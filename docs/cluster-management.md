# User Cluster Management

This document describes how to manage **user clusters** (also called "workload clusters") using `cluster.sh`.

## Overview

The `cluster.sh` script manages **user clusters** - the actual Hetzner VM-based Kubernetes clusters that run your applications. These are provisioned and managed by the **management cluster** (which runs k0rdent).

```
Management Cluster (kind/k0s + k0rdent) ← You interact with this
└── User Clusters (Hetzner VMs)         ← These run your apps
    ├── production
    ├── staging
    └── development
```

## Architecture

### Management vs User Clusters

**Management Cluster**:
- Runs k0rdent (cluster provisioning engine)
- Can be local (kind) or remote (Hetzner k0s)
- Manages credentials and templates
- **One management cluster → many user clusters**
- Does NOT run your application workloads

**User Cluster** (also called "workload cluster"):
- Actual Hetzner VMs running Kubernetes
- Provisioned by k0rdent running on the management cluster
- Each has independent configuration
- **This is where your applications run**
- Billed by Hetzner Cloud

### Directory Structure

```
cluster-templates/
├── manifests/
│   ├── mgmt/           # Management cluster templates
│   └── user-cluster/   # User cluster templates
│       └── cluster.yaml
│
└── mgmt/               # Generated (NOT in git)
    └── <mgmt-name>/    # e.g., "test" or "prod"
        ├── .env        # Management cluster config
        ├── manifests/  # Applied to management cluster
        └── user-clusters/  # User clusters
            └── <user-cluster-name>/  # e.g., "production"
                ├── .env         # User cluster config
                └── cluster.yaml # User cluster manifest
```

**Important**: All `./cluster.sh` commands operate on **user clusters** stored in `mgmt/<mgmt-name>/user-clusters/`.

## Commands

### `create` - Generate Manifests

Generate **user cluster** configuration and manifests from templates.

**Usage**:
```bash
./cluster.sh create <user-cluster-name>
```

**What it does**:
1. Detects active management cluster from kubectl context
2. Creates directory: `mgmt/<mgmt-name>/user-clusters/<user-cluster-name>/`
3. Creates `.env` file with default user cluster configuration
4. Generates `cluster.yaml` from template
5. **Does NOT apply manifests** (no Hetzner VMs created yet)

**Example**:
```bash
$ ./cluster.sh create my-app
[CLUSTER] Creating user cluster: my-app
[INFO] Management cluster: test

[INFO] Creating user cluster configuration...
[INFO] Created: mgmt/test/clusters/my-app/.env
[INFO] Generating manifests for my-app...
[INFO] Processing cluster.yaml...

✓ User cluster configured: my-app
✓ Configuration: mgmt/test/user-clusters/my-app/.env
✓ Manifests: mgmt/test/user-clusters/my-app/

[INFO] To deploy this cluster:
[INFO]   ./cluster.sh deploy my-app
```

**When to use**:
- Creating a new user cluster for your applications
- Setting up configuration before deployment
- Testing manifest generation without creating Hetzner resources

---

### `deploy` - Apply Manifests

Apply **user cluster** manifests to create Hetzner VMs.

**Usage**:
```bash
./cluster.sh deploy <user-cluster-name>
```

**What it does**:
1. Validates user cluster was created (manifests exist)
2. Loads management cluster configuration
3. **Applies manifests to management cluster** (not directly to Hetzner!)
4. k0rdent (running on mgmt cluster) provisions Hetzner VMs
5. Shows monitoring commands

**Example**:
```bash
$ ./cluster.sh deploy my-app
[CLUSTER] Deploying user cluster: my-app
[INFO] Management cluster: test
[WARN] This will create Hetzner VMs for the user cluster.

[INFO] Applying manifests to management cluster (test)...
clusterdeployment.k0rdent.mirantis.com/my-app created

✓ User cluster deployment initiated!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[CLUSTER] Monitoring Commands
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] Watch deployment (runs on mgmt cluster):
[INFO]   kubectl get clusterdeployment my-app -n kcm-system -w

[INFO] Check status:
[INFO]   ./cluster.sh status my-app
```

**When to use**:
- After creating user cluster manifests
- When ready to provision Hetzner VMs for your applications
- To apply configuration changes (scaling, etc.)

**Important**:
- This creates **billable Hetzner resources**
- Ensure configuration is correct before deploying
- Monitor deployment progress with `./cluster.sh status`
- The manifest is applied to the **management cluster**, which then provisions Hetzner VMs

