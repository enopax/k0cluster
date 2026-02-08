# How to Add a Custom Provider to k0rdent

**Status**: Work in Progress
**Last Updated**: 2025-12-04

---

## Overview

This guide documents how to properly integrate a custom Cluster API (CAPI) provider into k0rdent, based on investigation of the k0rdent architecture and documentation.

---

## k0rdent Provider Architecture

### Component Hierarchy

```
Management (kcm)
    ↓ references
Release (kcm-1-5-0)
    ↓ contains
ProviderTemplate (cluster-api-provider-xyz-1-0-0)
    ↓ references
HelmChart (via HelmRepository)
    ↓ deploys
InfrastructureProvider (xyz)
    ↓ manages
Cluster Resources
```

### Key Resources

1. **Management** - Top-level k0rdent configuration
   - References a Release
   - Lists providers to deploy
   - Tracks which providers are available

2. **Release** - Package of ProviderTemplates
   - Defines which provider versions to use
   - Installed via Helm chart
   - Contains core CAPI + providers

3. **ProviderTemplate** - Defines how to install a provider
   - Points to Helm chart
   - Specifies CAPI contracts (v1beta1, etc.)
   - Must be in `kcm-system` namespace

4. **HelmRepository** - Source for Helm charts
   - Must have label: `k0rdent.mirantis.com/managed: "true"`
   - Can be OCI or traditional Helm repo

5. **InfrastructureProvider** - Actual CAPI provider instance
   - Created by deploying the ProviderTemplate
   - Manages infrastructure resources

---

## Prerequisites

### 1. Helm Chart

Your provider must be available as a Helm chart that creates an `InfrastructureProvider` resource.

**Example structure**:
```
cluster-api-provider-hetzner/
  ├── Chart.yaml
  ├── values.yaml
  └── templates/
      ├── provider.yaml       # InfrastructureProvider
      ├── interface.yaml      # ProviderInterface (optional)
      ├── rbac.yaml           # RBAC rules (optional)
      └── secret.yaml         # Secret template (optional)
```

**Chart.yaml annotations** (optional but recommended):
```yaml
annotations:
  cluster.x-k8s.io/provider: infrastructure-hetzner
  cluster.x-k8s.io/v1beta1: v1beta1
```

### 2. HelmRepository

Create or use an existing HelmRepository:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: custom-repo
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/managed: "true"  # REQUIRED
spec:
  type: oci
  url: oci://ghcr.io/your-org/templates
  interval: 10m
```

**Critical**: The `k0rdent.mirantis.com/managed: "true"` label is **required** for k0rdent to recognize this repository.

### 3. Chart Compatibility

Your provider chart must:
- Create an `operator.cluster.x-k8s.io/v1alpha2/InfrastructureProvider` resource
- Be compatible with the CAPI version in your k0rdent (check: `kubectl get coreprovider -A`)
- Support the manager configuration fields that CAPI operator injects
  - **Note**: Older providers may not support `--diagnostics-address` or `--insecure-diagnostics` flags

---

## Method 1: Manual Provider Addition (Current Approach)

This method adds a provider outside of the Release system. It works for the InfrastructureProvider but has issues with Management registration.

### Step 1: Create HelmRepository

```bash
kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: custom-repo
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/managed: "true"
spec:
  type: oci
  url: oci://ghcr.io/enopax/templates
  interval: 10m
EOF
```

### Step 2: Create ProviderTemplate

```bash
kubectl apply -f - <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ProviderTemplate
metadata:
  name: cluster-api-provider-hetzner-0-0-7
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/component: kcm
spec:
  helm:
    chartSpec:
      chart: cluster-api-provider-hetzner
      version: 0.0.7
      interval: 10m
      sourceRef:
        kind: HelmRepository
        name: custom-repo
