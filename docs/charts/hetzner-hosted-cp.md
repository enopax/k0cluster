# Hetzner Hosted Control Plane Chart

This guide covers the **hetzner-hosted-cp** Helm chart for deploying Kubernetes clusters on Hetzner Cloud with a **hosted control plane** using k0smotron.

## Overview

The `hetzner-hosted-cp` chart creates a Kubernetes cluster where:
- **Control plane runs as pods** in the management cluster (via k0smotron)
- **Worker nodes run as VMs** on Hetzner Cloud
- **Cloud integration** via hcloud-cloud-controller-manager and hcloud-csi

### Key Difference: Hosted vs Standalone

| Aspect | Hosted CP (this chart) | Standalone CP |
|--------|------------------------|---------------|
| **Control Plane Location** | Management cluster (pods) | User cluster (Hetzner VMs) |
| **Resource Kind** | `K0smotronControlPlane` | `K0sControlPlane` |
| **Infrastructure Templates** | Workers only | Control plane + Workers |
| **Load Balancer** | Not needed (k8s Service) | Required for HA |
| **Cost** | Lower (no CP VMs) | Higher (dedicated CP VMs) |
| **Scaling CP** | Adjust pod replicas | Add/remove VMs |
| **Failure Domain** | Shared with mgmt cluster | Isolated |
| **Provisioning Speed** | Fast (pods vs VMs) | Slower (VM provisioning) |

## When to Use Hosted CP

✅ **Use hosted control plane when:**
- You want to **reduce costs** (no control plane VMs)
- You need **fast cluster provisioning** (seconds vs minutes)
- You want **centralized management** of all control planes
- You have a **reliable management cluster**
- You're running **many small clusters** (dev/test environments)

❌ **Use standalone control plane when:**
- You need **complete isolation** between clusters
- You have **strict compliance** requirements
- You want **independent failure domains**
- You're running **large production clusters**
- You need **maximum resilience**

## Chart Structure

```
hetzner-hosted-cp/
├── Chart.yaml                                    # Chart metadata (v1.0.0)
├── values.yaml                                   # Configuration defaults
└── templates/
    ├── _helpers.tpl                             # Helper functions
    ├── cluster.yaml                             # Main Cluster resource
    ├── hetznercluster.yaml                      # Hetzner infrastructure
    ├── k0smotroncontrolplane.yaml               # Hosted control plane
    ├── hcloudmachinetemplate.yaml               # Worker machine template
    ├── k0sworkerconfigtemplate.yaml             # Worker bootstrap config
    └── machinedeployment.yaml                   # Worker deployment
```

## What Gets Deployed

### In the Management Cluster
- **K0smotronControlPlane** pods (default: 3 replicas)
- **LoadBalancer Service** exposing the Kubernetes API
- **etcd** storage for the user cluster

### In Hetzner Cloud
- **Worker VMs** only (no control plane VMs)
- **Private network** for worker nodes
- **No load balancer** needed (control plane accessed via k8s Service)

### Installed Components
1. **hcloud-cloud-controller-manager** (v1.21.0)
   - LoadBalancer service provisioning
   - Node lifecycle management
   - Private networking support
   - Cluster CIDR management

2. **hcloud-csi** (v2.10.0)
   - Persistent volume provisioning
   - Default StorageClass: `hcloud-volumes`
   - Volume encryption support
   - Dynamic volume resizing

3. **Calico CNI** (VXLAN mode)
   - Pod networking
   - Network policies
   - Cloud-optimized VXLAN overlay

## Prerequisites

Before deploying, ensure you have:

1. **Management cluster** with k0rdent installed
2. **CAPH provider** (Cluster API Provider Hetzner) deployed
3. **k0smotron provider** deployed
4. **Hetzner API token** stored as a Secret
5. **SSH keys** registered in Hetzner Cloud (optional)

See [Setup Management Cluster](../getting-started/setup-kind.md) for details.

## Configuration

### Required Parameters

```yaml
# Required
region: "fsn1"                    # Hetzner region (fsn1, nbg1, hel1, ash)
workersNumber: 2                  # Number of worker nodes (minimum: 1)
tokenRef:
  name: "hcloud-token-secret"     # Secret containing Hetzner API token
  key: "hcloud-token"             # Key in the secret
worker:
  image: "ubuntu-22.04"           # Server image
  type: "cpx11"                   # Instance type
```

### Common Configurations

#### Development Cluster (Minimal Cost)

