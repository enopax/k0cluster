#!/bin/bash

# Kind Management Cluster Provider
# Provider-specific functions for managing local kind clusters as k0rdent management clusters
# Common functions and orchestration are handled by deploy.sh

set -e

# Check if kind is installed (provider-specific)
check_requirements() {
    if ! command -v kind &> /dev/null; then
        print_error "kind is not installed"
        print_info "Install it with: brew install kind"
        return 1
    fi
    return 0
}

# Check if kind cluster exists (provider-specific)
cluster_exists() {
    local cluster_name=$1
    kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"
}

# Create kind cluster (provider-specific)
create_cluster() {
    local cluster_name=$1

    if cluster_exists "${cluster_name}"; then
        print_info "Kind cluster already exists: ${cluster_name}"
        return 0
    fi

    print_info "Creating kind cluster: ${cluster_name}"
    if ! kind create cluster --name "${cluster_name}"; then
        print_error "Failed to create kind cluster"
        return 1
    fi
    return 0
}

# Get kubectl context name for kind cluster (provider-specific)
get_context_name() {
    local cluster_name=$1
    echo "kind-${cluster_name}"
}

# Switch to kind cluster context (provider-specific)
switch_context() {
    local cluster_name=$1
    local context_name=$(get_context_name "${cluster_name}")

    if ! kubectl config use-context "${context_name}" >/dev/null 2>&1; then
        print_error "Failed to switch to context: ${context_name}"
        return 1
    fi
    print_info "Using kubectl context: ${context_name}"
    return 0
}

# Parse management cluster name from kubectl context (provider-specific)
# Returns: mgmt_name if context matches kind pattern, empty otherwise
parse_context_name() {
    local context=$1
    if [[ "$context" =~ ^kind-(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Check if this provider owns the given context (provider-specific)
owns_context() {
    local context=$1
    [[ "$context" =~ ^kind- ]]
}

# Install k0rdent to the cluster (provider-specific)
install_k0rdent() {
    print_info "Installing k0rdent to kind cluster..."
    if ! helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm --version 1.5.0 \
        -n kcm-system --create-namespace --wait; then
        print_error "Failed to install k0rdent"
        return 1
    fi
    return 0
}
