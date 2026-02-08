# K0rdent Templates

Helm chart templates and manifests for deploying k0rdent management clusters and provisioning Kubernetes clusters on Hetzner Cloud.

**For New Users:** Start with the [Complete Integration Guide](./docs/k0rdent/hetzner-provider-integration-complete.md) for step-by-step instructions on deploying the Hetzner provider to your k0rdent cluster.

## 🎯 Two Deployment Options

This repository now supports **two types** of Kubernetes cluster deployments:

1. **Hosted Control Plane** (NEW!) - Control plane runs as pods in management cluster
   - **50% cost savings** - No control plane VMs needed
   - **Fast provisioning** - Pods start in seconds
   - **Ideal for:** Dev/test, multi-tenant platforms, cost optimization
   - [📖 Full Documentation](./docs/charts/hetzner-hosted-cp.md)

2. **Standalone Control Plane** (Traditional) - Control plane on dedicated Hetzner VMs
   - **Complete isolation** - Independent failure domains
   - **Compliance friendly** - Meets strict requirements
   - **Ideal for:** Production, large clusters, compliance needs

---

## What is This?

This repository provides everything needed to:

1. **Deploy a k0rdent management cluster** (locally with kind or remotely on Hetzner)
2. **Provision Kubernetes clusters** on Hetzner Cloud infrastructure
3. **Package and distribute** custom cluster templates via OCI registry

## Repository Structure

```
.
├── charts/                                 # Helm charts
│   ├── hetzner-standalone-cp/              # Standalone CP template
│   ├── hetzner-hosted-cp/                  # Hosted CP template (NEW!)
│   └── cluster-api-provider-hetzner/       # Hetzner CAPI provider
│
├── manifests/                              # Kubernetes manifests
│   ├── mgmt/                        # Management cluster resources
│   │   ├── credential.yaml          # Hetzner credential config
│   │   ├── helm-custom-repo.yaml    # Helm repository config
│   │   ├── hetzner-standalone-clustertemplate.yaml  # Standalone template
│   │   ├── hetzner-hosted-clustertemplate.yaml  # Hosted template (NEW!)
│   │   └── hetzner-providertemplate.yaml # Provider template
│   └── user-cluster/                # User cluster definitions
│       ├── cluster-01.yaml          # Standalone example
│       └── cluster-hosted.yaml      # Hosted example (NEW!)
│
├── docs/                            # Documentation
│   ├── getting-started/             # Getting started guides
│   └── charts/                      # Chart management guides
│       ├── hetzner-hosted-cp.md     # Hosted CP guide (NEW!)
│       └── package-and-publish.md   # Publishing guide
│
├── k0sctl-hetzner.yaml             # k0sctl example config
└── README.md                        # This file
```

## Quick Start

**Prerequisites:** See [Prerequisites Guide](./docs/getting-started/prerequisites.md)

### Automated Setup (Recommended)

Use the automated setup script for a complete installation:

```bash
./scripts/setup-k0rdent-mgmt.sh
```

This script will:
- Create a kind cluster
- Install k0rdent v1.5.0
- Deploy the Hetzner provider (CAPH)
- Apply cluster templates
- Configure credentials from your hcloud CLI
- Verify the installation

**Time:** ~5-10 minutes for complete setup

### Manual Setup

If you prefer manual installation:

#### 1. Create kind Cluster

```bash
kind create cluster --name k0rdent
```

#### 2. Install k0rdent

```bash
helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
  --version 1.5.0 \
  -n kcm-system \
  --set regional.telemetry.mode=disabled \
  --set regional.velero.enabled=false \
  --set="controller.createManagement=false" \
  --create-namespace
```

#### 3. Apply Templates and Configure Credentials

```bash
# Apply management resources (in order)
kubectl apply -f manifests/mgmt/management.yaml
kubectl apply -f manifests/mgmt/helm-custom-repo.yaml
kubectl apply -f manifests/mgmt/hetzner-providertemplate.yaml
kubectl apply -f manifests/mgmt/hetzner-standalone-clustertemplate.yaml
kubectl apply -f manifests/mgmt/hetzner-hosted-clustertemplate.yaml
kubectl apply -f manifests/mgmt/credential.yaml

# Create Hetzner API secret
kubectl create secret generic hcloud-cluster-provisioning-token \
  --from-literal=hcloud=$(hcloud config get token --allow-sensitive) \
  --namespace kcm-system
kubectl label secret hcloud-cluster-provisioning-token -n kcm-system \
  caph.environment=owned k0rdent.mirantis.com/component=kcm

# Deploy user cluster
kubectl apply -f manifests/user-cluster/cluster-01.yaml
```

