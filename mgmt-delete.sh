#!/bin/bash

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set script name for print_header
SCRIPT_NAME="MGMT-DELETE"

# Source common functions
source "${SCRIPT_DIR}/scripts/common.sh"

# Override print_header for delete script
print_header() {
    echo -e "${BLUE}[DELETE]${NC} $1"
}

# Function to show usage
usage() {
    echo "Usage: $0 <mgmt-cluster-name>"
    echo ""
    echo "Deletes a management cluster and its configuration."
    echo ""
    echo "This will:"
    echo "  - Delete the management cluster (kind or hcloud)"
    echo "  - Remove local configuration directory"
    echo "  - Clean up kubectl context"
    echo "  - Optionally remove user cluster configurations"
    echo ""
    echo "Examples:"
    echo "  $0 test"
    echo "  $0 production"
    exit 1
}

# Main
if [ $# -eq 0 ]; then
    usage
fi

# Handle help flags
case "$1" in
    -h|--help|help)
        usage
        ;;
esac

MGMT_NAME=$1
MGMT_DIR="${SCRIPT_DIR}/mgmt/${MGMT_NAME}"
MGMT_ENV="${MGMT_DIR}/.env"

print_header "Deleting management cluster: ${MGMT_NAME}"
echo ""

# Check if management cluster exists
if [ ! -d "$MGMT_DIR" ]; then
    print_error "Management cluster not found: ${MGMT_NAME}"
    print_info "Available management clusters:"
    ls -1 "${SCRIPT_DIR}/mgmt" 2>/dev/null || echo "  (none)"
    exit 1
fi

# Load configuration to determine cluster type
if [ -f "$MGMT_ENV" ]; then
    set -a
    source "$MGMT_ENV"
    set +a
else
    print_warn "Configuration file not found: ${MGMT_ENV}"
    print_info "Will attempt to delete based on kubectl context"
fi

# Determine cluster type
CLUSTER_TYPE="${MGMT_CLUSTER_TYPE:-kind}"

print_info "Management cluster type: ${CLUSTER_TYPE}"
print_info "Configuration directory: ${MGMT_DIR}"
echo ""

# Check for user clusters
USER_CLUSTERS_DIR="${MGMT_DIR}/user-clusters"
USER_CLUSTER_COUNT=0
USER_CLUSTERS=()

if [ -d "$USER_CLUSTERS_DIR" ]; then
    while IFS= read -r cluster_dir; do
        if [ -d "$cluster_dir" ]; then
            USER_CLUSTERS+=("$(basename "$cluster_dir")")
            ((USER_CLUSTER_COUNT++))
        fi
    done < <(find "$USER_CLUSTERS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

if [ "$USER_CLUSTER_COUNT" -gt 0 ]; then
    print_warn "This management cluster manages ${USER_CLUSTER_COUNT} user cluster(s):"
    for cluster in "${USER_CLUSTERS[@]}"; do
        echo "  - ${cluster}"
    done
    echo ""
fi

# Show what will be deleted
print_warn "Deleting management cluster: ${MGMT_NAME}"
if [ "$USER_CLUSTER_COUNT" -gt 0 ]; then
    print_warn "This will also delete ${USER_CLUSTER_COUNT} user cluster(s) (including Hetzner VMs)"
fi
echo ""

# Delete user clusters first
if [ "$USER_CLUSTER_COUNT" -gt 0 ]; then
    echo ""
    print_header "Step 1: Delete User Clusters"

    # Switch to management cluster context
    case "$CLUSTER_TYPE" in
        kind)
            CONTEXT_NAME="kind-${MGMT_NAME}"
            ;;
        hcloud)
            CONTEXT_NAME="hcloud-${MGMT_NAME}"
            ;;
        *)
            CONTEXT_NAME=""
            ;;
    esac

    if [ -n "$CONTEXT_NAME" ]; then
        if kubectl config get-contexts "${CONTEXT_NAME}" &>/dev/null; then
            print_info "Switching to management cluster context: ${CONTEXT_NAME}"
            kubectl config use-context "${CONTEXT_NAME}" &>/dev/null
        else
            print_warn "Management cluster context not found: ${CONTEXT_NAME}"
            print_warn "User clusters may not be deleted from Hetzner"
        fi
    fi

    # Delete each user cluster
    for cluster in "${USER_CLUSTERS[@]}"; do
        print_info "Deleting user cluster: ${cluster}"

        # Delete from Kubernetes (removes Hetzner VMs)
        if kubectl get clusterdeployment "${cluster}" -n "${CLUSTER_NAMESPACE:-kcm-system}" &>/dev/null; then
            kubectl delete clusterdeployment "${cluster}" -n "${CLUSTER_NAMESPACE:-kcm-system}" --wait=false
            print_info "✓ Deletion initiated for: ${cluster}"
        else
            print_warn "ClusterDeployment not found in Kubernetes: ${cluster}"
        fi

        # Remove local configuration
        local cluster_dir="${USER_CLUSTERS_DIR}/${cluster}"
        if [ -d "$cluster_dir" ]; then
            rm -rf "$cluster_dir"
            print_info "✓ Removed local config for: ${cluster}"
        fi
    done

    echo ""
    print_info "User cluster deletion initiated (Hetzner VMs will be deleted)"
    print_warn "This may take several minutes. Continuing with management cluster deletion..."
    echo ""
    sleep 2
