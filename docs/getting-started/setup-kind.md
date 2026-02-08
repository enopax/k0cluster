# Setup Management Cluster with kind

This guide walks you through setting up a local k0rdent management cluster using kind (Kubernetes in Docker).

## Prerequisites

Ensure you have completed the [prerequisites](./prerequisites.md) setup.

## Quick Setup (Recommended)

Use the automated setup script for a complete installation:

```bash
cd /path/to/templates
./scripts/setup-k0rdent-mgmt.sh
```

**What it does:**
- Creates kind cluster named `k0rdent`
- Installs k0rdent v1.5.0
- Deploys Hetzner provider (CAPH)
- Applies cluster templates
- Configures credentials from hcloud CLI
- Verifies installation

**Time:** ~5-10 minutes for complete setup

**Next:** Skip to [Step 6](#step-6-deploy-a-test-cluster) to deploy a cluster.

---

## Manual Setup

Follow these steps if you want to understand each component or customize the installation:

## Step 1: Create kind Cluster

Create a new kind cluster:

```bash
kind create cluster --name k0rdent
```

The cluster will be created with the latest stable Kubernetes version. This typically takes 1-2 minutes.

**Verify cluster is running:**
```bash
kubectl cluster-info --context kind-k0rdent
kubectl get nodes
```

You should see the control-plane node in `Ready` status.

## Step 2: Install k0rdent

Install k0rdent into the cluster using Helm:

```bash
helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
  --version 1.5.0 \
  -n kcm-system \
  --set regional.telemetry.mode=disabled \
  --set regional.velero.enabled=false \
  --set="controller.createManagement=false" \
  --create-namespace
```

**Note:** Installation takes approximately 15 minutes.

**Monitor installation progress:**
```bash
kubectl get pods -n kcm-system
```

Wait until all pods show `Running` status.

Reference: [k0rdent documentation](https://docs.k0rdent.io/latest/quickstarts/quickstart-1-mgmt-node-and-cluster/)

## Step 3: Publish Charts (First Time Only)

**⚠️ Important:** The manifests reference charts from `oci://ghcr.io/enopax/templates`. These charts must be published before applying templates.

**If charts are already published, skip this step.**

See [Package and Publish Charts](../../charts/package-and-publish.md) for complete instructions on:
- Packaging the Helm charts
- Authenticating to GitHub Container Registry
- Publishing charts to the OCI registry
- Verifying the charts are available

Once complete, verify charts are published:
- https://github.com/orgs/enopax/packages?repo_name=templates

## Step 4: Configure Cluster Templates

Apply the management resources, provider, and cluster templates in the correct order:

```bash
# Setup k0rdent Management
kubectl apply -f manifests/mgmt/management.yaml

# Setup Helm repository
kubectl apply -f manifests/mgmt/helm-custom-repo.yaml

# Setup Provider template (MUST be applied before Management finishes reconciliation)
kubectl apply -f manifests/mgmt/hetzner-providertemplate.yaml

# Wait for Management to be ready
kubectl wait --for=condition=ready management/kcm --timeout=600s

# Setup Cluster template
kubectl apply -f manifests/mgmt/hetzner-clustertemplate.yaml
```

**Note:** The ProviderTemplate must exist before the Management resource finishes reconciliation, as the Management references this template.

## Step 5: Configure Credentials

**⚠️ Security Note:** Never write your API token directly in YAML files!

k0rdent uses a two-part credential system:
1. **Credential Resource** (`hcloud-cluster-provisioning`) - References where to find the token
2. **Secret** (`hcloud-cluster-provisioning-token`) - Contains the actual Hetzner API token

### 5.1: Create the Credential Resource

The Credential resource tells k0rdent where to find your Hetzner credentials:

```bash
# Apply credential configuration
kubectl apply -f manifests/mgmt/credential.yaml
```

This creates a `Credential` named `hcloud-cluster-provisioning` that references the `hcloud-cluster-provisioning-token` secret.

**Verify credential was created:**
```bash
kubectl get credential hcloud-cluster-provisioning -n kcm-system
```

### 5.2: Create the Secret with Your API Token

Create the secret containing your actual Hetzner Cloud API token using the `hcloud` CLI:

```bash
# Create secret from hcloud context
kubectl create secret generic hcloud-cluster-provisioning-token \
  --from-literal=hcloud=$(hcloud config get token --allow-sensitive) \
  --namespace kcm-system

# Add required labels
kubectl label secret hcloud-cluster-provisioning-token \
  -n kcm-system \
  caph.environment=owned \
  k0rdent.mirantis.com/component=kcm
```

**Alternative: Create secret manually without hcloud CLI:**

If you don't have the `hcloud` CLI configured, create the secret directly with your token:

```bash
# Replace YOUR_HETZNER_API_TOKEN with your actual token
kubectl create secret generic hcloud-cluster-provisioning-token \
  --from-literal=hcloud=YOUR_HETZNER_API_TOKEN \
  --namespace kcm-system

# Add required labels
kubectl label secret hcloud-cluster-provisioning-token \
  -n kcm-system \
  caph.environment=owned \
  k0rdent.mirantis.com/component=kcm
```

### 5.3: Verify the Credential Setup

**Check the credential resource:**
```bash
# Verify credential exists and references correct secret
kubectl get credential hcloud-cluster-provisioning -n kcm-system -o yaml
```

**Check the secret:**
```bash
# Check secret exists
kubectl get secret hcloud-cluster-provisioning-token -n kcm-system

# Verify labels are correct
kubectl get secret hcloud-cluster-provisioning-token -n kcm-system --show-labels

# Check secret contains the 'hcloud' key
kubectl get secret hcloud-cluster-provisioning-token -n kcm-system -o jsonpath='{.data}' | grep -o hcloud
```

**Test the token works:**
```bash
# Extract and test token with hcloud
HCLOUD_TOKEN=$(kubectl get secret hcloud-cluster-provisioning-token -n kcm-system -o jsonpath='{.data.hcloud}' | base64 -d)

# Test token by listing servers (should work without error)
hcloud server list

# Clean up variable
unset HCLOUD_TOKEN
```

**Expected output:** Your Hetzner servers list (or empty if none exist). If you get an authentication error, the token is invalid.

**Understanding the relationship:**
- Your `ClusterDeployment` references → `credential: hcloud-cluster-provisioning`
- The `hcloud-cluster-provisioning` Credential references → Secret `hcloud-cluster-provisioning-token`
- The `hcloud-cluster-provisioning-token` Secret contains → Your actual Hetzner API token

## Step 6: Deploy a Test Cluster

Deploy a test cluster on Hetzner:

```bash
kubectl apply -f manifests/user-cluster/cluster-01.yaml
```

**Monitor cluster deployment:**
```bash
kubectl get clusters
kubectl get clusterdeployments
kubectl describe cluster cluster-01
```

## Managing Your kind Cluster

### Switch Between Clusters

If you have multiple kind clusters:

```bash
# List all kind clusters
kind get clusters

# Switch context
kubectl config use-context kind-k0rdent

# Check current context
kubectl config current-context
```

### Delete the Cluster

When you're done:

```bash
kind delete cluster --name k0rdent
```

## Troubleshooting

### Pods Not Starting

Check pod status and logs:
```bash
kubectl describe pod <pod-name> -n kcm-system
kubectl logs <pod-name> -n kcm-system
```

### Cluster Creation Failed

If kind cluster creation fails:
1. Check container runtime is running (Rancher Desktop or Docker Desktop)
2. Ensure sufficient resources (4 CPU, 8 GB RAM minimum)
3. Delete any stale clusters: `kind get clusters`, then `kind delete cluster --name <name>`

### "Too Many Open Files" or API Timeout Errors

If you encounter errors like:
- `too many open files` in kube-proxy logs
- CoreDNS unable to reach Kubernetes API
- `dial tcp 10.96.0.1:443: i/o timeout` in flux-check or pod logs

**Solutions**:

1. **Check and increase file descriptor limits**:
   ```bash
   # Check current limit
   ulimit -n

   # Increase if below 65536 (macOS/Linux)
   ulimit -n 65536
   ```

   For permanent changes:
   - **macOS**: Add to `~/.zshrc` or `~/.bash_profile`
   - **Linux**: Edit `/etc/security/limits.conf`

2. **Delete unused kind clusters to free resources**:
   ```bash
   # List all clusters
   kind get clusters

   # Delete unused clusters
   kind delete cluster --name <cluster-name>
   ```

3. **Restart Docker/Rancher Desktop**:
   - Restart the container runtime to reset resource limits
   - This clears stale file descriptors and network connections

4. **Verify sufficient system resources**:
   - CPU: 8+ cores recommended (4 cores minimum per cluster)
   - RAM: 16+ GB recommended (8 GB minimum per cluster)
   - Storage: 20+ GB available disk space
   - Check: `docker system df` to see Docker resource usage

5. **Check for other resource-intensive containers**:
   ```bash
   # List all running containers
   docker ps

   # Stop containers you don't need
   docker stop <container-id>
   ```

### Port Conflicts

kind automatically assigns ports. If you see port conflicts:
```bash
docker ps | grep kind
```

Check which ports are in use and stop conflicting services.

### k0rdent Installation Timeout

If the helm install times out or pre-install hooks fail:

1. **Wait longer**: k0rdent installation can take 15-20 minutes
2. **Check pod status**: `kubectl get pods -n kcm-system -w`
3. **Ensure cluster is stable**: Wait 1-2 minutes after creating the kind cluster before installing k0rdent
4. **Verify DNS is working**: `kubectl get pods -n kube-system` - ensure CoreDNS pods are Running

## Next Steps

- Build and push custom templates (see main [README](../../README.md))
- Deploy additional clusters
- Configure monitoring and observability

## Configure SSH Keys for Cluster Nodes

To enable SSH access to your Hetzner cluster nodes, you need to configure SSH keys that are registered in your Hetzner Cloud project.

### List Available SSH Keys

```bash
# List all SSH keys in your Hetzner project
hcloud ssh-key list
```

### Add SSH Keys to Your ClusterDeployment

Update your `cluster-01.yaml` (or similar) to include the SSH key names from your Hetzner project:

```yaml
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ClusterDeployment
metadata:
  name: cluster01
  namespace: kcm-system
spec:
  template: hetzner-standalone-cp-v109  # or latest version
  credential: hcloud-cluster-provisioning
  config:
    region: fsn1
    controlPlaneNumber: 1
    workersNumber: 1
    
    # Add SSH keys from your Hetzner project
    sshKeyNames:
      - "felix@chump"           # Replace with your SSH key names
      - "your-key-name"
    
    # ... rest of configuration
```

### Verify SSH Access

After the cluster is deployed, you can SSH into the nodes:

```bash
# Get the node IPs
kubectl get machines -n kcm-system -o wide

# SSH to control plane (replace IP with actual)
ssh root@<CONTROL_PLANE_IP>

# SSH to worker node (replace IP with actual)
ssh root@<WORKER_NODE_IP>
```
