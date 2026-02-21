#!/bin/bash

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set script name for print_header
SCRIPT_NAME="DEPLOY"

# Source common functions
source "${SCRIPT_DIR}/scripts/common.sh"

# Function to show usage
usage() {
    echo "Usage: $0 <cluster_name>"
    echo ""
    echo "Example:"
    echo "  $0 cluster01"
    echo "  $0 production"
    echo ""
    echo "This script will apply the generated manifests for the specified cluster."
    echo ""
    echo "Prerequisites:"
    echo "  1. Run ./setup.sh <cluster_name> first"
    echo "  2. kubectl must be configured to access your k0rdent management cluster"
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    print_error "Cluster name is required"
    usage
fi

CLUSTER_NAME=$1
# Define management cluster directory
MGMT_DIR="${SCRIPT_DIR}/mgmt/${CLUSTER_NAME}"
# .env file is in the management cluster directory
ENV_FILE="${MGMT_DIR}/.env"
# Management manifests to apply
MANIFESTS_DIR="${MGMT_DIR}/manifests"

print_header "Deploying cluster: ${CLUSTER_NAME}"
echo ""

# Validate that setup has been run
if [ ! -d "${MGMT_DIR}" ]; then
    print_error "Management cluster directory not found: ${MGMT_DIR}"
    print_info "Please run setup first: ./setup.sh ${CLUSTER_NAME}"
    exit 1
fi

if [ ! -d "${MANIFESTS_DIR}" ]; then
    print_error "Manifests directory not found: ${MANIFESTS_DIR}"
    print_info "Please run setup first: ./setup.sh ${CLUSTER_NAME}"
    exit 1
fi

if [ ! -f "${ENV_FILE}" ]; then
    print_error "Environment file not found: ${ENV_FILE}"
    print_info "Please run setup first: ./setup.sh ${CLUSTER_NAME}"
    exit 1
fi

# Load environment configuration
set -a
source "${ENV_FILE}"
set +a

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    print_info "Please install kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    print_error "helm is not installed!"
    print_info "Install it with: brew install helm"
    exit 1
fi

# Define common functions (provider-agnostic)
# These are defined BEFORE sourcing providers so providers can use or override them

# Check if k0rdent is installed
k0rdent_installed() {
    helm list -n kcm-system 2>/dev/null | grep -q "kcm"
}

# Verify connection to cluster
verify_connection() {
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to management cluster"
        return 1
    fi
    return 0
}

# Setup management cluster orchestration
setup_management_cluster() {
    local cluster_name=$1

    print_info "Setting up management cluster..."
    echo ""

    # Check provider-specific requirements
    print_info "Checking requirements..."
    if ! check_requirements; then
        print_error "Requirements check failed"
        return 1
    fi

    # Create or verify cluster exists
    print_info "Preparing cluster..."
    if ! create_cluster "${cluster_name}"; then
        print_error "Failed to create/verify cluster"
        return 1
    fi

    # Switch to correct kubectl context
    print_info "Switching kubectl context..."
    if ! switch_context "${cluster_name}"; then
        print_error "Failed to switch context"
        return 1
    fi

    # Install or verify k0rdent
    print_info "Checking k0rdent installation..."
    if ! k0rdent_installed; then
        print_info "k0rdent not found, attempting installation..."
        if ! install_k0rdent; then
            # For hcloud, this is expected and we continue
            if [ "${MGMT_CLUSTER_TYPE}" = "hcloud" ]; then
                print_warn "k0rdent not installed on remote cluster"
                print_info "Please install k0rdent before deploying workload clusters"
            else
                print_error "Failed to install k0rdent"
                return 1
            fi
        fi
    else
        print_info "k0rdent already installed"
    fi

    echo ""
    print_info "Management cluster ready: ${cluster_name}"
    return 0
}

# Source the appropriate provider script
# This is done AFTER defining common functions so provider can use/override them
PROVIDER_SCRIPT="${SCRIPT_DIR}/scripts/provider/${MGMT_CLUSTER_TYPE}.sh"

if [ ! -f "${PROVIDER_SCRIPT}" ]; then
    print_error "Invalid MGMT_CLUSTER_TYPE: ${MGMT_CLUSTER_TYPE}"
    print_info "Must be 'kind' or 'hcloud' in ${ENV_FILE}"
    print_info "Provider script not found: ${PROVIDER_SCRIPT}"
    exit 1
fi

print_info "Management cluster type: ${MGMT_CLUSTER_TYPE}"
source "${PROVIDER_SCRIPT}"

# Setup management cluster
if ! setup_management_cluster "${CLUSTER_NAME}"; then
    print_error "Failed to setup management cluster"
    exit 1
fi

# Verify connection to management cluster
echo ""
print_info "Verifying connection to management cluster..."
if ! verify_connection; then
    exit 1
fi

# Get kubectl context for display
KUBECTL_CONTEXT=$(kubectl config current-context)
print_info "Connected to management cluster: ${KUBECTL_CONTEXT}"
echo ""

# Verify manifests directory has yaml files
MANIFEST_COUNT=$(find "${MANIFESTS_DIR}" -maxdepth 1 -name "*.yaml" -type f 2>/dev/null | wc -l | tr -d ' ')

if [ "${MANIFEST_COUNT}" -eq 0 ]; then
    print_error "No manifests found in ${MANIFESTS_DIR}"
    print_info "Please run setup first: ./setup.sh ${CLUSTER_NAME}"
    exit 1
fi

print_info "Configuration: ${ENV_FILE}"
print_info "Manifests directory: ${MANIFESTS_DIR}/ (${MANIFEST_COUNT} files)"
print_info "Target namespace: ${CLUSTER_NAMESPACE}"
print_info "Kubectl context: $(kubectl config current-context)"
echo ""

# List manifests to be applied
print_info "Management cluster manifests to be applied:"
for manifest_file in "${MANIFESTS_DIR}"/*.yaml; do
    if [ -f "${manifest_file}" ]; then
        echo "  - $(basename "${manifest_file}")"
    fi
done
echo ""

print_info "Applying manifests to management cluster..."
echo ""

# Apply all management manifests
# This installs k0rdent and templates to the management cluster
print_info "Applying k0rdent manifests..."
kubectl apply -f "${MANIFESTS_DIR}/"

echo ""
print_info "✓ All manifests applied successfully!"
echo ""
print_header "Monitoring Commands"
print_info "Watch cluster deployment:"
print_info "  kubectl get clusterdeployment ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} -w"
echo ""
print_info "Check deployment status:"
print_info "  kubectl describe clusterdeployment ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE}"
echo ""
print_info "Monitor pods:"
print_info "  kubectl get pods -n ${CLUSTER_NAMESPACE} -w"
echo ""
print_info "Get all cluster deployments:"
print_info "  kubectl get clusterdeployment -n ${CLUSTER_NAMESPACE}"
