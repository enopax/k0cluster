# Architecture

This document describes the system architecture and design principles of the k0rdent cluster templates project.

## Overview

The system manages two types of Kubernetes clusters:

- **Management Cluster**: Runs k0rdent to provision and manage user clusters (can be local kind or remote k0s)
- **User Clusters**: The actual Kubernetes clusters created on Hetzner for running your applications

The system is designed around three core principles:

1. **Provider Agnosticism**: Support multiple management cluster providers (kind, Hetzner k0s, AWS, etc.)
2. **Template-Based Configuration**: Use environment variables to generate manifests from templates
3. **Self-Contained Configurations**: Each management cluster and user cluster has isolated configuration

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         User Interface                          │
│       (setup.sh, deploy.sh for mgmt; cluster.sh for user)      │
└────────────────────────┬────────────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
┌──────────────┐  ┌─────────────┐  ┌──────────────┐
│   Common     │  │  Provider   │  │    Config    │
│  Functions   │  │   Scripts   │  │              │
│              │  │             │  │ mgmt/*/      │
│ common.sh    │  │  kind.sh    │  │   .env       │
│              │  │ hetzner.sh  │  │ mgmt/*/      │
│ - print_*    │  │             │  │ clusters/*/  │
│ - colors     │  │ - setup     │  │   .env       │
└──────────────┘  │ - validate  │  └──────────────┘
                  │ - deploy    │
                  └─────────────┘
                         │
                         ▼
                ┌─────────────────────────┐
                │  Management Cluster     │
                │  (kind or Hetzner k0s)  │
                │                         │
                │  Runs k0rdent          │
                └────────┬────────────────┘
                         │
                         │ runs
                         ▼
                ┌─────────────────┐
                │   k0rdent       │
                │   (Helm Chart)  │
                └────────┬────────┘
                         │
                         │ provisions
                         ▼
                ┌─────────────────────┐
                │   User Clusters     │
                │   (Hetzner VMs)     │
                │                     │
                │ Your app workloads  │
                └─────────────────────┘
```

## Core Components

### 1. Scripts

#### `setup.sh`
**Purpose**: Configure clusters and generate manifests

**Flow**:
```
1. Parse cluster name argument
2. Create cluster directory (cluster/<name>/)
3. Create/update .env file
   - Copy from .env.example if new
   - Merge new variables if existing
4. Auto-detect Hetzner token from hcloud CLI
5. Validate required variables
6. Package Helm charts (local mode)
7. Generate manifests from templates
   - Loop through manifests/*.yaml
   - Apply environment variable substitution
   - Write to cluster/<name>/*.yaml
8. Clean up orphaned manifests
   - Compare cluster/*.yaml to manifests/*.yaml
   - Remove files that no longer have templates
```

**Key Functions**:
- `generate_cluster_name()` - Generate random cluster names
- `get_hcloud_token()` - Extract token from hcloud CLI
- `merge_env_updates()` - Merge new variables from .env.example
- `process_manifest()` - Apply envsubst to template

#### `deploy.sh`
**Purpose**: Deploy clusters to management clusters

**Flow**:
```
1. Parse cluster name argument
2. Validate cluster directory exists
3. Load .env file
4. Check tool requirements (kubectl, helm)
5. Define common functions
   - k0rdent_installed()
   - verify_connection()
   - setup_management_cluster()
6. Source provider script
7. Setup management cluster
   - Check provider requirements
   - Create/verify cluster
   - Switch kubectl context
   - Install k0rdent if needed
8. Verify connection
9. Apply all manifests
   - kubectl apply -f cluster/<name>/
10. Display monitoring commands
```

**Key Functions**:
- `k0rdent_installed()` - Check if k0rdent is installed
- `verify_connection()` - Verify kubectl connection
- `setup_management_cluster()` - Orchestrate cluster setup

### 2. Provider System

#### Architecture

Providers implement a standard interface, allowing the main deploy script to remain provider-agnostic.

**Interface** (all providers must implement):

```bash
# Check provider-specific requirements
check_requirements()

# Check if cluster exists
cluster_exists()

# Create or verify cluster
create_cluster()

# Return kubectl context name
get_context_name()

# Switch to cluster context
switch_context()

# Install k0rdent (if applicable)
install_k0rdent()
```

**Provider Implementations**:

##### kind.sh
- **Purpose**: Manage local kind clusters
- **Creates**: Docker-based Kubernetes clusters
- **Context**: `kind-<cluster-name>`
- **Auto-installs**: k0rdent via Helm

##### hetzner.sh
- **Purpose**: Manage remote k0s clusters on Hetzner VMs
- **Requires**: Pre-configured kubectl context
- **Context**: `hetzner-<cluster-name>`
- **Manual setup**: k0rdent must be installed manually

#### Provider Selection

```bash
# In cluster/<name>/.env
MGMT_CLUSTER_TYPE=kind     # Uses scripts/provider/kind.sh
MGMT_CLUSTER_TYPE=hetzner  # Uses scripts/provider/hetzner.sh
```

The deploy script dynamically loads the appropriate provider:

```bash
source "${SCRIPT_DIR}/scripts/provider/${MGMT_CLUSTER_TYPE}.sh"
```

### 3. Common Functions

#### `scripts/common.sh`

Shared utilities used by both setup.sh and deploy.sh:

```bash
# Color definitions
RED, GREEN, YELLOW, BLUE, NC

# Print functions
print_info()    # [INFO] messages
print_warn()    # [WARN] messages
print_error()   # [ERROR] messages
print_header()  # Uses $SCRIPT_NAME for prefix
```

**Usage Pattern**:
```bash
SCRIPT_NAME="DEPLOY"  # or "SETUP"
source "${SCRIPT_DIR}/scripts/common.sh"
print_header "Message"  # Shows [DEPLOY] Message
```

### 4. Configuration Structure

#### Directory Layout

**Management Cluster Configuration**:

```
mgmt/<mgmt-name>/        # e.g., "test" or "prod"
├── .env                 # Management cluster config
├── manifests/           # Applied to management cluster
│   ├── credential.yaml
│   ├── secret.yaml
│   └── ...
└── user-clusters/       # User clusters managed by this mgmt cluster
    └── <user-name>/     # e.g., "production", "staging"
        ├── .env         # User cluster config
        └── cluster.yaml # Applied to mgmt → creates Hetzner VMs
```

#### Management Cluster Configuration (`.env`)

```bash
# Management cluster provider
MGMT_CLUSTER_TYPE=kind       # kind or hetzner

# Shared Hetzner credentials
HETZNER_TOKEN_BASE64=...

# Kubernetes namespace
CLUSTER_NAMESPACE=kcm-system

# Helm charts
PROVIDER_CHART_SOURCE=oci://ghcr.io/enopax/templates/...
```

#### User Cluster Configuration (`.env`)

```bash
# User cluster name (automatically set)
CLUSTER_NAME=production

# Hetzner infrastructure
HETZNER_REGION=fsn1
CONTROL_PLANE_COUNT=1
WORKER_COUNT=2               # Worker nodes for your applications
CONTROL_PLANE_MACHINE_TYPE=cx21
WORKER_MACHINE_TYPE=cx21

# Kubernetes version
K0S_VERSION=v1.32.6+k0s.1

# Helm chart for user cluster
CLUSTER_CHART_SOURCE=oci://ghcr.io/enopax/templates/hetzner-standalone-cp:1.0.0
```

### 5. Template System

#### Flow

```
manifests/*.yaml  →  envsubst  →  cluster/<name>/*.yaml
     (templates)    (substitution)    (generated)
```

#### Example

**Template** (`manifests/cluster.yaml`):
```yaml
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: ClusterDeployment
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${CLUSTER_NAMESPACE}
spec:
  template: hetzner-standalone-cp
  credential: ${CLUSTER_NAME}-credential
```

**Generated** (`cluster/my-cluster/cluster.yaml`):
```yaml
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: ClusterDeployment
metadata:
  name: my-cluster
  namespace: kcm-system
spec:
  template: hetzner-standalone-cp
  credential: my-cluster-credential
```

### 6. Orphaned Manifest Cleanup

#### Problem

When templates are removed from `manifests/`, old generated files remain in `cluster/<name>/`, potentially causing:
- Deployment of obsolete resources
- Configuration drift
- Confusion about active resources

#### Solution

The setup script tracks template files and removes orphaned manifests:

```bash
# 1. Track current templates
TEMPLATE_FILES=()
for manifest in manifests/*.yaml; do
    TEMPLATE_FILES+=("$(basename "$manifest")")
done

# 2. Generate manifests (as usual)
for manifest in manifests/*.yaml; do
    process_manifest "$(basename "$manifest")"
done

# 3. Remove orphans (only for existing clusters)
if [ "$CLUSTER_EXISTS" = true ]; then
    for cluster_file in cluster/<name>/*.yaml; do
        filename=$(basename "$cluster_file")
        if [[ ! " ${TEMPLATE_FILES[@]} " =~ " ${filename} " ]]; then
            rm -f "$cluster_file"
        fi
    done
fi
```

## Data Flow

### Management Cluster Setup Flow

```
┌─────────────────┐
│   User          │
│ ./setup.sh test │
└──────┬──────────┘
       │
       ▼
┌─────────────────────────┐
│ Create mgmt dir         │
│ mgmt/test/              │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Create/update .env      │
│ - Copy from .env.example│
│ - Auto-detect token     │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Generate manifests      │
│ - envsubst templates    │
│ - Write to mgmt/test/   │
│   manifests/            │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Clean up orphans        │
│ - Remove old manifests  │
└─────────────────────────┘
```

### Management Cluster Deployment Flow

```
┌─────────────────┐
│   User          │
│ ./deploy.sh test│
└──────┬──────────┘
       │
       ▼
┌─────────────────────────┐
│ Load configuration      │
│ - mgmt/test/.env        │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Source provider script  │
│ - scripts/provider/     │
│   kind.sh or hetzner.sh │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Setup mgmt cluster      │
│ - check_requirements    │
│ - create_cluster        │
│ - switch_context        │
│ - install_k0rdent       │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Apply manifests         │
│ kubectl apply -f        │
│   mgmt/test/manifests/  │
└─────────────────────────┘
```

### User Cluster Creation Flow

```
┌──────────────────────────┐
│   User                   │
│ ./cluster.sh create      │
│   production             │
└──────┬───────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Create user cluster dir │
│ mgmt/test/user-clusters/│
│   production/           │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Generate manifests      │
│ - From manifests/       │
│   user-cluster/         │
│ - Write to user-        │
│   clusters/production/  │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Ready for deployment    │
│ (no Hetzner VMs yet)    │
└─────────────────────────┘
```

### User Cluster Deployment Flow

```
┌──────────────────────────┐
│   User                   │
│ ./cluster.sh deploy      │
│   production             │
└──────┬───────────────────┘
       │
       ▼
┌─────────────────────────┐
│ Apply to mgmt cluster   │
│ kubectl apply -f        │
│   mgmt/test/            │
│   user-clusters/        │
│   production/           │
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ k0rdent receives        │
│ ClusterDeployment       │
│ resource on mgmt cluster│
└──────┬──────────────────┘
       │
       ▼
┌─────────────────────────┐
│ k0rdent provisions      │
│ Hetzner VMs for user    │
│ cluster "production"    │
└─────────────────────────┘
```

## Design Principles

### 1. Provider Agnosticism

The core deployment logic is provider-agnostic. Providers implement a standard interface, allowing new providers to be added without modifying deploy.sh.

**Benefits**:
- Easy to add new providers (AWS, GCP, Azure, etc.)
- Core logic remains stable
- Testable in isolation

### 2. Function Definition Order

Functions are defined BEFORE sourcing providers:

```bash
# deploy.sh structure
source common.sh                # Shared utilities
define common functions         # k0rdent_installed, etc.
source provider script          # Can use/override common functions
call orchestration functions    # setup_management_cluster
```

This allows providers to:
- Use common functions (print_info, etc.)
- Override common functions if needed
- Call other common functions

### 3. Self-Contained Configurations

Each configuration is isolated in its own directory:

**Management Cluster**:
```
mgmt/test/
├── .env          # Management cluster config
├── manifests/    # Applied to management cluster
└── user-clusters/# User clusters managed by this mgmt
```

**User Cluster**:
```
mgmt/test/user-clusters/production/
├── .env          # User cluster config
└── cluster.yaml  # User cluster manifest
```

**Benefits**:
- Easy to manage multiple management and user clusters
- No root-level clutter
- Git-friendly (mgmt/ in .gitignore)
- Clear separation between management and user configs

### 4. Idempotent Operations

Both setup.sh and deploy.sh are idempotent:

**setup.sh**:
- Re-running regenerates manifests
- Updates .env with new variables
- Cleans up orphaned files

**deploy.sh**:
- Re-running re-applies manifests
- Checks if cluster exists before creating
- Checks if k0rdent is installed before installing

### 5. Fail Fast

Scripts exit immediately on errors:

```bash
set -e  # Exit on any command failure
```

Each critical operation checks for success:

```bash
if ! check_requirements; then
    print_error "Requirements check failed"
    return 1
fi
```

## Security Considerations

### Secrets Management

1. **Environment Files**:
   - `.env` files contain secrets (tokens, credentials)
   - Stored in cluster directories (ignored by git)
   - Never committed to version control

2. **.gitignore Coverage**:
   ```
   .env
   .env.*
   *.env
   cluster/
   ```

3. **Token Encoding**:
   - Hetzner tokens are base64-encoded
   - Auto-detected from hcloud CLI (never displayed)
   - Manual encoding: `echo -n "token" | base64`

### kubectl Context Isolation

Each cluster uses a unique kubectl context:

```
kind-production      # Local kind cluster for 'production'
kind-dev            # Local kind cluster for 'dev'
hetzner-prod-eu     # Remote cluster for 'prod-eu'
```

This prevents accidental operations on wrong clusters.

## Extension Points

### Adding New Providers

1. Create `scripts/provider/<name>.sh`
2. Implement required interface:
   - check_requirements
   - cluster_exists
   - create_cluster
   - get_context_name
   - switch_context
   - install_k0rdent
3. Set `MGMT_CLUSTER_TYPE=<name>` in cluster config

### Adding New Templates

1. Add template to `manifests/<name>.yaml`
2. Use environment variables: `${VAR_NAME}`
3. Run `./setup.sh <cluster>` to generate
4. Manifest automatically applied on deploy

### Adding New Configuration Variables

1. Add to `.env.example`
2. Run `./setup.sh <cluster>` (auto-merges new variables)
3. Use in templates: `${NEW_VAR}`

## Testing Strategy

### Script Validation

```bash
# Syntax checking
bash -n setup.sh
bash -n deploy.sh
bash -n scripts/provider/*.sh

# Function testing
# Test individual functions in isolation
source scripts/common.sh
print_info "Test message"
```

### Provider Testing

```bash
# Test provider interface
source scripts/provider/kind.sh
check_requirements
get_context_name "test"
```

### Integration Testing

```bash
# Full workflow test
./setup.sh test-cluster
./deploy.sh test-cluster
# Verify deployment
kubectl get clusterdeployment test-cluster -n kcm-system
```

## Performance Considerations

### Caching

- Helm chart packaging is idempotent (skips unchanged charts)
- Provider checks are fast (command existence checks)

### Parallel Operations

- Multiple manifests applied in single kubectl command
- kubectl handles ordering via dependencies

### Resource Usage

- kind clusters: ~2GB RAM, minimal CPU
- Remote clusters: No local resource usage

## Future Enhancements

1. **Multi-cloud Support**: AWS, GCP, Azure providers
2. **Cluster Templates**: Pre-configured cluster types
3. **Backup/Restore**: Automated backup of cluster configs
4. **Validation**: Pre-deployment validation of configs
5. **Monitoring Integration**: Built-in monitoring setup
6. **CI/CD Integration**: GitHub Actions for automation
7. **Web UI**: Optional web interface for management

## References

- [k0rdent Documentation](https://docs.k0rdent.io/)
- [Hetzner Cloud API](https://docs.hetzner.cloud/)
- [kind Documentation](https://kind.sigs.k8s.io/)
- [k0s Documentation](https://docs.k0sproject.io/)
