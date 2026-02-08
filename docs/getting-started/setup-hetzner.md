# Setup Management Cluster on Hetzner
TODO: untested
TODO: needs hcloud server setup script


This guide walks you through setting up a k0rdent management cluster on a remote Hetzner Cloud server using k0s.

## Prerequisites

Ensure you have completed the [prerequisites](./prerequisites.md) setup.

## Step 1: Create Hetzner Cloud Server

### Setup hcloud CLI

1. Create an API token in Hetzner Cloud Console:
   - Go to https://console.hetzner.cloud/
   - Select your project
   - Go to **Security** → **API Tokens**
   - Click **Generate API Token**
   - Give it a name (e.g., `k0rdent-cli`)
   - Copy the token

2. Configure hcloud:

```bash
hcloud context create k0rdent
# Paste your API token when prompted
```

### Create SSH Key

If you don't have an SSH key in Hetzner Cloud yet:

```bash
# Upload your local SSH key
hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_rsa.pub

# Or list existing keys
hcloud ssh-key list
```

### Create Server

Create a server using hcloud CLI:

```bash
hcloud server create \
  --name k0rdent-mgmt \
  --type cpx31 \
  --image ubuntu-24.04 \
  --location nbg1 \
  --ssh-key my-key
```

**Server Types:**
- **Recommended:** `cpx31` (4 vCPU, 8 GB RAM, ~€12/month)
- **Minimum:** `cpx21` (3 vCPU, 4 GB RAM, ~€8/month)

**Locations:**
- `nbg1` - Nuremberg, Germany
- `fsn1` - Falkenstein, Germany
- `hel1` - Helsinki, Finland
- `ash` - Ashburn, USA
- `hil` - Hillsboro, USA

### Get Server IP

```bash
hcloud server describe k0rdent-mgmt
# Or get just the IP
hcloud server ip k0rdent-mgmt
```

### Verify SSH Access

```bash
ssh root@$(hcloud server ip k0rdent-mgmt)
```

## Step 2: Install k0s on Remote Server

You can use either k0sctl (recommended) or manual installation.

### Option A: Using k0sctl (Recommended)

**On your local machine:**

1. Copy and customize the configuration:

```bash
cp k0sctl-hetzner.yaml k0sctl-hetzner-custom.yaml
```

2. Edit `k0sctl-hetzner-custom.yaml`:
   - Replace `<server-ip>` with your server IP (use `hcloud server ip k0rdent-mgmt`)
   - Update SSH key path if needed

Or use sed to replace automatically:
```bash
cp k0sctl-hetzner.yaml k0sctl-hetzner-custom.yaml
sed -i '' "s/<server-ip>/$(hcloud server ip k0rdent-mgmt)/" k0sctl-hetzner-custom.yaml
```

3. Bootstrap the cluster:

```bash
k0sctl apply --config k0sctl-hetzner-custom.yaml
```

k0sctl will:
- SSH into the server
- Install k0s
- Configure the cluster
- Download kubeconfig to `./kubeconfig`

4. Configure kubectl to use the cluster:

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

### Option B: Manual Installation

**On the remote server:**

1. Install k0s:

```bash
curl -sSLf https://get.k0s.sh | sudo sh
```

2. Install as single-node controller:

```bash
sudo k0s install controller --single
sudo k0s start
```

3. Verify k0s is running:

```bash
sudo k0s status
```

4. Generate kubeconfig:

```bash
sudo k0s kubeconfig admin > k0s-kubeconfig.yaml
cat k0s-kubeconfig.yaml
```

**On your local machine:**

5. Copy kubeconfig from server:

```bash
scp root@<server-ip>:~/k0s-kubeconfig.yaml ~/.kube/k0s-config
```

6. Update server address in kubeconfig:

```bash
sed -i '' 's/localhost/<server-ip>/g' ~/.kube/k0s-config
```

7. Configure kubectl:

```bash
export KUBECONFIG=~/.kube/k0s-config
kubectl get nodes
```

## Step 3: Install k0rdent

Install k0rdent using Helm:

```bash
helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
  --version 1.5.0 \
  -n kcm-system \
  --create-namespace
```

**Monitor installation:**
```bash
kubectl get pods -n kcm-system -w
```

Wait until all pods show `Running` status (approximately 15 minutes).

## Step 4: Configure Templates

Apply the Hetzner provider and cluster templates:

