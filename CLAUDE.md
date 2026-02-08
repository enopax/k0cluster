# CLAUDE.md - k0rdent Hetzner Templates

**Last Updated**: 2025-12-08

---

## Project Overview

This repository provides Helm charts, manifests, and automation scripts for deploying k0rdent management clusters and provisioning Kubernetes clusters on Hetzner Cloud infrastructure.

**Key Components:**
- k0rdent management cluster setup (kind or Hetzner)
- Cluster API Provider Hetzner (CAPH) integration
- Custom cluster templates for k0s on Hetzner
- Automated setup scripts

---

## Repository Structure

```
.
├── charts/                                 # Helm charts
│   ├── hetzner-standalone-cp/              # Hetzner k0s cluster template
│   └── cluster-api-provider-hetzner/       # Hetzner CAPI provider
│
├── manifests/                              # Kubernetes manifests
│   ├── mgmt/                               # Management cluster resources
│   │   ├── management.yaml                 # k0rdent Management resource
│   │   ├── helm-custom-repo.yaml           # HelmRepository for custom charts
│   │   ├── hetzner-providertemplate.yaml   # CAPH ProviderTemplate
│   │   ├── hetzner-clustertemplate.yaml    # ClusterTemplate
│   │   └── credential.yaml                 # Credential resource
│   └── user-cluster/                       # User cluster definitions
│       └── cluster-01.yaml                 # Example ClusterDeployment
│
├── scripts/                                # Automation scripts
│   └── setup-k0rdent-mgmt.sh               # Automated management cluster setup
│
└── docs/                                   # Documentation
    ├── getting-started/                    # Setup guides
    ├── charts/                             # Chart management
    └── k0rdent/                            # k0rdent integration guides
```

---

## Critical Setup Order

When deploying the management cluster, manifests **must be applied in this order**:

1. `management.yaml` - Creates Management resource
2. `helm-custom-repo.yaml` - Creates HelmRepository for custom charts
3. `hetzner-providertemplate.yaml` - **MUST exist before Management reconciles**
4. Wait for Management to be ready
5. `hetzner-clustertemplate.yaml` - Cluster template for user clusters
6. `credential.yaml` - Credential resource (references Secret)
7. Create `hcloud-cluster-provisioning-token` Secret with Hetzner API token

**Why this order matters:** The Management resource references the ProviderTemplate (`cluster-api-provider-hetzner-0-0-26`) in its spec. If the ProviderTemplate doesn't exist when Management reconciles, it will fail with "ProviderTemplate not found" and timeout.

---

## Automated Setup Script

The `scripts/setup-k0rdent-mgmt.sh` script handles the complete setup process:

**What it does:**
1. Creates kind cluster
2. Installs k0rdent v1.5.0
3. Applies Management resource
4. Applies HelmRepository and ProviderTemplate (in correct order)
5. Waits for CAPI to be ready
6. Waits for CAPH deployment
7. Applies ClusterTemplate
8. Configures credentials from hcloud CLI
9. Verifies installation

**Recent improvements (2025-12-08):**
- Fixed ProviderTemplate application order (now applied before waiting for Management)
- Renamed `apply_provider_template()` → `wait_for_provider()` for clarity
- Removed redundant manifest re-applications
- Script now completes successfully without manual intervention

---

## Key Technologies

- **k0rdent**: Multi-cluster management platform
- **Cluster API (CAPI)**: Kubernetes cluster lifecycle management
- **CAPH**: Cluster API Provider Hetzner (v1.0.7)
- **k0s**: Lightweight Kubernetes distribution
- **kind**: Kubernetes in Docker (for local dev)
- **Helm**: Package manager for Kubernetes

---

## Development Workflow

### Testing Changes Locally

```bash
# 1. Run automated setup
./scripts/setup-k0rdent-mgmt.sh

# 2. Deploy test cluster
kubectl apply -f manifests/user-cluster/cluster-01.yaml

# 3. Monitor deployment
kubectl get clusterdeployments -n kcm-system
kubectl get clusters -n kcm-system

# 4. Clean up
kind delete cluster --name k0rdent
```

### Modifying Charts

