# STACKIT on the management cluster

Everything needed to let `enopax-mgmt` build clusters on STACKIT — and the order
to do it in. Nothing here is applied yet.

Context and the open decisions: enopax/enopax#51.

## State

| Piece | Where | State |
|---|---|---|
| CAPSTK provider chart | `enopax/capstk-helm` | written, not published |
| CCM + CSI chart | `enopax/cloud-provider-stackit-helm` | written, not published |
| `stackit-standalone-cp` | own repo | written, never built a cluster |
| `stackit-hosted-cp` | own repo | written, never built a cluster |
| kof-operator patch | `enopax/kof`, `feat/stackit-cloud` | written, image not rebuilt |
| Catalogue rows | `console-api` | `enabled=false`, `available=false` |
| `Management.spec.providers` | `manifests/mgmt/management.yaml` | commented out |

CAPSTK is `v0.1.0-alpha.5` and upstream says "use at your own risk"; STACKIT
calls it "not an officially supported STACKIT project". Enabling it is a product
decision, not a deployment step.

## What has to exist at STACKIT first

1. A STACKIT project, and a **service account with a custom project role** —
   not project admin. The 26 permissions CAPSTK actually uses are listed in its
   docs under *IAM permissions* (`iaas.server.*`, `iaas.network.*`,
   `iaas.security-group.*`, `iaas.public-ip.*`, `nlb.loadbalancer.*`,
   `nlb.targetpool.replace`). What the child cluster's CCM needs on top is not
   documented there; it shows up at the first load balancer.
2. **A network with `internetAccess`**, created by us. Not CAPSTK's managed
   network: its create call sets name, labels and an IPv4 prefix and no
   internet access, and nodes have no public IP. Without the project router's
   SNAT, k0s downloads no binary and no image is pulled — and that failure looks
   like a bootstrap problem while being a networking one.
3. An **image ID** (UUID, not a name):

   ```bash
   stackit image list --project-id "$STACKIT_PROJECT_ID" --output-format json \
     --label-selector linux,prod | jq -r '.[] | select(.name == "Ubuntu 24.04") | .id'
   ```

## The spike comes before anything else

`scripts/stackit-spike.sh` runs against a local **kind** cluster and separates
the two questions, so a failure means something:

```bash
./scripts/stackit-spike.sh prereqs    # tools and variables
./scripts/stackit-spike.sh mgmt       # kind + CAPSTK + k0smotron + kubeadm
./scripts/stackit-spike.sh phase-a    # CAPSTK's own kubeadm template
./scripts/stackit-spike.sh phase-b    # our k0s chart
./scripts/stackit-spike.sh watch
./scripts/stackit-spike.sh teardown
```

**Phase A** proves account, permissions, quota, network and image. **Phase B**
is the open question: CAPSTK reads bootstrap data provider-neutrally from
`Machine.spec.bootstrap.dataSecretName`, but every upstream template and code
comment speaks of kubeadm. k0s on CAPSTK is plausible and unproven. If phase A
is green and phase B is not, that is the answer the whole plan hangs on.

## Order on `enopax-mgmt`

Publish the charts first (`helm push` from each chart repo, or a tag — the
release workflow does it), then:

```bash
export CLUSTER_NAMESPACE=kcm-system
export STACKIT_PROJECT_ID_BASE64="$(printf %s "$STACKIT_PROJECT_ID" | base64)"
export STACKIT_SERVICE_ACCOUNT_JSON_B64="$(base64 < sa_key.json | tr -d '\n')"

envsubst < manifests/mgmt/stackit-secret.yaml | kubectl apply -f -
kubectl apply -f manifests/mgmt/stackit-credential.yaml
kubectl apply -f manifests/mgmt/stackit-resource-template.yaml
kubectl apply -f manifests/mgmt/helm-enopax-charts-repo.yaml
kubectl apply -f manifests/mgmt/stackit-providertemplate.yaml

# now uncomment the stackit entry in management.yaml
kubectl apply -f manifests/mgmt/management.yaml
kubectl get management kcm -w          # wait for Ready

kubectl apply -f manifests/mgmt/stackit-standalone-clustertemplate.yaml
kubectl apply -f manifests/mgmt/stackit-hosted-clustertemplate.yaml
```

Then in `console-api`: fill `provider_regions` (`projectId`, `networkId`,
`imageId`, `availabilityZone`, `credentialsSecretName`), add the
`provider_sizes` rows once the purchase prices are known, and flip
`available`/`enabled` **only** for what has built.

## How the key reaches the child cluster

`stackit-resource-template.yaml` is a Sveltos template ConfigMap named
`<identity-secret>-resource-template`. KCM carries it along when it propagates
the credential, and `getResource "InfrastructureProviderIdentity"` reads the
management-cluster secret. It renders `Secret/stackit-cloud-secret` with
`sa_key.json` into the child's `kube-system` — exactly the names the
`cloud-provider-stackit` chart expects.

Same mechanism as Hetzner's `hcloud-cluster-provisioning-token-resource-template`.
The key must not travel through `ClusterDeployment` values: it would sit in the
object in clear text.

## Two traps worth naming

**The CSI needs the k0s kubelet path.** Upstream hardcodes `/var/lib/kubelet`;
k0s uses `/var/lib/k0s/kubelet`. Our chart defaults to the k0s path. With the
wrong one the node plugin starts, never registers, and PVCs stay `Pending` with
nothing reporting failure — the same shape as enopax/enopax#40.

**The CCM version is tied to the Kubernetes minor.** `cloud-provider-stackit`
pins its releases to `kubernetes/kubernetes` minors (1.34–1.37). A child on k0s
`v1.35.x` needs the `v1.35.x` CCM. Raising the child's k0s minor means raising
`cloudProvider.imageTag` in the cluster chart — the catalogue cannot express
that yet, which is why only one k0s version is offered for STACKIT.

## Teardown is part of the test

Deleting must leave nothing behind: servers, the network (if managed), public
IPs, load balancers, volumes, security groups. Checked in the STACKIT project,
not in the log. Delete the kind cluster **last** — without controllers nobody
cleans up any more.