EOF
```

### Step 3: Add to Management

```bash
kubectl patch management kcm --type='json' -p='[
  {"op": "add", "path": "/spec/providers/-", "value": {"name": "cluster-api-provider-hetzner-0-0-7"}}
]'
```

### Status

✅ **Works**:
- ProviderTemplate is created and valid
- HelmChart is pulled and ready
- InfrastructureProvider can be installed manually

❌ **Doesn't Work**:
- Provider doesn't appear in Management `availableProviders`
- ClusterDeployment webhook rejects due to missing provider
- Management controller errors: `ProviderTemplate "" not found`

**Root Cause**: Management controller expects providers to come from a Release, not added directly.

---

## Method 2: Release-Based Integration (Recommended - In Progress)

This is the proper k0rdent way but requires more investigation.

### Concept

Instead of adding the provider directly to Management, add it to a Release. The Management then discovers providers through the Release.

### Step 1: Understand Release Structure

```bash
$ kubectl get release kcm-1-5-0 -o yaml

apiVersion: k0rdent.mirantis.com/v1beta1
kind: Release
metadata:
  name: kcm-1-5-0
spec:
  version: 1.5.0
  capi:
    template: cluster-api-1-0-7
  kcm:
    template: kcm-1-5-0
  providers:
  - name: cluster-api-provider-aws
    template: cluster-api-provider-aws-1-0-7
  - name: cluster-api-provider-azure
    template: cluster-api-provider-azure-1-0-9
  # ...etc
```

### Step 2: Options for Extending Release

**Option A: Patch Existing Release**
```bash
kubectl patch release kcm-1-5-0 --type='json' -p='[
  {"op": "add", "path": "/spec/providers/-", "value": {
    "name": "cluster-api-provider-hetzner",
    "template": "cluster-api-provider-hetzner-0-0-7"
  }}
]'
```

**Risk**: Release is managed by Helm, patching may be overwritten on upgrade.

**Option B: Create Custom Release** (Not yet tested)

Create a new Release that extends the base:

```yaml
apiVersion: k0rdent.mirantis.com/v1beta1
kind: Release
metadata:
  name: kcm-1-5-0-custom
spec:
  version: 1.5.0-custom
  capi:
    template: cluster-api-1-0-7
  kcm:
    template: kcm-1-5-0
  providers:
  # Copy all providers from kcm-1-5-0
  - name: cluster-api-provider-k0sproject-k0smotron
    template: cluster-api-provider-k0sproject-k0smotron-1-0-11
  # ... all others ...
  # Add custom provider
  - name: cluster-api-provider-hetzner
    template: cluster-api-provider-hetzner-0-0-7
```

Then update Management to reference new Release:

```bash
kubectl patch management kcm --type='merge' -p='{"spec":{"release":"kcm-1-5-0-custom"}}'
```

**Option C: Helm Values Override**

When installing k0rdent, include custom providers in Helm values:

```yaml
# values-custom.yaml
providers:
  - name: cluster-api-provider-hetzner
    template: cluster-api-provider-hetzner-0-0-7
```

```bash
helm upgrade kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
  --version 1.5.0 \
  -n kcm-system \
  -f values-custom.yaml
```

---

## Method 3: ProviderInterface Only (Alternative)

If the InfrastructureProvider is already installed (e.g., manually via Helm), you might only need to create a ProviderInterface.

```yaml
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ProviderInterface
metadata:
  name: cluster-api-provider-hetzner
spec:
  clusterGVKs:
  - group: infrastructure.cluster.x-k8s.io
    version: v1beta1
    kind: HetznerCluster
  clusterIdentityKinds:
  - HCloudTokenRef
  description: "Hetzner infrastructure provider for Cluster API"
```

**Status**: Tested - ProviderInterface exists but doesn't solve the Management registration issue.

---

## Debugging Provider Registration

### Check Provider Discovery

```bash
# Check if ProviderTemplate is valid
kubectl get providertemplate cluster-api-provider-hetzner-0-0-7

# Check what providers Management sees
kubectl get management kcm -o jsonpath='{.status.availableProviders}'

# Check Management components status
kubectl get management kcm -o json | jq '.status.components'