---

### `list` - List User Clusters

List all **user clusters** for the active management cluster.

**Usage**:
```bash
./cluster.sh list
```

**Example**:
```bash
$ ./cluster.sh list
[CLUSTER] User clusters managed by: test

  production
    Status: Provisioned
    Ready: True

  staging
    Status: Provisioning
    Ready: Unknown

  development
    Status: Pending
    Ready: False
```

**When to use**:
- View all user clusters managed by current management cluster
- Check user cluster statuses at a glance
- Verify user cluster names

---

### `status` - Check Cluster Status

Show detailed status of a workload cluster.

**Usage**:
```bash
./cluster.sh status <cluster-name>
```

**Example**:
```bash
$ ./cluster.sh status production
[CLUSTER] Cluster Status: production

NAME         READY   STATUS        CONTROL-PLANE   WORKERS
production   True    Provisioned   1               2

Name:         production
Namespace:    kcm-system
Ready:        True
Status:       Provisioned
Control Plane Nodes: 1/1
Worker Nodes:        2/2

Events:
  Type    Reason           Age   From              Message
  ----    ------           ----  ----              -------
  Normal  Provisioning     5m    cluster-manager   Creating control plane
  Normal  MachinesReady    3m    cluster-manager   All machines ready
  Normal  Provisioned      1m    cluster-manager   Cluster provisioned
```

**When to use**:
- Monitor cluster deployment progress
- Troubleshoot deployment issues
- Verify cluster is ready

---

### `delete` - Delete Cluster

Delete a workload cluster and its Hetzner VMs.

**Usage**:
```bash
./cluster.sh delete <cluster-name>
```

**What it does**:
1. Confirms deletion (prompts user)
2. Deletes cluster from management cluster (removes Hetzner VMs)
3. Optionally removes local configuration

**Example**:
```bash
$ ./cluster.sh delete my-app
[CLUSTER] Deleting workload cluster: my-app
[WARN] This will delete Hetzner VMs and all data!

Are you sure? (y/N): y
[INFO] Deleting from management cluster...
clusterdeployment.k0rdent.mirantis.com "my-app" deleted

Remove local configuration? (y/N): y
[INFO] ✓ Local configuration removed
[INFO] ✓ Workload cluster deleted
```

**When to use**:
- Remove workload cluster
- Clean up test clusters
- Stop Hetzner billing

**Important**:
- This deletes Hetzner VMs (data loss!)
- Waits for user confirmation
- Can keep local config for recreation

---

### `kubeconfig` - Get Kubeconfig

Retrieve kubeconfig for accessing the workload cluster.

**Usage**:
```bash
./cluster.sh kubeconfig <cluster-name>
```

**What it does**:
1. Extracts kubeconfig from Kubernetes secret
2. Saves to `~/.kube/config-<cluster-name>`
3. Shows usage instructions

**Example**:
```bash
$ ./cluster.sh kubeconfig production
[CLUSTER] Getting kubeconfig: production

✓ Kubeconfig saved to: ~/.kube/config-production

[INFO] To use this cluster:
[INFO]   export KUBECONFIG=~/.kube/config-production
[INFO]   kubectl get nodes
```

**Usage with kubectl**:
```bash
# Option 1: Export KUBECONFIG
export KUBECONFIG=~/.kube/config-production
kubectl get nodes

# Option 2: Use --kubeconfig flag
kubectl get nodes --kubeconfig=~/.kube/config-production

# Option 3: Merge with main config
KUBECONFIG=~/.kube/config:~/.kube/config-production kubectl config view --flatten > /tmp/merged
mv /tmp/merged ~/.kube/config
kubectl config use-context production
```

**When to use**:
- Access workload cluster after deployment
- Manage workload cluster resources
- Verify cluster is operational

---

## Workflows

### Creating a New User Cluster

```bash
# 1. Ensure management cluster is active
kubectl config current-context  # Should be kind-test or hcloud-test

# 2. Create user cluster manifests
./cluster.sh create my-app

# 3. (Optional) Customize user cluster configuration
vim mgmt/test/user-clusters/my-app/.env
# Adjust: CONTROL_PLANE_COUNT, WORKER_COUNT, HETZNER_REGION, etc.

# 4. Regenerate if customized
./cluster.sh create my-app  # Re-run to apply changes

# 5. Deploy to Hetzner (creates VMs for user cluster)
./cluster.sh deploy my-app

# 6. Monitor deployment (runs against management cluster)
./cluster.sh status my-app
kubectl get clusterdeployment my-app -n kcm-system -w

# 7. Get kubeconfig when user cluster is ready
./cluster.sh kubeconfig my-app

# 8. Access user cluster (where your apps will run)
export KUBECONFIG=~/.kube/config-my-app
kubectl get nodes  # Shows nodes in your user cluster
```

