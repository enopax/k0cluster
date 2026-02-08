#!/bin/bash
# Monitor cluster deployment progress

echo "=== Diagnostic Information ==="
echo -n "- hetzner-standalone-cp Version: "
kubectl get clustertemplate hetzner-standalone-cp -n kcm-system -o jsonpath='{.spec.helm.chartSpec.version}' 2>/dev/null && echo "" || echo "ClusterTemplate not found"

echo ""
echo "--- HCloud Credentials ---"
kubectl get credential -n kcm-system -o custom-columns=NAME:.metadata.name,IDENTITY_REF:.spec.identityRef.name 2>/dev/null || echo "No credentials found"

echo ""
echo "--- HCloud Secrets ---"
kubectl get secret -n kcm-system -l caph.environment=owned -o custom-columns=NAME:.metadata.name,TYPE:.type,LABELS:.metadata.labels 2>/dev/null || echo "No hcloud secrets found"

echo ""
echo "=== Cluster Deployment Status ==="
kubectl get clusterdeployment cluster01 -n kcm-system

echo ""
echo "=== Machines ==="
kubectl get machine -n kcm-system

echo ""
echo "=== HCloud Machines ==="
kubectl get hcloudmachine -n kcm-system

echo ""
echo "=== K0s Control Plane ==="
kubectl get k0scontrolplane -n kcm-system -o custom-columns=NAME:.metadata.name,READY:.status.ready,INITIALIZED:.status.initialized,REPLICAS:.spec.replicas,READY_REPLICAS:.status.readyReplicas

echo ""
echo "=== HetznerCluster ==="
kubectl get hetznercluster -n kcm-system

echo ""
echo "=== Hetzner Cloud Resources ==="
if command -v hcloud &> /dev/null; then
  echo "=== Hetzner Cloud Servers ==="
  hcloud server list
  echo ""
  echo "=== Hetzner Cloud Load Balancers ==="
  hcloud load-balancer list
else
  echo "Hcloud CLI not available"
fi

echo ""
echo "=== Recent Events ==="
kubectl get events -n kcm-system --sort-by='.lastTimestamp' | tail -10