fi

echo ""
STEP_NUM=$((USER_CLUSTER_COUNT > 0 ? 2 : 1))
print_header "Step ${STEP_NUM}: Delete Management Cluster"

# Delete based on cluster type
case "$CLUSTER_TYPE" in
    kind)
        CONTEXT_NAME="kind-${MGMT_NAME}"

        # Check if kind cluster exists
        if kind get clusters 2>/dev/null | grep -q "^${MGMT_NAME}$"; then
            print_info "Deleting kind cluster: ${MGMT_NAME}"
            kind delete cluster --name "${MGMT_NAME}"
            print_info "✓ Kind cluster deleted"
        else
            print_warn "Kind cluster not found: ${MGMT_NAME}"
        fi

        # Delete kubectl context
        if kubectl config get-contexts "${CONTEXT_NAME}" &>/dev/null; then
            print_info "Removing kubectl context: ${CONTEXT_NAME}"
            kubectl config delete-context "${CONTEXT_NAME}" &>/dev/null || true
            print_info "✓ Kubectl context removed"
        fi
        ;;

    hcloud)
        CONTEXT_NAME="hcloud-${MGMT_NAME}"

        print_warn "Hetzner Cloud management cluster detected"
        print_warn "IMPORTANT: You must manually delete the Hetzner Cloud VM running k0s"
        print_info "The script will remove the kubectl context"
        echo ""

        # Delete kubectl context
        if kubectl config get-contexts "${CONTEXT_NAME}" &>/dev/null; then
            print_info "Removing kubectl context: ${CONTEXT_NAME}"
            kubectl config delete-context "${CONTEXT_NAME}" &>/dev/null || true
            print_info "✓ Kubectl context removed"
        fi
        ;;

    *)
        print_warn "Unknown cluster type: ${CLUSTER_TYPE}"
        print_info "Skipping cluster deletion"
        ;;
esac

echo ""
STEP_NUM=$((USER_CLUSTER_COUNT > 0 ? 3 : 2))
print_header "Step ${STEP_NUM}: Remove Local Configuration"

# Remove management cluster directory
print_info "Removing configuration directory: ${MGMT_DIR}"
rm -rf "$MGMT_DIR"
print_info "✓ Configuration directory removed"

echo ""
print_header "Cleanup Complete"
print_info "✓ Management cluster deleted: ${MGMT_NAME}"

# Show remaining management clusters
REMAINING_CLUSTERS=$(ls -1 "${SCRIPT_DIR}/mgmt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING_CLUSTERS" -gt 0 ]; then
    echo ""
    print_info "Remaining management clusters:"
    ls -1 "${SCRIPT_DIR}/mgmt" 2>/dev/null | sed 's/^/  - /'
else
    echo ""
    print_info "No management clusters remaining"
fi

# Check if we need to switch kubectl context
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
if [ "$CURRENT_CONTEXT" = "kind-${MGMT_NAME}" ] || [ "$CURRENT_CONTEXT" = "hcloud-${MGMT_NAME}" ]; then
    print_warn "Current kubectl context was deleted"
    print_info "Available contexts:"
    kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  - /'
    echo ""
    print_info "Switch to a different context:"
    print_info "  kubectl config use-context <context-name>"
fi
