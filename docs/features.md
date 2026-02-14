# Features

Comprehensive guide to all features provided by the k0rdent cluster templates system.

**Terminology Note**: This system manages two types of clusters:
- **Management Cluster**: Runs k0rdent (can be local kind or remote k0s)
- **User Cluster**: The actual Hetzner-based Kubernetes clusters for your applications (also called "workload clusters")

## Table of Contents

- [Multi-Cluster Management](#multi-cluster-management)
- [Provider System](#provider-system)
- [Template-Based Configuration](#template-based-configuration)
- [Automated Token Detection](#automated-token-detection)
- [Orphaned Manifest Cleanup](#orphaned-manifest-cleanup)
- [Helm Chart Management](#helm-chart-management)
- [Self-Contained Configurations](#self-contained-configurations)
- [Configuration Merging](#configuration-merging)
- [Context Management](#context-management)
- [Idempotent Operations](#idempotent-operations)

---

## Multi-Cluster Management

Manage multiple Kubernetes clusters simultaneously, each with independent configuration.

### Features

- **Independent Configurations**: Each cluster has its own directory and settings
- **Isolated Contexts**: Separate kubectl contexts prevent cross-cluster operations
- **Parallel Management**: Setup and deploy multiple clusters without conflicts
- **Easy Switching**: Switch between clusters using standard kubectl context commands

### Usage

```bash
# Create multiple clusters
./setup.sh production
./setup.sh staging
./setup.sh development

# Each has its own configuration
cluster/production/.env
cluster/staging/.env
cluster/development/.env

# Deploy specific cluster
./deploy.sh production

# Switch between clusters
kubectl config use-context kind-production
kubectl config use-context kind-staging
```

### Benefits

- **No Configuration Interference**: Changes to one cluster don't affect others
- **Different Providers**: Mix kind (local) and Hetzner (remote) management clusters
- **Region Diversity**: Deploy clusters in different Hetzner regions
- **Environment Separation**: Clear separation between dev, staging, and production

---

## Provider System

Modular provider architecture supporting multiple management cluster types.

### Supported Providers

#### kind (Local Development)

**Description**: Docker-based local Kubernetes clusters

**Features**:
- Automatic cluster creation
- Automatic k0rdent installation
- No cloud costs
- Fast iteration cycles
- Isolated from production

**Use Cases**:
- Development and testing
- CI/CD pipelines
- Learning k0rdent
- Offline development

**Configuration**:
```bash
MGMT_CLUSTER_TYPE=kind
```

**Automatic Setup**:
- Creates kind cluster if not exists
- Installs k0rdent via Helm
- Configures kubectl context
- No manual intervention required

#### hcloud (Remote Production)

**Description**: Remote k0s clusters on Hetzner VMs

**Features**:
- Production-grade infrastructure
- Remote access
- Persistent management cluster
- Multi-user support

**Use Cases**:
- Production deployments
- Team collaboration
- Long-running clusters
- High availability setups

**Configuration**:
```bash
MGMT_CLUSTER_TYPE=hcloud
```

**Manual Setup Required**:
1. Create Hetzner VM
2. Install k0s
3. Configure kubectl context
4. Install k0rdent

### Adding Custom Providers

Create new provider script with standard interface:

```bash
# scripts/provider/aws.sh

check_requirements() {
    # Check for AWS CLI, credentials, etc.
}

cluster_exists() {
    # Check if EKS cluster exists
}

create_cluster() {
    # Create EKS cluster or validate existing
}

get_context_name() {
    # Return: aws-<cluster-name>
}

switch_context() {
    # Switch to AWS cluster context
}

install_k0rdent() {
    # Install k0rdent to EKS cluster
}
```

Then use in cluster config:
```bash
MGMT_CLUSTER_TYPE=aws
```

---

## Template-Based Configuration

Generate Kubernetes manifests from templates using environment variables.

### How It Works

1. **Templates** stored in `manifests/`
2. **Variables** defined in `cluster/<name>/.env`
3. **Generation** via `envsubst` command
4. **Output** to `cluster/<name>/*.yaml`

### Template Syntax

Use bash environment variable syntax:

```yaml
# manifests/cluster.yaml
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: ClusterDeployment
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${CLUSTER_NAMESPACE}
spec:
  template: hetzner-standalone-cp
  credential: ${CLUSTER_NAME}-credential
  config:
    clusterLabels:
      environment: ${ENVIRONMENT:-production}
      region: ${HETZNER_REGION}
```

### Variable Features

**Default Values**:
```yaml
region: ${HETZNER_REGION:-fsn1}  # Defaults to 'fsn1' if not set
```

**Required Variables**:
```yaml
name: ${CLUSTER_NAME}  # No default, must be set
```

**Computed Values**:
```bash
# In .env
CONTROL_PLANE_MACHINE_TYPE=cx21
WORKER_MACHINE_TYPE=cx21
MACHINE_COUNT=$((CONTROL_PLANE_COUNT + WORKER_COUNT))
```

### Benefits

- **DRY Configuration**: Single source of truth for values
- **Reusable Templates**: Same template for all clusters
- **Type Safety**: Validate variables before generation
- **Version Control**: Track template changes, not generated files

---

## Automated Token Detection

Automatically detect Hetzner API tokens from hcloud CLI configuration.

### How It Works

1. **Check for hcloud CLI**: `command -v hcloud`
2. **Read Active Context**: `hcloud context active`
3. **Parse TOML Config**: Using `yq` to extract token
4. **Base64 Encode**: `echo -n "$token" | base64`
5. **Update .env**: Auto-populate `HETZNER_TOKEN_BASE64`

### Implementation

```bash
get_hcloud_token() {
    local hcloud_config="${HOME}/.config/hcloud/cli.toml"

    # Check if hcloud CLI is installed
    if ! command -v hcloud &> /dev/null; then
        return 1
    fi

    # Get active context
    local active_context=$(hcloud context active 2>/dev/null)
    if [ -z "${active_context}" ]; then
        return 1
    fi

    # Extract token using yq (TOML parser)
    local token=$(yq -p toml -oy \
        ".contexts[] | select(.name == \"${active_context}\") | .token" \
        "${hcloud_config}" 2>/dev/null)

    # Base64 encode
    if [ -n "${token}" ]; then
        echo -n "${token}" | base64
        return 0
    fi

    return 1
}
```

### Setup

```bash
# Configure hcloud CLI
hcloud context create my-project
# Enter token when prompted

# Activate context
hcloud context use my-project

# Token auto-detected
./setup.sh my-cluster
```

### Fallback

Manual configuration if hcloud CLI not available:

```bash
# Get token from Hetzner Cloud Console
# https://console.hetzner.cloud/

# Encode token
echo -n "your-token-here" | base64

# Add to .env
vim cluster/my-cluster/.env
HETZNER_TOKEN_BASE64=<encoded-token>
```

### Security

- Token never displayed in terminal
- Not logged to any files
- Only stored in `.env` (git-ignored)
- Base64 encoding prevents accidental exposure

---

## Orphaned Manifest Cleanup

Automatically remove generated manifests when templates are deleted.

### Problem

When templates are removed from `manifests/`:
- Generated files remain in `cluster/<name>/`
- Old resources may be deployed
- Configuration drift occurs
- Manual cleanup required

### Solution

Setup script tracks templates and removes orphans:

```bash
# Track current templates
TEMPLATE_FILES=()
for manifest in manifests/*.yaml; do
    TEMPLATE_FILES+=("$(basename "$manifest")")
done

# Generate manifests (as usual)
for manifest in manifests/*.yaml; do
    process_manifest "$(basename "$manifest")"
done

# Remove orphaned files
for cluster_file in cluster/<name>/*.yaml; do
    filename=$(basename "$cluster_file")
    if [[ ! " ${TEMPLATE_FILES[@]} " =~ " ${filename} " ]]; then
        print_warn "Removing orphaned manifest: ${filename}"
        rm -f "$cluster_file"
    fi
done
```

### Example

**Before**:
```
manifests/
├── cluster.yaml
├── credential.yaml
├── old-config.yaml      # To be removed

cluster/my-cluster/
├── cluster.yaml
├── credential.yaml
├── old-config.yaml      # Orphaned
```

**After running `./setup.sh my-cluster`**:
```
manifests/
├── cluster.yaml
├── credential.yaml
# old-config.yaml deleted

cluster/my-cluster/
├── cluster.yaml
├── credential.yaml
# old-config.yaml removed automatically
```

### Output

```bash
$ ./setup.sh my-cluster
[SETUP] Setting up cluster: my-cluster
[INFO] Cluster configuration exists, checking for updates...
[INFO] Regenerating manifests in cluster/my-cluster/...
[INFO] Processing cluster.yaml...
[INFO] Processing credential.yaml...

[INFO] Checking for orphaned manifests...
[WARN] Removing orphaned manifest: old-config.yaml
[INFO] Removed 1 orphaned manifest(s)
```

### Benefits

- **Automatic Cleanup**: No manual intervention
- **Prevents Drift**: Keeps generated files in sync with templates
- **Safe**: Only runs for existing clusters (not first-time setup)
- **Visible**: Warns when removing files

---

## Helm Chart Management

Intelligent Helm chart packaging and publishing.

### Features

- **Idempotent Packaging**: Only re-packages changed charts
- **Version Aware**: Reads versions from `Chart.yaml`
- **Local/Remote Support**: Package locally or publish to OCI registry
- **Auto-detection**: Detects chart changes via file modification times

### Usage

```bash
# Package and publish to OCI registry
./package-charts.sh

# Package locally only (no publish)
./package-charts.sh --local
./package-charts.sh --no-push
```

### Chart Sources

**Remote (Published)**:
```bash
CLUSTER_CHART_SOURCE=oci://ghcr.io/enopax/templates/hetzner-standalone-cp:1.0.0
```

**Local (Development)**:
```bash
CLUSTER_CHART_SOURCE=file://templates/cluster/hetzner-standalone-cp-1.0.0.tgz
```

**Mixed**:
```bash
# Use published cluster chart, local provider chart
CLUSTER_CHART_SOURCE=oci://ghcr.io/enopax/templates/hetzner-standalone-cp:1.0.0
PROVIDER_CHART_SOURCE=file://templates/provider/cluster-api-provider-hetzner-0.0.5.tgz
```

### Auto-Packaging

Setup script automatically packages charts locally:

```bash
$ ./setup.sh my-cluster
[SETUP] Setting up cluster: my-cluster
[INFO] Ensuring Helm charts are packaged...
[INFO] Packaging chart: hetzner-standalone-cp
[INFO] Successfully packaged chart: hetzner-standalone-cp-1.0.0.tgz
```

---

## Self-Contained Configurations

Each management cluster and user cluster configuration is isolated in its own directory.

### Structure

**Management Cluster**:
```
mgmt/<mgmt-name>/
├── .env                # Management cluster config
├── manifests/          # Generated manifests
└── user-clusters/      # User clusters
```

**User Cluster**:
```
mgmt/<mgmt-name>/user-clusters/<user-cluster-name>/
├── .env                # User cluster config
└── cluster.yaml        # Generated manifest
```

### Benefits

**Isolation**:
- No shared configuration between management or user clusters
- Changes don't affect other clusters
- Easy to manage independently

**Portability**:
- Copy directory to backup
- Share with team members
- Clear separation between management and user configs

**Clarity**:
- Everything in one place per cluster type
- No searching across directories
- Clear ownership of files

### Git Handling

The `mgmt/` directory is git-ignored:

```gitignore
# .gitignore
mgmt/
```

**Why**:
- Contains secrets (`.env` files with Hetzner tokens)
- Contains generated files (`.yaml` manifests)
- Should not be committed

**Alternative** (for shared configs):
```bash
# Remove secrets before committing
cp mgmt/test/.env mgmt/test/.env.example
sed -i '' 's/HETZNER_TOKEN_BASE64=.*/HETZNER_TOKEN_BASE64=/' mgmt/test/.env.example
# Commit .env.example only (not tracked by default)
```

---

## Configuration Merging

Automatically merge new variables from `.env.example` into existing `.env` files.

### Problem

When `.env.example` is updated with new variables:
- Existing clusters miss new configurations
- Manual copy-paste required
- Easy to miss new variables
- Documentation out of sync

### Solution

Setup script merges new variables automatically:

```bash
merge_env_updates() {
    local env_file=$1
    local example_file="${SCRIPT_DIR}/.env.example"

    # Find variables in example but not in env
    local new_vars=$(comm -23 \
        <(grep -E '^[A-Z_]+=.*' "$example_file" | cut -d= -f1 | sort) \
        <(grep -E '^[A-Z_]+=.*' "$env_file" | cut -d= -f1 | sort))

    if [ -n "$new_vars" ]; then
        # Append new variables with comment
        echo "" >> "$env_file"
        echo "# ── New variables added $(date +%Y-%m-%d) ──" >> "$env_file"

        for var in $new_vars; do
            grep "^${var}=" "$example_file" >> "$env_file"
        done
    fi
}
```

### Example

**`.env.example` updated with**:
```bash
# New feature flag
ENABLE_MONITORING=true
```

**Existing `cluster/my-cluster/.env` updated to**:
```bash
# ... existing variables ...

# ── New variables added 2025-12-01 ──
ENABLE_MONITORING=true
```

### Output

```bash
$ ./setup.sh my-cluster
[INFO] Cluster configuration exists, checking for updates...
[INFO] Found 1 new variable(s) in .env.example
[INFO] Updated cluster/my-cluster/.env with new configuration options
[WARN] Please review the new variables and adjust as needed
```

### Benefits

- **Automatic**: No manual intervention
- **Non-Destructive**: Doesn't modify existing variables
- **Documented**: Adds timestamp comment
- **Safe**: Creates backup before modifying

---

## Context Management

Automatic kubectl context management with consistent naming.

### Context Naming

**Consistent Schema**:
```
<provider>-<cluster-name>
```

**Examples**:
- `kind-production`
- `kind-dev`
- `hcloud-prod-eu`
- `hcloud-staging`

### Automatic Switching

Deploy script automatically switches context:

```bash
# kind provider
switch_context() {
    local cluster_name=$1
    local context_name="kind-${cluster_name}"

    kubectl config use-context "${context_name}" >/dev/null 2>&1
    print_info "Using kubectl context: ${context_name}"
}

# hcloud provider
switch_context() {
    local cluster_name=$1
    local context_name="hcloud-${cluster_name}"

    if ! kubectl config get-contexts "${context_name}" &>/dev/null; then
        print_error "kubectl context not found: ${context_name}"
        return 1
    fi

    kubectl config use-context "${context_name}" >/dev/null 2>&1
    print_info "Using kubectl context: ${context_name}"
}
```

### Manual Context Operations

```bash
# List all contexts
kubectl config get-contexts

# Switch manually
kubectl config use-context kind-production

# Current context
kubectl config current-context

# View context details
kubectl config view --minify
```

### Benefits

- **Safety**: Prevents accidental operations on wrong cluster
- **Clarity**: Context name shows provider and cluster
- **Automation**: No manual context switching needed

---

## Idempotent Operations

Both setup and deploy scripts can be run multiple times safely.

### Setup Script Idempotence

**First Run**:
```bash
$ ./setup.sh my-cluster
[INFO] Creating new cluster configuration...
[INFO] Created cluster/my-cluster/.env from .env.example
[INFO] Generating manifests...
✓ Setup complete
```

**Subsequent Runs**:
```bash
$ ./setup.sh my-cluster
[INFO] Cluster configuration exists, checking for updates...
[INFO] Regenerating manifests...
[INFO] Checking for orphaned manifests...
✓ Manifests updated
```

**Features**:
- Creates `.env` if not exists
- Merges new variables if exists
- Always regenerates manifests
- Cleans up orphaned files

### Deploy Script Idempotence

**First Run**:
```bash
$ ./deploy.sh my-cluster
[INFO] Creating kind cluster: my-cluster
[INFO] Installing k0rdent...
[INFO] Applying manifests...
✓ Deployment complete
```

**Subsequent Runs**:
```bash
$ ./deploy.sh my-cluster
[INFO] Kind cluster already exists: my-cluster
[INFO] k0rdent already installed
[INFO] Applying manifests...
✓ Manifests applied
```

**Features**:
- Checks cluster existence before creating
- Checks k0rdent installation before installing
- Always applies manifests (kubectl handles updates)
- No destructive operations

### Benefits

- **Safe Iteration**: Run repeatedly during development
- **Error Recovery**: Re-run after failures
- **Updates**: Apply configuration changes easily
- **No Side Effects**: Same end state regardless of runs

---

## Additional Features

### Color-Coded Output

Clear visual feedback using colored messages:

```bash
[INFO]  # Green - Success, information
[WARN]  # Yellow - Warnings, non-critical issues
[ERROR] # Red - Errors, critical failures
[DEPLOY] # Blue - Headers, section markers
```

### Validation

**Pre-Flight Checks**:
- Tool availability (kubectl, helm, envsubst, yq)
- Configuration validity (required variables)
- Context existence (for hcloud provider)
- Token detection (hcloud or manual)

**Error Messages**:
```bash
[ERROR] kubectl is not installed or not in PATH
[INFO] Please install kubectl: https://kubernetes.io/docs/tasks/tools/

[ERROR] Required variable HETZNER_TOKEN_BASE64 is not set in cluster/my-cluster/.env
```

### Progress Tracking

Clear indication of current operation:

```bash
[DEPLOY] Deploying cluster: my-cluster

[INFO] Setting up management cluster...

[INFO] Checking requirements...
✓ kind is installed
✓ helm is installed

[INFO] Preparing cluster...
✓ Kind cluster already exists: my-cluster

[INFO] Switching kubectl context...
✓ Using kubectl context: kind-my-cluster

[INFO] Checking k0rdent installation...
✓ k0rdent already installed

✓ Management cluster ready: my-cluster
```

### Help Documentation

Built-in help for all scripts:

```bash
$ ./setup.sh --help
Usage: ./setup.sh [cluster_name]

Arguments:
  cluster_name    Optional. If not provided, a fun name will be generated.

Examples:
  ./setup.sh production
  ./setup.sh dev
  ./setup.sh           # Generates random name like "brave-comet"
```

### Random Cluster Names

Generate fun cluster names if not specified:

```bash
$ ./setup.sh
[SETUP] Generated cluster name: swift-nebula
[SETUP] Setting up cluster: swift-nebula
```

---

## Feature Roadmap

### Planned Features

- [ ] **Backup/Restore**: Automated cluster configuration backup
- [ ] **Validation Mode**: Dry-run validation before deployment
- [ ] **Multi-Region Support**: Deploy across multiple regions simultaneously
- [ ] **Cost Estimation**: Estimate Hetzner costs before deployment
- [ ] **Monitoring Integration**: Built-in Prometheus/Grafana setup
- [ ] **CI/CD Integration**: GitHub Actions workflows
- [ ] **Web UI**: Optional web interface for cluster management
- [ ] **Cluster Migration**: Move clusters between providers
- [ ] **Template Library**: Pre-configured cluster templates
- [ ] **Health Checks**: Automated cluster health verification

### Under Consideration

- [ ] **Terraform Integration**: Export to Terraform for hybrid management
- [ ] **Ansible Integration**: Use Ansible for complex configurations
- [ ] **Secret Management**: Integrate with HashiCorp Vault
- [ ] **RBAC Templates**: Pre-configured RBAC policies
- [ ] **Network Policies**: Template-based network policies
- [ ] **Disaster Recovery**: Automated DR procedures
- [ ] **Cost Optimization**: Automatic cost optimization recommendations

---

## Feature Comparison

| Feature | kind Provider | hcloud Provider |
|---------|--------------|------------------|
| Automatic cluster creation | ✅ | ❌ (manual) |
| Auto k0rdent install | ✅ | ❌ (manual) |
| Local development | ✅ | ❌ |
| Production ready | ❌ | ✅ |
| Cloud costs | ✅ Free | 💰 Paid |
| Multi-user support | ❌ | ✅ |
| Persistent | ❌ | ✅ |
| Requires Docker | ✅ | ❌ |

---

## See Also

- [Architecture Documentation](architecture.md)
- [Main README](../README.md)
- [k0rdent Documentation](https://docs.k0rdent.io/)