### Updating Cluster Configuration

```bash
# 1. Modify configuration
vim mgmt/test/user-clusters/my-app/.env
# Change: WORKER_COUNT=2 → WORKER_COUNT=5

# 2. Regenerate manifests
./cluster.sh create my-app

# 3. Apply changes
./cluster.sh deploy my-app

# 4. Monitor scaling
./cluster.sh status my-app
```

### Managing Multiple Clusters

```bash
# Create clusters for different environments
./cluster.sh create production
./cluster.sh create staging
./cluster.sh create development

# Customize each
vim mgmt/test/clusters/production/.env   # 3 control plane, 5 workers
vim mgmt/test/clusters/staging/.env      # 1 control plane, 2 workers
vim mgmt/test/clusters/development/.env  # 1 control plane, 1 worker

# Deploy all
./cluster.sh deploy production
./cluster.sh deploy staging
./cluster.sh deploy development

# List all clusters
./cluster.sh list

# Check specific cluster
./cluster.sh status production
```

### Switching Between Management Clusters

```bash
# Scenario: Multiple management clusters managing different workloads

# Management cluster: test (local kind)
kubectl config use-context kind-test
./cluster.sh list             # Shows workload clusters managed by 'test'
./cluster.sh create dev-app
./cluster.sh deploy dev-app

# Management cluster: prod (remote Hetzner)
kubectl config use-context hcloud-prod
./cluster.sh list             # Shows workload clusters managed by 'prod'
./cluster.sh create prod-app
./cluster.sh deploy prod-app
```

## Configuration

### Management Cluster Detection

The script automatically detects the active management cluster from kubectl context:

```bash
# Context: kind-test → Management cluster: test
# Context: hcloud-prod → Management cluster: prod
```

**Format**:
- kind clusters: `kind-<mgmt-name>`
- hcloud clusters: `hcloud-<mgmt-name>`

### Workload Cluster Configuration

Edit `mgmt/<mgmt-name>/user-clusters/<cluster-name>/.env`:

```bash
# Cluster Name (automatically set)
CLUSTER_NAME=my-app

# Cluster Sizing
CONTROL_PLANE_COUNT=1
WORKER_COUNT=2

# Hetzner Region
# Options: fsn1 (Falkenstein), nbg1 (Nuremberg), hel1 (Helsinki), ash (Ashburn)
HETZNER_REGION=fsn1

# Machine Types
# Options: cx11, cx21, cx31, cx41, cx51 (shared vCPU)
#          cpx11, cpx21, cpx31, cpx41, cpx51 (dedicated vCPU)
CONTROL_PLANE_MACHINE_TYPE=cx21
WORKER_MACHINE_TYPE=cx21
```

### Credentials and Templates

Credentials are configured once in the management cluster and shared across all workload clusters:

```
mgmt/test/
├── .env              # Hetzner API token (shared)
└── manifests/
    ├── credential.yaml   # Hetzner credential (shared)
    ├── secret.yaml       # Hetzner secret (shared)
    └── ...
```

User clusters reference the shared credential:

```yaml
# mgmt/test/user-clusters/my-app/cluster.yaml
spec:
  credential: test-credential  # References mgmt credential
```

## Monitoring

### Watch Deployment Progress

```bash
# Real-time status updates
kubectl get clusterdeployment my-app -n kcm-system -w

# Detailed events
kubectl describe clusterdeployment my-app -n kcm-system

# Watch all resources
kubectl get clusterdeployment,machine,cluster -n kcm-system -w
```

### Check Deployment Logs

```bash
# k0rdent controller logs
kubectl logs -n kcm-system -l app=k0rdent --tail=100 -f

# Cluster-specific logs
kubectl logs -n kcm-system -l cluster.x-k8s.io/cluster-name=my-app -f
```

### Verify Hetzner Resources

```bash
# Via hcloud CLI
hcloud server list
hcloud server describe my-app-control-plane-0

# Via Hetzner Cloud Console
# https://console.hetzner.cloud/
```

## Troubleshooting

