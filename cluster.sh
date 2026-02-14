#!/bin/bash

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_TEMPLATES_DIR="${SCRIPT_DIR}/manifests/user-cluster"  # User cluster templates

# Set script name for print_header
SCRIPT_NAME="CLUSTER"

# Source common functions
source "${SCRIPT_DIR}/scripts/common.sh"

# Override print_header for cluster script
print_header() {
    echo -e "${BLUE}[CLUSTER]${NC} $1"
}

# Function to show usage
usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  create <name>        Generate workload cluster manifests"
    echo "  deploy <name>        Apply workload cluster manifests"
    echo "  list                 List all workload clusters"
    echo "  status <name>        Show cluster status"
    echo "  delete <name>        Delete a workload cluster"
    echo "  kubeconfig <name>    Get workload cluster kubeconfig"
    echo ""
    echo "Examples:"
    echo "  $0 create test-worker"
    echo "  $0 deploy test-worker"
    echo "  $0 list"
    echo "  $0 status test-worker"
    echo "  $0 kubeconfig test-worker"
    exit 1
}

# Get active management cluster from kubectl context using provider scripts
get_active_mgmt_cluster() {
    local context=$(kubectl config current-context 2>/dev/null || echo "")

    if [ -z "$context" ]; then
        print_error "No active kubectl context"
        print_info "Please run ./deploy.sh <mgmt-cluster> first"
        exit 1
    fi

    # Try each provider to parse the context
    local mgmt_name=""
    for provider_script in "${SCRIPT_DIR}/scripts/provider"/*.sh; do
        if [ -f "$provider_script" ]; then
            source "$provider_script"

            # Check if this provider owns the context
            if owns_context "$context" 2>/dev/null; then
                mgmt_name=$(parse_context_name "$context" 2>/dev/null || echo "")
                if [ -n "$mgmt_name" ]; then
                    echo "$mgmt_name"
                    return 0
                fi
            fi
        fi
    done

    # No provider matched
    print_error "Cannot determine management cluster from context: $context"
    print_info "Context doesn't match any known provider pattern (kind-*, hetzner-*, etc.)"
    print_info ""
    print_info "Available management clusters:"
    ls -1 "${SCRIPT_DIR}/mgmt" 2>/dev/null || echo "  (none)"
    exit 1
}

# Create a new workload cluster
cmd_create() {
    if [ $# -ne 1 ]; then
        print_error "Cluster name is required"
        echo "Usage: $0 create <cluster-name>"
        exit 1
    fi

    local WORKER_NAME=$1
    local MGMT_NAME=$(get_active_mgmt_cluster)

    print_header "Creating workload cluster: ${WORKER_NAME}"
    print_info "Management cluster: ${MGMT_NAME}"
    echo ""

    # Define paths
    local MGMT_DIR="${SCRIPT_DIR}/mgmt/${MGMT_NAME}"
    local MGMT_ENV="${MGMT_DIR}/.env"
    local CLUSTERS_DIR="${MGMT_DIR}/user-clusters"
    local WORKER_DIR="${CLUSTERS_DIR}/${WORKER_NAME}"
    local WORKER_ENV="${WORKER_DIR}/.env"

    # Validate management cluster exists
    if [ ! -d "$MGMT_DIR" ]; then
        print_error "Management cluster not found: ${MGMT_NAME}"
        print_info "Available management clusters:"
        ls -1 "${SCRIPT_DIR}/mgmt" 2>/dev/null || echo "  (none)"
        exit 1
    fi

    # Check if workload cluster already exists
    if [ -d "$WORKER_DIR" ]; then
        print_warn "Workload cluster already exists: ${WORKER_NAME}"
        print_info "To recreate, delete first: $0 delete ${WORKER_NAME}"
        exit 1
    fi

    # Create workload cluster directory
    mkdir -p "$WORKER_DIR"

    # Create .env file for workload cluster
    if [ ! -f "$WORKER_ENV" ]; then
        print_info "Creating workload cluster configuration..."
        cat > "$WORKER_ENV" << 'EOF'
# User Cluster Configuration
# This file configures a specific user/workload cluster.
# Management cluster settings are inherited from the parent mgmt/.env file.

# =============================================================================
# CLUSTER IDENTITY
# =============================================================================
# Cluster name (automatically set during creation)
CLUSTER_NAME=${CLUSTER_NAME}

# =============================================================================
# CLUSTER SIZING
# =============================================================================
# Number of control plane nodes (1 for dev/test, 3+ for production)
CONTROL_PLANE_COUNT=1

# Number of worker nodes (where your workloads run)
WORKER_COUNT=2

# =============================================================================
# INFRASTRUCTURE SETTINGS
# =============================================================================
# Hetzner region: fsn1 (Falkenstein), nbg1 (Nuremberg), hel1 (Helsinki), ash (Ashburn)
HETZNER_REGION=fsn1

# Machine types (see https://www.hetzner.com/cloud for options)
# Common types: cx21 (2vCPU, 4GB), cx31 (2vCPU, 8GB), cx41 (4vCPU, 16GB)
CONTROL_PLANE_MACHINE_TYPE=cx21
WORKER_MACHINE_TYPE=cx21

# =============================================================================
# NOTES
# =============================================================================
# The following are inherited from mgmt/${MGMT_NAME}/.env:
#   - HETZNER_TOKEN_BASE64 (shared Hetzner API credentials)
#   - CLUSTER_NAMESPACE (k0rdent namespace, typically kcm-system)
#   - K0S_VERSION and K0S_DOWNLOAD_URL (k0s distribution)
#   - CLUSTER_CHART_SOURCE and PROVIDER_CHART_SOURCE (Helm charts)
#
# Only override the above if this specific cluster needs different settings.
EOF
        # Replace ${CLUSTER_NAME} placeholder with actual name
        sed -i.bak "s/\${CLUSTER_NAME}/${WORKER_NAME}/g" "$WORKER_ENV" && rm -f "${WORKER_ENV}.bak"
        print_info "Created: ${WORKER_ENV}"
    fi

    # Load management cluster config
    print_info "Loading management cluster configuration..."
    set -a
    source "$MGMT_ENV"
    set +a

    # Override with workload cluster config
    print_info "Loading workload cluster configuration..."
    set -a
    source "$WORKER_ENV"
    set +a

    # Set cluster name explicitly
    export CLUSTER_NAME="$WORKER_NAME"

    # Generate manifests
    print_info "Generating manifests for ${WORKER_NAME}..."
    echo ""

    for template_file in "$CLUSTER_TEMPLATES_DIR"/*.yaml; do
        if [ -f "$template_file" ]; then
            local filename=$(basename "$template_file")
            local output_file="${WORKER_DIR}/${filename}"

            print_info "Processing ${filename}..."
            envsubst < "$template_file" > "$output_file"
        fi
    done

    echo ""
    print_info "✓ Workload cluster configured: ${WORKER_NAME}"
    print_info "✓ Configuration: ${WORKER_ENV}"
    print_info "✓ Manifests: ${WORKER_DIR}/"
    echo ""
    print_info "To deploy this cluster:"
    print_info "  $0 deploy ${WORKER_NAME}"
}

# Deploy a workload cluster
cmd_deploy() {
    local MGMT_NAME=$(get_active_mgmt_cluster)
    local MGMT_ENV="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/.env"
    local CLUSTERS_DIR="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/user-clusters"

    # Load config for namespace
    set -a
    source "$MGMT_ENV" 2>/dev/null || CLUSTER_NAMESPACE="kcm-system"
    set +a

    # If no cluster name provided, show list with instructions
    if [ $# -eq 0 ]; then
        print_header "Available User Clusters"
        echo ""

        # Check if any clusters exist locally
        if [ ! -d "$CLUSTERS_DIR" ] || [ -z "$(ls -A "$CLUSTERS_DIR" 2>/dev/null)" ]; then
            print_info "No user clusters found in management cluster: ${MGMT_NAME}"
            print_info ""
            print_info "Create one with: $0 create <cluster-name>"
            exit 1
        fi

        # List available clusters
        local found=false
        for cluster_dir in "$CLUSTERS_DIR"/*; do
            if [ -d "$cluster_dir" ]; then
                found=true
                local cluster_name=$(basename "$cluster_dir")
                echo "  • ${cluster_name}"
            fi
        done

        if [ "$found" = true ]; then
            echo ""
            print_info "Usage: $0 deploy <cluster-name>"
            print_info "Example: $0 deploy $(basename "$(ls -d "$CLUSTERS_DIR"/* 2>/dev/null | head -1)")"
        fi
        exit 1
    fi

    local WORKER_NAME=$1
    local WORKER_DIR="${CLUSTERS_DIR}/${WORKER_NAME}"

    # Validate cluster exists
    if [ ! -d "$WORKER_DIR" ]; then
        print_error "Workload cluster not found: ${WORKER_NAME}"
        print_info "Create it first with: $0 create ${WORKER_NAME}"
        exit 1
    fi

    print_header "Deploying workload cluster: ${WORKER_NAME}"
    print_info "Management cluster: ${MGMT_NAME}"
    print_warn "This will create Hetzner VMs for the workload cluster."
    echo ""

    print_info "Applying manifests to ${MGMT_NAME}..."
    kubectl apply -f "$WORKER_DIR/"

    echo ""
    print_info "✓ Workload cluster deployment initiated!"
    echo ""
    print_header "Monitoring Commands"
    print_info "Watch deployment:"
    print_info "  kubectl get clusterdeployment ${WORKER_NAME} -n ${CLUSTER_NAMESPACE} -w"
    echo ""
    print_info "Check status:"
    print_info "  $0 status ${WORKER_NAME}"
    echo ""
}

# List all workload clusters
cmd_list() {
    local MGMT_NAME=$(get_active_mgmt_cluster)
    local CLUSTERS_DIR="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/user-clusters"

    print_header "Workload clusters in: ${MGMT_NAME}"
    echo ""

    if [ ! -d "$CLUSTERS_DIR" ]; then
        print_info "No workload clusters found"
        print_info "Create one with: $0 create <cluster-name>"
        return
    fi

    # Load mgmt config for namespace
    local MGMT_ENV="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/.env"
    set -a
    source "$MGMT_ENV" 2>/dev/null || true
    set +a

    # List local cluster directories
    local found=false
    for cluster_dir in "$CLUSTERS_DIR"/*; do
        if [ -d "$cluster_dir" ]; then
            found=true
            local cluster_name=$(basename "$cluster_dir")

            # Try to get status from k8s
            local status=$(kubectl get clusterdeployment "$cluster_name" -n "${CLUSTER_NAMESPACE:-kcm-system}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            local ready=$(kubectl get clusterdeployment "$cluster_name" -n "${CLUSTER_NAMESPACE:-kcm-system}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

            echo "  $cluster_name"
            echo "    Status: ${status:-Pending}"
            echo "    Ready: ${ready:-Unknown}"
            echo ""
        fi
    done

    if [ "$found" = false ]; then
        print_info "No workload clusters found"
        print_info "Create one with: $0 create <cluster-name>"
    fi
}

# Show cluster status
cmd_status() {
    local MGMT_NAME=$(get_active_mgmt_cluster)
    local MGMT_ENV="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/.env"
    local CLUSTERS_DIR="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/user-clusters"

    # Load config for namespace
    set -a
    source "$MGMT_ENV" 2>/dev/null || CLUSTER_NAMESPACE="kcm-system"
    set +a

    # If no cluster name provided, show list with instructions
    if [ $# -eq 0 ]; then
        print_header "Available User Clusters"
        echo ""

        # Check if any clusters exist locally
        if [ ! -d "$CLUSTERS_DIR" ] || [ -z "$(ls -A "$CLUSTERS_DIR" 2>/dev/null)" ]; then
            print_info "No user clusters found in management cluster: ${MGMT_NAME}"
            print_info ""
            print_info "Create one with: $0 create <cluster-name>"
            return
        fi

        # List available clusters
        local found=false
        for cluster_dir in "$CLUSTERS_DIR"/*; do
            if [ -d "$cluster_dir" ]; then
                found=true
                local cluster_name=$(basename "$cluster_dir")
                echo "  • ${cluster_name}"
            fi
        done

        if [ "$found" = true ]; then
            echo ""
            print_info "Usage: $0 status <cluster-name>"
            print_info "Example: $0 status $(basename "$(ls -d "$CLUSTERS_DIR"/* 2>/dev/null | head -1)")"
        fi
        return
    fi

    local WORKER_NAME=$1

    print_header "Cluster Status: ${WORKER_NAME}"
    echo ""

    kubectl get clusterdeployment "$WORKER_NAME" -n "${CLUSTER_NAMESPACE}"
    echo ""
    kubectl describe clusterdeployment "$WORKER_NAME" -n "${CLUSTER_NAMESPACE}"
}

# Delete workload cluster
cmd_delete() {
    if [ $# -ne 1 ]; then
        print_error "Cluster name is required"
        echo "Usage: $0 delete <cluster-name>"
        exit 1
    fi

    local WORKER_NAME=$1
    local MGMT_NAME=$(get_active_mgmt_cluster)
    local WORKER_DIR="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/user-clusters/${WORKER_NAME}"
    local MGMT_ENV="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/.env"

    # Load config for namespace
    set -a
    source "$MGMT_ENV" 2>/dev/null || CLUSTER_NAMESPACE="kcm-system"
    set +a

    if [ ! -d "$WORKER_DIR" ]; then
        print_error "Workload cluster not found: ${WORKER_NAME}"
        exit 1
    fi

    print_header "Deleting workload cluster: ${WORKER_NAME}"
    print_warn "This will delete Hetzner VMs and all data!"
    echo ""
    read -p "Are you sure? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting from management cluster..."
        kubectl delete -f "$WORKER_DIR/" --ignore-not-found

        echo ""
        read -p "Remove local configuration? (y/N): " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$WORKER_DIR"
            print_info "✓ Local configuration removed"
        fi

        print_info "✓ Workload cluster deleted"
    else
        print_info "Cancelled"
    fi
}

# Get workload cluster kubeconfig
cmd_kubeconfig() {
    if [ $# -ne 1 ]; then
        print_error "Cluster name is required"
        echo "Usage: $0 kubeconfig <cluster-name>"
        exit 1
    fi

    local WORKER_NAME=$1
    local MGMT_NAME=$(get_active_mgmt_cluster)
    local MGMT_ENV="${SCRIPT_DIR}/mgmt/${MGMT_NAME}/.env"

    # Load config for namespace
    set -a
    source "$MGMT_ENV" 2>/dev/null || CLUSTER_NAMESPACE="kcm-system"
    set +a

    print_header "Getting kubeconfig: ${WORKER_NAME}"
    echo ""

    local secret_name="${WORKER_NAME}-kubeconfig"
    local kubeconfig_path="${HOME}/.kube/config-${WORKER_NAME}"

    if ! kubectl get secret "$secret_name" -n "${CLUSTER_NAMESPACE}" &>/dev/null; then
        print_error "Kubeconfig secret not found: ${secret_name}"
        print_info "Cluster may not be ready yet"
        print_info "Check status with: $0 status ${WORKER_NAME}"
        exit 1
    fi

    kubectl get secret "$secret_name" -n "${CLUSTER_NAMESPACE}" \
        -o jsonpath='{.data.kubeconfig}' | base64 -d > "$kubeconfig_path"

    print_info "✓ Kubeconfig saved to: ${kubeconfig_path}"
    echo ""
    print_info "To use this cluster:"
    print_info "  export KUBECONFIG=${kubeconfig_path}"
    print_info "  kubectl get nodes"
}

# Main
if [ $# -eq 0 ]; then
    usage
fi

COMMAND=$1
shift

case "$COMMAND" in
    create)
        cmd_create "$@"
        ;;
    deploy)
        cmd_deploy "$@"
        ;;
    list|ls)
        cmd_list "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    delete|rm)
        cmd_delete "$@"
        ;;
    kubeconfig|kc)
        cmd_kubeconfig "$@"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        usage
        ;;
esac