```bash
# 1. Edit chart in charts/
cd charts/hetzner-standalone-cp

# 2. Update version in Chart.yaml

# 3. Package chart
helm package .

# 4. Authenticate to GHCR
gh auth token | helm registry login ghcr.io -u $(gh api user -q .login) --password-stdin

# 5. Push to registry
helm push hetzner-standalone-cp-<version>.tgz oci://ghcr.io/enopax/templates

# 6. Update manifest references to new version
```

---

## Common Issues & Solutions

### Issue: "ProviderTemplate not found"

**Cause:** ProviderTemplate was not applied before Management reconciliation.

**Solution:** The automated script now handles this correctly. For manual setup, ensure you:
1. Apply `hetzner-providertemplate.yaml` before waiting for Management
2. Verify: `kubectl get providertemplate cluster-api-provider-hetzner-0-0-26`

### Issue: CAPH pods not starting

**Cause:** Missing HelmChart or HelmRelease.

**Solution:**
```bash
# Check HelmChart exists
kubectl get helmchart -n kcm-system | grep hetzner

# Check HelmRelease
kubectl get helmrelease -n kcm-system | grep hetzner

# Check CAPH pod
kubectl get pods -n kcm-system | grep caph
```

### Issue: Cluster deployment stuck in "Provisioning"

**Cause:** Usually credential or network issues.

**Solution:**
```bash
# Check credential exists
kubectl get credential hcloud-cluster-provisioning -n kcm-system

# Check secret exists and has correct labels
kubectl get secret hcloud-cluster-provisioning-token -n kcm-system --show-labels

# Check CAPH controller logs
kubectl logs -n kcm-system -l cluster.x-k8s.io/provider=infrastructure-hetzner
```

---

## Credential System

k0rdent uses a two-part credential system:

1. **Credential Resource** (`hcloud-cluster-provisioning`)
   - References where to find the token
   - Applied via `credential.yaml`

2. **Secret** (`hcloud-cluster-provisioning-token`)
   - Contains actual Hetzner API token
   - Created via `kubectl create secret`
   - Requires specific labels: `caph.environment=owned`, `k0rdent.mirantis.com/component=kcm`

**Data flow:**
```
ClusterDeployment
  └─> spec.credential: "hcloud-cluster-provisioning"
      └─> Credential resource
          └─> spec.identityRef.name: "hcloud-cluster-provisioning-token"
              └─> Secret with Hetzner API token
```

---

## Version Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| k0rdent | 1.5.0 | Management platform |
| CAPH | v1.0.7 | Infrastructure provider |
| CAPI | v1.0.7 | Core Cluster API |
| k0s | v1.32.6+k0s.0 | Kubernetes distribution |
| Kubernetes (kind) | v1.34.0 | Kind cluster version |

---

## Important Files

- `scripts/setup-k0rdent-mgmt.sh` - Main setup automation
- `manifests/mgmt/management.yaml` - Defines which providers to install
- `manifests/mgmt/hetzner-providertemplate.yaml` - CAPH deployment config
- `manifests/mgmt/hetzner-clustertemplate.yaml` - User cluster template
- `charts/cluster-api-provider-hetzner/` - CAPH Helm chart (v0.0.26)
- `charts/hetzner-standalone-cp/` - k0s cluster template (v1.0.0)

---

## Testing & Verification

After running the setup script, verify:

```bash
# Management cluster is ready
kubectl get management kcm -n kcm-system

# CAPH is installed and ready
kubectl get infrastructureprovider -A
# Should show: hetzner   v1.0.7   True

# CAPH CRDs are installed
kubectl get crd | grep hetzner

# CAPH controller is running
kubectl get pods -n kcm-system | grep caph-controller-manager
```

---

## Related Projects

This repository is part of the **Enopax** organization infrastructure provisioning ecosystem:

- **Platform**: Full-featured Next.js platform for infrastructure provisioning
- **Resource API**: Script-based provider framework
- **Git Provider**: Git repository provisioning
- **Agent Provider**: AI agent provisioning (planned)

See parent `CLAUDE.md` at `/Users/felix/work/enopax/CLAUDE.md` for full organizational overview.

---

## References

- [k0rdent Documentation](https://docs.k0rdent.io/)
- [Cluster API Provider Hetzner](https://github.com/syself/cluster-api-provider-hetzner)
- [k0s Documentation](https://docs.k0sproject.io/)
- [Hetzner Cloud API](https://docs.hetzner.cloud/)

---

*This file provides context for AI assistants working on this codebase.*