```yaml
workersNumber: 1
worker:
  type: cpx11                     # Shared vCPU, 2GB RAM, ~€5/month
k0smotron:
  controlPlaneNumber: 1           # Single CP replica (dev only!)
```

**Estimated cost:** ~€5/month

#### Production Cluster (High Availability)

```yaml
workersNumber: 3
worker:
  type: cpx21                     # Shared vCPU, 4GB RAM, ~€11/month
  placementGroupName: "worker-pg"  # Anti-affinity for workers
k0smotron:
  controlPlaneNumber: 3           # 3 CP replicas (HA)
region: "fsn1"
sshKeyNames: ["prod-ssh-key"]
```

**Estimated cost:** ~€33/month (3 workers only, no CP VMs!)

#### Large Cluster (Scale)

```yaml
workersNumber: 5
worker:
  type: cpx31                     # 4 vCPUs, 8GB RAM, ~€22/month
  dataDisks:
    - size: 100                   # 100GB additional storage
k0smotron:
  controlPlaneNumber: 3
```

**Estimated cost:** ~€110/month + storage costs

### Optional Parameters

```yaml
# SSH Access
sshKeyNames:
  - "my-ssh-key"
  - "team-ssh-key"

# Placement Groups (Anti-affinity)
placementGroupName: "cluster-pg"
worker:
  placementGroupName: "worker-pg"

# Additional Disks
worker:
  dataDisks:
    - size: 100                   # 100GB volume
    - size: 200                   # 200GB volume

# Security Groups
worker:
  additionalSecurityGroups:
    - id: 12345

# Network Configuration
clusterNetwork:
  pods:
    cidrBlocks:
      - "10.244.0.0/16"
  services:
    cidrBlocks:
      - "10.96.0.0/12"
k0s:
  network:
    provider: calico
    calico:
      mode: vxlan               # vxlan, ipip, or never

# Control Plane Replicas
k0smotron:
  controlPlaneNumber: 3         # 1, 3, or 5 recommended

# K0s Configuration
k0s:
  version: v1.32.6+k0s.0
  arch: amd64                   # amd64, arm64, arm
  api:
    extraArgs:
      audit-log-path: "/var/log/k8s-audit.log"
```

## Deployment Example

### 1. Create ClusterDeployment Manifest

```yaml
# cluster-hosted.yaml
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ClusterDeployment
metadata:
  name: dev-cluster-hosted
  namespace: kcm-system
spec:
  template: hetzner-hosted-cp-1-0-0
  credential: hcloud-cluster-provisioning
  config:
    region: fsn1
    workersNumber: 2
    sshKeyNames:
      - "felix-hetzner"
    worker:
      image: ubuntu-22.04
      type: cpx11
    k0smotron:
      controlPlaneNumber: 3
```

### 2. Apply the Manifest

```bash
kubectl apply -f manifests/user-cluster/cluster-hosted.yaml
```

### 3. Monitor Deployment

```bash
# Watch cluster deployment
kubectl get clusterdeployments -n kcm-system -w

# Check cluster status
kubectl get clusters -n kcm-system

# Check control plane pods
kubectl get pods -n kcm-system | grep dev-cluster-hosted

# Check worker machines
kubectl get machines -n kcm-system
```

### 4. Get Kubeconfig

```bash
# Extract kubeconfig
kubectl get secret -n kcm-system dev-cluster-hosted-kubeconfig -o jsonpath='{.data.value}' | base64 -d > dev-cluster-hosted.kubeconfig

# Test access
kubectl --kubeconfig dev-cluster-hosted.kubeconfig get nodes
```

## Cost Comparison

### Hosted CP vs Standalone CP

**Hosted Control Plane:**
```
Management cluster (one-time):
  - 3x CPX11 nodes: €5 × 3 = €15/month

Per user cluster:
  - 2x CPX11 workers: €5 × 2 = €10/month

Total for 5 clusters: €15 + (€10 × 5) = €65/month
```

**Standalone Control Plane:**
```
Per user cluster:
  - 3x CPX11 control plane: €5 × 3 = €15/month
  - 2x CPX11 workers: €5 × 2 = €10/month

Total for 5 clusters: €25 × 5 = €125/month
```