#### 4. Verify

```bash
kubectl get clusters
kubectl get clusterdeployments
kubectl get infrastructureproviders -A
```

## 💰 Cost Comparison

### Example: 3 Clusters (2 workers each)

**Hosted CP:**
```
Management cluster (one-time): €15/month (3x CPX11 nodes)

Per user cluster: €10/month (2x CPX11 workers only)

Total: €15 + (€10 × 3) = €45/month
```

**Standalone CP:**
```
Per user cluster: €31/month
  - 3x CPX11 control plane: €15
  - 2x CPX11 workers: €10
  - Load balancer: €6

Total: €31 × 3 = €93/month
```

**💰 Savings: €48/month (52% reduction) with hosted CP!**

## 🆚 Quick Comparison

| Feature | Hosted CP | Standalone CP |
|---------|-----------|---------------|
| **Cost** | 💰 Low | 💰💰 Medium-High |
| **Provisioning** | ⚡ 2-3 min | 🐌 5-10 min |
| **Isolation** | ⚠️ Shared | ✅ Complete |
| **Scaling** | ⚡ Instant | 🐌 Slow |
| **Best for** | Dev/Test/Multi-tenant | Production/Compliance |

[📖 Detailed Comparison Guide](./docs/charts/hetzner-hosted-cp.md#comparison-matrix)

## Detailed Guides

**Getting Started:**
- [Prerequisites](./docs/getting-started/prerequisites.md) - Install required tools
- [Setup with kind](./docs/getting-started/setup-kind.md) - Local development cluster
- [Setup on Hetzner](./docs/getting-started/setup-hetzner.md) - Remote production cluster

**Hetzner Provider Integration:**
- [Complete Integration Guide](./docs/k0rdent/hetzner-provider-integration-complete.md) - ✅ **Comprehensive guide to using CAPH with k0rdent**
- [Integration Status](./docs/status/integration-status.md) - Current implementation status
- [Lessons Learned](./docs/k0rdent/lessons-learned.md) - Technical insights from integration process
- [Root Cause Analysis](./docs/k0rdent/root-cause-analysis.md) - Deep dive into webhook validation

**Chart Management:**
- [Hetzner Hosted CP Chart](./docs/charts/hetzner-hosted-cp.md) - ⭐ **Complete guide to hosted control planes**
- [Package and Publish Charts](./docs/charts/package-and-publish.md) - Build and publish Helm charts

## Working with Charts

See [Package and Publish Charts](./docs/charts/package-and-publish.md) for detailed instructions on:
- Packaging Helm charts
- Authenticating to GitHub Container Registry
- Publishing charts to OCI registry
- Version management
- Troubleshooting

**Quick reference:**
```bash
# Package
cd charts/hetzner-standalone-cp && helm package .

# Authenticate
gh auth token | helm registry login ghcr.io -u $(gh api user -q .login) --password-stdin

# Push
helm push hetzner-standalone-cp-1.0.0.tgz oci://ghcr.io/enopax/templates
```

**Browse published charts:** https://github.com/orgs/enopax/packages?repo_name=templates

## Chart Versions

| Chart | Version | Kubernetes | Description |
|-------|---------|------------|-------------|
| hetzner-standalone-cp | 1.0.11 | v1.32.6+k0s.0 | k0s cluster with bootstrapped control plane |
| hetzner-hosted-cp | 1.0.0 | v1.32.6+k0s.0 | k0s cluster with hosted control plane (NEW!) |
| cluster-api-provider-hetzner | 0.0.26 | v1.0.7 | Cluster API provider for Hetzner (✅ Production Ready) |

## Common Commands

```bash
# List clusters
kubectl get clusters

# Check cluster status
kubectl describe cluster cluster-01

# Monitor deployments
kubectl get clusterdeployments

# View k0rdent pods
kubectl get pods -n kcm-system

# Delete a cluster
kubectl delete cluster cluster-01
```
