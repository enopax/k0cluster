#!/usr/bin/env bash
#
# K0rdent Management Cluster Setup Script
#
# This script sets up a k0rdent management cluster with Hetzner provider support
# on a kind cluster. It includes the fix for the CAPH --insecure-diagnostics issue.
#
# Usage:
#   ./setup-k0rdent-mgmt.sh [cluster-name]
#
# Requirements:
#   - kind
#   - kubectl
#   - helm
#   - hcloud CLI (for Hetzner API token)
#

set -euo pipefail

# Configuration
CLUSTER_NAME="${1:-k0rdent}"
K0RDENT_VERSION="1.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detect versions from manifests
PROVIDER_CHART_VERSION=$(yq '.spec.helm.chartSpec.version' "$REPO_ROOT/manifests/mgmt/hetzner-providertemplate.yaml")
CLUSTER_TEMPLATE_STANDALONE_VERSION=$(yq '.spec.helm.chartSpec.version' "$REPO_ROOT/manifests/mgmt/hetzner-standalone-clustertemplate.yaml")
CLUSTER_TEMPLATE_HOSTED_VERSION=$(yq '.spec.helm.chartSpec.version' "$REPO_ROOT/manifests/mgmt/hetzner-hosted-clustertemplate.yaml")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timing variables
SCRIPT_START_TIME=$(date +%s)
SECTION_START_TIME=0

# Timing functions
start_timer() {
    SECTION_START_TIME=$(date +%s)
}

format_duration() {
    local seconds=$1
    if [ $seconds -lt 60 ]; then
        echo "${seconds}s"
    else
        local minutes=$((seconds / 60))
        local remaining_seconds=$((seconds % 60))
        echo "${minutes}m ${remaining_seconds}s"
    fi
}

log_elapsed() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - SECTION_START_TIME))
    echo -e "  ${BLUE}[Elapsed: $(format_duration $elapsed)]${NC}"
}

# Logging functions
log_header() {
    echo -e "${BLUE}$1${NC}"
    start_timer
}