**Savings:** €60/month (48% reduction) with hosted control plane!

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                   Management Cluster                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           K0smotronControlPlane Pods                  │  │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────┐        │  │
│  │  │   CP-1    │  │   CP-2    │  │   CP-3    │        │  │
│  │  │ (etcd +   │  │ (etcd +   │  │ (etcd +   │        │  │
│  │  │  api-svc) │  │  api-svc) │  │  api-svc) │        │  │
│  │  └───────────┘  └───────────┘  └───────────┘        │  │
│  └──────────────────────────────────────────────────────┘  │
│           ▲                                                 │
│           │ LoadBalancer Service (6443)                    │
└───────────┼─────────────────────────────────────────────────┘
            │
            │ API Access
            │
┌───────────┼─────────────────────────────────────────────────┐
│           ▼      Hetzner Cloud (User Cluster)               │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐              │
│  │  Worker-1 │  │  Worker-2 │  │  Worker-N │              │
│  │  (CPX11)  │  │  (CPX11)  │  │  (CPX11)  │              │
│  └───────────┘  └───────────┘  └───────────┘              │
│       │              │              │                       │
│       └──────────────┴──────────────┘                       │
│              Private Network                                │
└─────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### Control Plane Pods Not Starting

**Symptoms:**
```bash
kubectl get pods -n kcm-system | grep cp
# No pods or pending pods
```

**Check:**
```bash
# Check K0smotronControlPlane resource
kubectl get k0smotroncontrolplane -n kcm-system

# Check events
kubectl describe k0smotroncontrolplane <cluster-name>-cp -n kcm-system
```

**Common causes:**
- Insufficient resources in management cluster
- Image pull failures
- PVC issues (if using persistent storage)

### Worker Nodes Not Joining

**Symptoms:**
```bash
kubectl get machines -n kcm-system
# Machines stuck in Provisioning
```

**Check:**
```bash
# Check HCloudMachine resources
kubectl get hcloudmachines -n kcm-system

# Check CAPH controller logs
kubectl logs -n kcm-system -l cluster.x-k8s.io/provider=infrastructure-hetzner

# Check worker bootstrap
kubectl describe k0sworkerconfigtemplate <cluster-name>-machine-config -n kcm-system
```

**Common causes:**
- Invalid Hetzner API token
- Missing SSH keys
- Region/image unavailable
- Network issues

### LoadBalancer Service Pending

**Symptoms:**
```bash
kubectl get svc -n kcm-system
# LoadBalancer EXTERNAL-IP shows <pending>
```

**Check:**
```bash
# This is expected in hosted CP!
# The service is type LoadBalancer but exposed via management cluster
# Not a Hetzner load balancer
```

**Note:** The LoadBalancer service is handled by the management cluster, not Hetzner's LB service.

### Cloud Controller Not Working

**Symptoms:**
- Worker nodes not getting external IPs
- LoadBalancer services in user cluster not working

**Check:**
```bash
# Access user cluster
kubectl --kubeconfig <cluster>.kubeconfig get pods -n kube-system | grep hcloud

# Check CCM logs
kubectl --kubeconfig <cluster>.kubeconfig logs -n kube-system -l app.kubernetes.io/name=hcloud-cloud-controller-manager
```

**Common causes:**
- Hetzner API token not accessible
- Token doesn't have required permissions
- Network policy blocking access

### CSI Driver Issues

**Symptoms:**
- PVCs stuck in Pending
- Volume attach failures

**Check:**
```bash
# Access user cluster
kubectl --kubeconfig <cluster>.kubeconfig get pods -n kube-system | grep csi

# Check CSI controller
kubectl --kubeconfig <cluster>.kubeconfig logs -n kube-system -l app=hcloud-csi-controller

# Check CSI node
kubectl --kubeconfig <cluster>.kubeconfig logs -n kube-system -l app=hcloud-csi
```

**Common causes:**
- API token issues
- Volume size/type issues
- Node driver registration problems

## Scaling

### Scale Worker Nodes

```bash
# Edit cluster deployment
kubectl edit clusterdeployment <cluster-name> -n kcm-system

# Change workersNumber
spec:
  config:
    workersNumber: 5  # Increase from 2 to 5

# Or patch
kubectl patch clusterdeployment <cluster-name> -n kcm-system \
  --type merge -p '{"spec":{"config":{"workersNumber":5}}}'
```

### Scale Control Plane Replicas

```bash
# Edit K0smotronControlPlane directly
kubectl edit k0smotroncontrolplane <cluster-name>-cp -n kcm-system

# Change replicas
spec:
  replicas: 5  # Increase from 3 to 5
```

**Note:** Control plane scaling is instant (pods vs VMs)!

## Upgrades

### Upgrade K0s Version

```bash
# Edit cluster deployment
kubectl edit clusterdeployment <cluster-name> -n kcm-system

# Update version
spec:
  config:
    k0s:
      version: v1.33.0+k0s.0  # New version
```