# Check for errors in Management controller
kubectl logs -n kcm-system -l control-plane=kcm-controller-manager | grep -i hetzner
```

### Verify InfrastructureProvider

```bash
# Is it installed?
kubectl get infrastructureproviders -A

# Is it ready?
kubectl get infrastructureprovider hetzner -n kcm-system

# Check provider contract
kubectl get infrastructureprovider hetzner -n kcm-system -o jsonpath='{.status.contract}'
```

### Test ClusterTemplate

```bash
# Does template reference correct providers?
kubectl describe clustertemplate hetzner-standalone-cp -n kcm-system | grep "Providers:"
```

---

## Known Issues

### Issue 1: Management Controller Error

**Symptom**:
```json
{
  "error": "Failed to get ProviderTemplate : ProviderTemplate.k0rdent.mirantis.com \"\" not found"
}
```

**Cause**: Management controller looks up providers in Release context, but provider was added to Management.spec directly.

**Workaround**: Pending - investigating Release-based registration.

### Issue 2: Provider Not in availableProviders

**Symptom**: `infrastructure-hetzner` missing from Management status even though InfrastructureProvider is healthy.

**Cause**: Provider not properly registered through Release mechanism.

**Impact**: ClusterDeployment webhook rejects requests:
```
failed to validate required providers: one or more required providers are not deployed yet: [infrastructure-hetzner]
```

### Issue 3: CAPH v1.0.7 Flag Incompatibility

**Symptom**:
```
unknown flag: --diagnostics-address
unknown flag: --insecure-diagnostics
```

**Cause**: CAPI operator uses newer flag schema that CAPH v1.0.7 doesn't support.

**Solution**: ✅ Fixed in chart v0.0.7 by removing manager config from template.

---

## Best Practices

### 1. Use Releases for Production

Don't manually add providers. Instead:
- Create a custom Release
- Or use Helm values to extend the base Release
- This ensures providers are properly registered

### 2. Label Everything

Required labels:
- HelmRepository: `k0rdent.mirantis.com/managed: "true"`
- ProviderTemplate: `k0rdent.mirantis.com/component: kcm`

### 3. Version Your Providers

Use semantic versioning in ProviderTemplate names:
- ✅ `cluster-api-provider-hetzner-0-0-7`
- ❌ `cluster-api-provider-hetzner-latest`

### 4. Test with Webhooks Enabled

Don't disable admission webhooks just to bypass validation. Fix the root cause instead.

### 5. Check CAPI Compatibility

Ensure your provider supports the flags that CAPI operator injects:
- `--leader-elect`
- `--diagnostics-address` (or `--metrics-bind-address` for older providers)
- `--insecure-diagnostics` (or handle gracefully)

---

## Next Steps

1. **Research Release Extension** - Understand if custom Releases are supported
2. **Check k0rdent GitHub** - Look for examples of custom provider integration
3. **Test Release Patching** - Try modifying Release directly
4. **Community Support** - Ask in k0rdent Slack/Discussions

---

## References

- **k0rdent Documentation**: https://docs.k0rdent.io/
- **BYO Templates Guide**: https://docs.k0rdent.io/latest/reference/template/template-byo/
- **Templating System**: https://docs.k0rdent.io/latest/templatehowto/the-templating-system-common-threads/
- **Provider Requirements**: https://docs.k0rdent.io/latest/appendix/appendix-providers/
- **k0rdent GitHub**: https://github.com/k0rdent/kcm/

---

## Commands Reference

```bash
# List all provider-related resources
kubectl get providertemplates -A
kubectl get providerinterfaces -A
kubectl get infrastructureproviders -A
kubectl get releases -A
kubectl get helmrepositories -A

# Check Management status
kubectl describe management kcm
kubectl get management kcm -o yaml

# Debug provider registration
kubectl logs -n kcm-system -l control-plane=kcm-controller-manager | grep -E "provider|error"

# Test ClusterDeployment (will fail if provider not registered)
kubectl apply -f manifests/user-cluster/cluster-01.yaml --dry-run=server
```

---

**Status**: This guide is a work in progress. The proper Release-based integration method is still under investigation.