### "No active kubectl context"

**Problem**: No kubectl context is active

**Solution**:
```bash
# List available contexts
kubectl config get-contexts

# Use management cluster context
kubectl config use-context kind-test   # or hcloud-test
```

### "Cannot determine management cluster from context"

**Problem**: Context name doesn't match expected format

**Expected**: `kind-<name>` or `hcloud-<name>`

**Solution**:
```bash
# Deploy management cluster first
./deploy.sh test  # Creates kind-test context

# Or use existing management cluster
kubectl config use-context kind-test
```

### "Workload cluster not found"

**Problem**: Trying to deploy cluster that wasn't created

**Solution**:
```bash
# Create cluster first
./cluster.sh create my-app

# Then deploy
./cluster.sh deploy my-app
```

### "Kubeconfig secret not found"

**Problem**: Cluster not ready yet

**Solution**:
```bash
# Check cluster status
./cluster.sh status my-app

# Wait for Ready: True
kubectl get clusterdeployment my-app -n kcm-system -w

# Try again when ready
./cluster.sh kubeconfig my-app
```

### Cluster Stuck in Provisioning

**Check events**:
```bash
kubectl describe clusterdeployment my-app -n kcm-system
```

**Common causes**:
- Invalid Hetzner token
- Insufficient Hetzner quota
- Invalid machine type or region
- Network connectivity issues

**Solutions**:
```bash
# Verify credentials
kubectl get secret -n kcm-system | grep credential

# Check Hetzner quota
hcloud server list
# Ensure you're under limits

# Verify configuration
cat mgmt/test/clusters/my-app/.env
# Check HETZNER_REGION, CONTROL_PLANE_MACHINE_TYPE, etc.

# Delete and recreate
./cluster.sh delete my-app
./cluster.sh create my-app
./cluster.sh deploy my-app
```

## Best Practices

### 1. Use Descriptive Names

```bash
# Good
./cluster.sh create production-eu
./cluster.sh create staging-us
./cluster.sh create dev-local

# Avoid
./cluster.sh create cluster1
./cluster.sh create test123
```

### 2. Test Configuration Locally First

```bash
# Test with kind management cluster
./setup.sh test
./deploy.sh test
./cluster.sh create my-test-app
./cluster.sh deploy my-test-app

# Verify it works, then use production management cluster
kubectl config use-context hcloud-prod
./cluster.sh create production-app
./cluster.sh deploy production-app
```

### 3. Customize Before Deploying

```bash
# Create manifests
./cluster.sh create my-app

# Review and customize
cat mgmt/test/clusters/my-app/.env
vim mgmt/test/clusters/my-app/.env

# Regenerate with changes
./cluster.sh create my-app

# Deploy
./cluster.sh deploy my-app
```

### 4. Monitor Deployments

```bash
# Don't just fire and forget
./cluster.sh deploy my-app

# Watch progress
./cluster.sh status my-app

# Wait for ready
kubectl get clusterdeployment my-app -n kcm-system -w
```

### 5. Clean Up Unused Clusters

```bash
# List all clusters
./cluster.sh list

# Delete unused ones
./cluster.sh delete old-test-cluster
```

## Cost Management

### Hetzner Pricing (as of 2025)

| Machine Type | vCPU | RAM  | Monthly Cost |
|--------------|------|------|--------------|
| cx11         | 1    | 2GB  | ~€4          |
| cx21         | 2    | 4GB  | ~€6          |
| cx31         | 2    | 8GB  | ~€11         |
| cx41         | 4    | 16GB | ~€17         |
| cx51         | 8    | 32GB | ~€33         |

### Estimating Cluster Costs

```bash
# Configuration
CONTROL_PLANE_COUNT=1
CONTROL_PLANE_MACHINE_TYPE=cx21  # €6/month
WORKER_COUNT=2
WORKER_MACHINE_TYPE=cx21          # €6/month

# Total: 1 × €6 + 2 × €6 = €18/month
```

### Cost Optimization

**Development**:
- Use kind management cluster (free)
- Use small workload clusters (cx11)
- Delete when not in use

**Staging**:
- Share staging clusters across teams
- Use smaller machine types
- Scale down outside business hours

**Production**:
- Right-size machine types
- Use dedicated vCPU (cpx) for critical workloads
- Monitor utilization and adjust

## See Also

- [Main README](../README.md) - Quick start and overview
- [Architecture](architecture.md) - System design
- [Features](features.md) - Feature documentation