log_detail() {
    echo "  $1"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wait for HelmRelease to be ready or error
wait_for_helmrelease() {
    local name=$1
    local namespace=${2:-kcm-system}
    local timeout=${3:-300}

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        # Check if HelmRelease exists
        if ! kubectl get helmrelease "$name" -n "$namespace" >/dev/null 2>&1; then
            sleep 5
            elapsed=$((elapsed + 5))
            continue
        fi

        # Get the Ready condition
        local ready=$(kubectl get helmrelease "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        local reason=$(kubectl get helmrelease "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
        local message=$(kubectl get helmrelease "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)

        if [ "$ready" = "True" ]; then
            return 0
        elif [ "$ready" = "False" ] && [[ "$reason" =~ (Failed|Error) ]]; then
            echo ""
            log_error "HelmRelease $name failed: $message"
            return 1
        fi

        # Still reconciling
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    return 1
}

# Check prerequisites
check_prerequisites() {
    log_header "Checking prerequisites"

    local missing=()

    command -v kind >/dev/null 2>&1 || missing+=("kind")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v helm >/dev/null 2>&1 || missing+=("helm")
    command -v yq >/dev/null 2>&1 || missing+=("yq")
    command -v hcloud >/dev/null 2>&1 || missing+=("hcloud")

    if [ ${#missing[@]} -ne 0 ]; then
        echo ""
        log_error "Missing required tools: ${missing[*]}"
        log_detail "See: docs/getting-started/prerequisites.md"
        exit 1
    fi

    log_detail "kind, kubectl, helm, yq, hcloud"

    log_success "Prerequisites met"
    log_elapsed
    echo ""
}

# Create kind cluster
create_kind_cluster() {
    log_header "Creating kind cluster"

    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        log_detail "Cluster already exists: $CLUSTER_NAME"
        kubectl config use-context "kind-$CLUSTER_NAME"
    else
        log_detail "Creating cluster: $CLUSTER_NAME"
        kind create cluster --name "$CLUSTER_NAME"
    fi

    log_success "Kind cluster ready"
    log_elapsed
    echo ""
}

# Install k0rdent
install_k0rdent() {
    log_header "Installing k0rdent"

    if helm list -n kcm-system 2>/dev/null | grep -q "^kcm"; then
        log_detail "k0rdent already installed (v$K0RDENT_VERSION)"
    else
        log_detail "Installing k0rdent v$K0RDENT_VERSION"
        helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
            --version "$K0RDENT_VERSION" \
            -n kcm-system \
            --set regional.telemetry.mode=disabled \
            --set regional.velero.enabled=false \
            --set="controller.createManagement=false" \
            --create-namespace
    fi

    log_success "k0rdent installed"
    log_elapsed
    echo ""
}

# Wait for k0rdent to be ready
wait_for_k0rdent() {
    log_header "Waiting for k0rdent pods"

    log_detail "Waiting for controller manager..."

    # Check if pods exist and are ready, or wait for them
    if kubectl get pods -n kcm-system -l app.kubernetes.io/name=kcm 2>/dev/null | grep -q "Running"; then
        log_detail "k0rdent pods already running"
    else
        kubectl wait --for=condition=ready pod \
            -l app.kubernetes.io/name=kcm \
            -n kcm-system \
            --timeout=600s >/dev/null || {
            log_error "k0rdent pods failed to become ready"
            log_detail "Check status: kubectl get pods -n kcm-system"
            exit 1
        }
    fi

    log_success "k0rdent ready"
    log_elapsed
    echo ""
}

# Apply management resources
apply_management() {
    log_header "Deploying management cluster"

    log_detail "Applying Management resource"
    kubectl apply -f "$REPO_ROOT/manifests/mgmt/management.yaml" | sed 's/^/  /'

    log_detail "Applying HelmRepository"
    kubectl apply -f "$REPO_ROOT/manifests/mgmt/helm-custom-repo.yaml" | sed 's/^/  /'

    log_detail "Applying Hetzner ProviderTemplate"
    kubectl apply -f "$REPO_ROOT/manifests/mgmt/hetzner-providertemplate.yaml" | sed 's/^/  /'

    log_detail "Waiting for reconciliation to start..."
    sleep 10
    kubectl get management/kcm -n kcm-system >/dev/null 2>&1

    log_success "Management resources deployed"
    log_elapsed
    echo ""
}

# Wait for provider deployment
wait_for_provider() {
    log_header "Deploying Hetzner provider (v$PROVIDER_CHART_VERSION)"

    # Wait for CAPI to be ready (Hetzner provider depends on it)
    log_detail "Waiting for CAPI HelmRelease..."
    if ! wait_for_helmrelease "capi" "kcm-system" 300; then
        log_error "CAPI failed to deploy"
        exit 1
    fi

    # Wait for Hetzner provider HelmRelease
    log_detail "Waiting for Hetzner HelmRelease..."
    if ! wait_for_helmrelease "cluster-api-provider-hetzner" "kcm-system" 300; then
        log_error "Hetzner provider failed to deploy"
        exit 1
    fi

    # Wait for CAPH deployment to exist and rollout
    log_detail "Waiting for CAPH deployment..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if kubectl get deployment caph-controller-manager -n kcm-system >/dev/null 2>&1; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    if [ $retries -eq 0 ]; then
        log_error "CAPH deployment not found"
        exit 1
    fi

    # Check if deployment is already ready
    log_detail "Checking CAPH deployment status..."
    local ready_replicas=$(kubectl get deployment caph-controller-manager -n kcm-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired_replicas=$(kubectl get deployment caph-controller-manager -n kcm-system -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

    if [ "$ready_replicas" = "$desired_replicas" ] && [ "$ready_replicas" != "0" ]; then
        log_detail "CAPH deployment already ready ($ready_replicas/$desired_replicas replicas)"
    else
        log_detail "Waiting for CAPH rollout ($ready_replicas/$desired_replicas replicas)..."
        if ! kubectl rollout status deployment/caph-controller-manager -n kcm-system --timeout=180s >/dev/null 2>&1; then
            log_error "CAPH deployment rollout failed"
            log_detail "Check status: kubectl get deployment caph-controller-manager -n kcm-system"
            exit 1
        fi
    fi

    log_success "Hetzner provider deployed"
    log_elapsed
    echo ""
}

# Check if ClusterTemplate is in use
template_in_use() {
    local template_name=$1
    local count=$(kubectl get clusterdeployments -n kcm-system -o jsonpath="{.items[?(@.spec.template=='$template_name')].metadata.name}" 2>/dev/null | wc -w | tr -d ' ')
    [ "$count" -gt 0 ]
}

# Apply cluster templates
apply_cluster_template() {
    log_header "Applying cluster templates"

    # Apply standalone CP template
    log_detail "Template: hetzner-standalone-cp (v$CLUSTER_TEMPLATE_STANDALONE_VERSION)"

    # Check if ClusterTemplate already exists
    if kubectl get clustertemplate hetzner-standalone-cp -n kcm-system >/dev/null 2>&1; then
        local existing_version=$(kubectl get clustertemplate hetzner-standalone-cp -n kcm-system -o jsonpath='{.spec.helm.chartSpec.version}')

        if [ "$existing_version" != "$CLUSTER_TEMPLATE_STANDALONE_VERSION" ]; then
            # Check if template is in use
            if template_in_use "hetzner-standalone-cp"; then
                log_warn "Template v$existing_version is in use by existing clusters"
                log_detail "Skipping update to avoid breaking active deployments"
                log_detail "To upgrade: delete clusters, update template, recreate clusters"
            else
                log_detail "Existing template found (v$existing_version), updating to v$CLUSTER_TEMPLATE_STANDALONE_VERSION"
                log_detail "Deleting existing template (ClusterTemplates are immutable)"
                kubectl delete clustertemplate hetzner-standalone-cp -n kcm-system >/dev/null 2>&1

                log_detail "Creating new template"
                kubectl apply -f "$REPO_ROOT/manifests/mgmt/hetzner-standalone-clustertemplate.yaml" | sed 's/^/  /'
            fi
        else
            log_detail "Template already exists with correct version (v$existing_version)"
        fi
    else
        log_detail "Creating new template"
        kubectl apply -f "$REPO_ROOT/manifests/mgmt/hetzner-standalone-clustertemplate.yaml" | sed 's/^/  /'
    fi

    echo ""

    # Apply hosted CP template
    log_detail "Template: hetzner-hosted-cp (v$CLUSTER_TEMPLATE_HOSTED_VERSION)"

    # Check if ClusterTemplate already exists
    if kubectl get clustertemplate hetzner-hosted-cp-1-0-0 -n kcm-system >/dev/null 2>&1; then
        local existing_version=$(kubectl get clustertemplate hetzner-hosted-cp-1-0-0 -n kcm-system -o jsonpath='{.spec.helm.chartSpec.version}')

        if [ "$existing_version" != "$CLUSTER_TEMPLATE_HOSTED_VERSION" ]; then
            # Check if template is in use
            if template_in_use "hetzner-hosted-cp-1-0-0"; then
                log_warn "Template v$existing_version is in use by existing clusters"
                log_detail "Skipping update to avoid breaking active deployments"
                log_detail "To upgrade: delete clusters, update template, recreate clusters"
            else
                log_detail "Existing template found (v$existing_version), updating to v$CLUSTER_TEMPLATE_HOSTED_VERSION"
                log_detail "Deleting existing template (ClusterTemplates are immutable)"
                kubectl delete clustertemplate hetzner-hosted-cp-1-0-0 -n kcm-system >/dev/null 2>&1

                log_detail "Creating new template"
                kubectl apply -f "$REPO_ROOT/manifests/mgmt/hetzner-hosted-clustertemplate.yaml" | sed 's/^/  /'
            fi
        else
            log_detail "Template already exists with correct version (v$existing_version)"
        fi
    else
        log_detail "Creating new template"
        kubectl apply -f "$REPO_ROOT/manifests/mgmt/hetzner-hosted-clustertemplate.yaml" | sed 's/^/  /'
    fi

    log_success "Cluster templates applied"
    log_elapsed
    echo ""
}

# Configure credentials
configure_credentials() {
    log_header "Configuring credentials"

    local CREDENTIAL_NAME="hcloud-cluster-provisioning"
    local SECRET_NAME="hcloud-cluster-provisioning-token"

    log_detail "Credential: $CREDENTIAL_NAME"
    kubectl apply -f "$REPO_ROOT/manifests/mgmt/credential.yaml" | sed 's/^/  /'

    # Check if secret exists (kubectl create is NOT idempotent)
    log_detail "Secret: $SECRET_NAME"
    if kubectl get secret $SECRET_NAME -n kcm-system 2>/dev/null >/dev/null; then
        echo "  Secret already exists" | sed 's/^/  /'
    else
        echo "  Creating from hcloud CLI token" | sed 's/^/  /'
        kubectl create secret generic $SECRET_NAME \
            --from-literal=hcloud-token="$(hcloud config get token --allow-sensitive)" \
            --namespace kcm-system >/dev/null

        kubectl label secret $SECRET_NAME -n kcm-system \
            caph.environment=owned \
            k0rdent.mirantis.com/component=kcm >/dev/null
    fi

    log_success "Credentials configured"
    log_elapsed
    echo ""
}

# Verify installation
verify_installation() {
    log_header "Verifying installation"

    log_detail "Infrastructure Providers:"
    kubectl get infrastructureprovider -A 2>/dev/null | grep -E '^(NAMESPACE|kcm-system)' | sed 's/^/    /'

    log_detail "Cluster Templates:"
    kubectl get clustertemplate -n kcm-system 2>/dev/null | grep -E '(NAME|hetzner)' | sed 's/^/    /'

    log_detail "Credentials:"
    kubectl get credential -n kcm-system 2>/dev/null | grep -E '(NAME|hetzner)' | sed 's/^/    /'

    log_success "Installation complete"
    log_elapsed
    echo ""
}

# Print next steps
print_next_steps() {
    local total_time=$(( $(date +%s) - SCRIPT_START_TIME ))

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}K0rdent Management Cluster Ready!${NC}"
    echo -e "${GREEN}Total time: $(format_duration $total_time)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo ""
    echo "1. Deploy a test cluster:"
    echo ""
    echo "   Standalone CP (control plane on Hetzner VMs):"
    echo -e "   ${YELLOW}kubectl apply -f $REPO_ROOT/manifests/user-cluster/cluster-01.yaml${NC}"
    echo ""
    echo "   Hosted CP (control plane in management cluster):"
    echo -e "   ${YELLOW}kubectl apply -f $REPO_ROOT/manifests/user-cluster/cluster-hosted.yaml${NC}"
    echo ""
    echo "2. Monitor cluster deployment:"
    echo -e "   ${YELLOW}kubectl get clusterdeployments -n kcm-system${NC}"
    echo -e "   ${YELLOW}kubectl get clusters -n kcm-system${NC}"
    echo ""
    echo "3. Check cluster details:"
    echo -e "   ${YELLOW}kubectl describe clusterdeployment cluster01 -n kcm-system${NC}"
    echo ""
    echo -e "${BLUE}Cluster Types:${NC}"
    echo ""
    echo "  Standalone CP: Traditional setup with CP VMs on Hetzner"
    echo "  Hosted CP:     CP runs as pods in management cluster (cost-effective)"
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo ""
    echo "  # Check provider status"
    echo "  kubectl get infrastructureprovider -A"
    echo ""
    echo "  # View CAPH controller logs"
    echo "  kubectl logs -n kcm-system -l cluster.x-k8s.io/provider=infrastructure-hetzner"
    echo ""
    echo "  # List available cluster templates"
    echo "  kubectl get clustertemplate -n kcm-system"
    echo ""
    echo "  # Check hosted CP pods"
    echo "  kubectl get pods -n kcm-system | grep '\-cp\-'"
    echo ""
    echo "  # Delete management cluster"
    echo "  kind delete cluster --name $CLUSTER_NAME"
    echo ""
}

# Main execution
main() {
    echo "==================================================================="
    echo "  K0rdent Management Cluster Setup"
    echo "  Cluster: $CLUSTER_NAME | k0rdent: $K0RDENT_VERSION | CAPH: $PROVIDER_CHART_VERSION"
    echo "==================================================================="
    echo ""

    check_prerequisites
    create_kind_cluster
    install_k0rdent
    wait_for_k0rdent
    apply_management
    wait_for_provider
    apply_cluster_template
    configure_credentials
    verify_installation
    print_next_steps
}

# Run main function
main "$@"