The upgrade will roll through control plane pods first, then workers.

### Upgrade Chart Version

1. Update ClusterTemplate to new chart version
2. Edit ClusterDeployment to reference new template
3. Changes will be reconciled automatically

## Backup and Restore

### Backup etcd

The control plane etcd data is stored in the management cluster. Backup strategies:

1. **Management cluster backups** (recommended)
   - Use Velero or similar tools
   - Backup entire kcm-system namespace
   - Includes all user cluster control planes

2. **etcd snapshots** (per cluster)
   ```bash
   # Access control plane pod
   kubectl exec -n kcm-system <cluster-name>-cp-0 -- etcdctl snapshot save /tmp/snapshot.db
   ```

### Disaster Recovery

If management cluster fails:
- All hosted control planes are unavailable
- Worker nodes continue running but cannot be managed
- Recovery requires management cluster restoration

**Mitigation:** Use high-availability management cluster with regular backups.

## Best Practices

### 1. Management Cluster Sizing

- **Minimum:** 3 nodes, CPX21 each (4 vCPU, 8GB RAM)
- **Scale:** Add resources based on number of user clusters
- **Rule of thumb:** 1GB RAM per 10 worker nodes across all clusters

### 2. Control Plane Replicas

- **Development:** 1 replica (cost savings)
- **Staging:** 3 replicas (recommended)
- **Production:** 3 or 5 replicas (HA)

### 3. Network Planning

- Use different CIDRs for each user cluster
- Avoid overlapping with management cluster
- Document network assignments

### 4. Monitoring

- Monitor management cluster health (critical!)
- Set up alerts for control plane pod failures
- Track etcd storage usage
- Monitor API latency

### 5. Security

- Use separate Hetzner API tokens per cluster (isolation)
- Limit token permissions (minimum required)
- Rotate SSH keys regularly
- Use private networks for worker communication

## Comparison Matrix

| Feature | Hosted CP | Standalone CP | Notes |
|---------|-----------|---------------|-------|
| CP VMs needed | ❌ No | ✅ Yes | Cost savings |
| Worker VMs needed | ✅ Yes | ✅ Yes | Same |
| LB needed | ❌ No | ✅ Yes | Additional cost |
| Provisioning time | 🚀 Fast (2-3 min) | ⏱️ Slow (5-10 min) | Pods vs VMs |
| CP scaling speed | ⚡ Instant | 🐌 Slow | Pods vs VMs |
| Isolation | ⚠️ Shared | ✅ Complete | Failure domain |
| Multi-tenancy | ✅ Good | ⚠️ Limited | Many small clusters |
| Resource efficiency | ✅ High | ⚠️ Medium | Shared CP resources |
| Compliance | ⚠️ May not meet strict requirements | ✅ Good | Depends on policy |
| Complexity | ⚠️ Management cluster dependency | ✅ Simpler | Operational |

## Migration

### From Standalone to Hosted

Not directly supported. Recommended approach:
1. Deploy new hosted CP cluster
2. Migrate workloads
3. Delete standalone cluster

### From Hosted to Standalone

Similar process:
1. Deploy new standalone cluster
2. Migrate workloads
3. Delete hosted cluster

## Costs Breakdown

### Example: 5 User Clusters

**Setup:**
- 5 user clusters
- 2 workers per cluster (CPX11)
- 3 CP replicas per cluster

**Hosted CP:**
```
Management cluster (one-time):
  Control planes: €0 (shared pods)
  Infrastructure: €15/month (3x CPX11)

Per user cluster:
  Workers: €10/month (2x CPX11)

Total: €15 + (€10 × 5) = €65/month
```

**Standalone CP:**
```
Per user cluster:
  Control plane: €15/month (3x CPX11)
  Workers: €10/month (2x CPX11)
  Load balancer: €6/month

Total: €31 × 5 = €155/month
```

**Savings: €90/month (58% reduction)**

## Next Steps

- [Package and Publish Chart](package-and-publish.md)
- [Setup Management Cluster](../getting-started/setup-kind.md)
- [Deploy Your First Cluster](../getting-started/deploy-cluster.md)

## References

- [k0smotron Documentation](https://k0smotron.io/)
- [Cluster API Provider Hetzner](https://github.com/syself/cluster-api-provider-hetzner)
- [k0s Documentation](https://docs.k0sproject.io/)
- [Hetzner Cloud API](https://docs.hetzner.cloud/)