```bash
# Setup Helm repository
kubectl apply -f manifests/mgmt/helm-custom-repo.yaml

# Setup Provider template
kubectl apply -f manifests/mgmt/hetzner-providertemplate.yaml

# Setup Cluster template
kubectl apply -f manifests/mgmt/hetzner-clustertemplate.yaml
```

## Step 5: Configure Credentials

**⚠️ Security Note:** Never write your API token directly in YAML files!

Add your Hetzner Cloud API credentials securely:

**Option A: Using hcloud CLI (Recommended)**

```bash
# Apply credential config
kubectl apply -f manifests/mgmt/credential.yaml

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

**Option B: Using Environment Variable**

```bash
# Set your token (e.g., from 1Password, Bitwarden, etc.)
export HCLOUD_TOKEN="your-token-here"

# Apply credential config
kubectl apply -f manifests/mgmt/credential.yaml

# Create secret from environment variable
kubectl create secret generic hcloud-cluster-provisioning-token \
  --from-literal=hcloud=$HCLOUD_TOKEN \
  --namespace kcm-system

# Add required labels
kubectl label secret hcloud-cluster-provisioning-token \
  -n kcm-system \
  caph.environment=owned \
  k0rdent.mirantis.com/component=kcm

# Clear the variable from shell history
unset HCLOUD_TOKEN
```

**Verify secret was created:**
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

## Step 6: Deploy a User Cluster

Deploy a cluster:

```bash
kubectl apply -f manifests/user-cluster/cluster-01.yaml
```

**Monitor deployment:**
```bash
kubectl get clusters
kubectl get clusterdeployments
kubectl describe cluster cluster-01
```

## Package and Publish Custom Templates

If you need to modify charts or publish new versions, see the complete guide:

**[Package and Publish Charts](../../charts/package-and-publish.md)**

This guide covers:
- Packaging Helm charts
- Authenticating to GitHub Container Registry
- Publishing to OCI registry
- Version management
- Troubleshooting

**Browse published templates:**
- https://github.com/orgs/enopax/packages?repo_name=templates

## Troubleshooting

### Cannot Connect to Remote Cluster

Check these common issues:

1. **Verify server IP in kubeconfig:**
```bash
grep server ~/.kube/k0s-config
```

2. **Check firewall allows port 6443:**
```bash
ssh root@<server-ip> "sudo ufw status"
```

3. **Verify k0s is running:**
```bash
ssh root@<server-ip> "sudo k0s status"
```

### k0rdent Pods Not Starting

Check pod status and logs:
```bash
kubectl describe pod <pod-name> -n kcm-system
kubectl logs <pod-name> -n kcm-system
```

### Cluster Deployment Stuck

Check events and cluster status:
```bash
kubectl get events --sort-by='.lastTimestamp'
kubectl describe cluster cluster-01
```

## Security Considerations

### Firewall Configuration

Ensure only necessary ports are open:

```bash
# On the remote server
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 6443/tcp  # Kubernetes API
sudo ufw enable
```

### SSH Key Security

- Use SSH keys instead of passwords
- Rotate SSH keys regularly
- Consider using SSH certificate authority

### API Token Security

- Store Hetzner API tokens securely
- Use separate tokens for different environments
- Rotate tokens regularly
- Never commit tokens to git

## Managing Hetzner Resources

### Useful hcloud Commands

```bash
# List all servers
hcloud server list

# Get server details
hcloud server describe k0rdent-mgmt

# Get server IP
hcloud server ip k0rdent-mgmt

# Stop server
hcloud server poweroff k0rdent-mgmt

# Start server
hcloud server poweron k0rdent-mgmt

# Delete server
hcloud server delete k0rdent-mgmt

# SSH into server
hcloud server ssh k0rdent-mgmt

# List available server types
hcloud server-type list

# List available locations
hcloud location list

# List available images
hcloud image list --type system
```

### Cost Management

Monitor your costs:
```bash
# Get server details including monthly cost
hcloud server describe k0rdent-mgmt | grep -A5 "Server Type"
```

**Approximate costs:**
- CPX21 (3 vCPU, 4 GB RAM): ~€8/month
- CPX31 (4 vCPU, 8 GB RAM): ~€12/month
- CPX41 (8 vCPU, 16 GB RAM): ~€24/month

## Next Steps

- Configure backup and disaster recovery
- Set up monitoring and alerting
- Configure multi-node k0s cluster for high availability
- Implement GitOps workflows
- Automate server provisioning with Terraform or scripts
