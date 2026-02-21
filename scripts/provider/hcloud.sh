#!/bin/bash

# Hetzner Cloud Management Cluster Provider
# Provider-specific functions for managing remote k0s clusters on Hetzner Cloud VMs as k0rdent management clusters
# Common functions and orchestration are handled by deploy.sh

set -e

# Check requirements (provider-specific)
check_requirements() {
    # kubectl is already checked in deploy.sh, this is just for provider-specific checks
    return 0
}

# Check if cluster exists by checking if kubectl context exists (provider-specific)
cluster_exists() {
    local cluster_name=$1
    local context_name=$(get_context_name "${cluster_name}")

    kubectl config get-contexts "${context_name}" &>/dev/null
}

# Get kubectl context name for hcloud cluster (provider-specific)
get_context_name() {
    local cluster_name=$1
    echo "hcloud-${cluster_name}"
}

# Switch to hcloud cluster context (provider-specific)
switch_context() {
    local cluster_name=$1
    local context_name=$(get_context_name "${cluster_name}")

    # Verify context exists
    if ! kubectl config get-contexts "${context_name}" &>/dev/null; then
        print_error "kubectl context not found: ${context_name}"
        print_info "Expected context: ${context_name}"
        print_info ""
        print_info "Available contexts:"
        kubectl config get-contexts -o name
        print_info ""
        print_info "Please create kubectl context for your Hetzner Cloud k0s management cluster:"
        print_info "  kubectl config set-context ${context_name} --cluster=... --user=..."
        return 1
    fi

    if ! kubectl config use-context "${context_name}" >/dev/null 2>&1; then
        print_error "Failed to switch to context: ${context_name}"
        return 1
    fi
    print_info "Using kubectl context: ${context_name}"
    return 0
}

# Hetzner Cloud clusters are manually provisioned (provider-specific)
create_cluster() {
    local cluster_name=$1
    local context_name=$(get_context_name "${cluster_name}")

    if ! cluster_exists "${cluster_name}"; then
        print_error "Hetzner Cloud management cluster not configured"
        print_info "Please create a k0s cluster on Hetzner Cloud and configure kubectl context:"
        print_info "  kubectl config set-context ${context_name} --cluster=... --user=..."
        return 1
    fi

    print_info "Using existing Hetzner Cloud cluster: ${cluster_name}"
    return 0
}

# Parse management cluster name from kubectl context (provider-specific)
# Returns: mgmt_name if context matches hcloud pattern, empty otherwise
parse_context_name() {
    local context=$1
    if [[ "$context" =~ ^hcloud-(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Check if this provider owns the given context (provider-specific)
owns_context() {
    local context=$1
    [[ "$context" =~ ^hcloud- ]]
}

# Install k0rdent (provider-specific - Hetzner Cloud requires manual installation)
install_k0rdent() {
    print_warn "k0rdent not found on Hetzner Cloud cluster"
    print_info "Please install k0rdent manually on your Hetzner Cloud management cluster:"
    print_info "  helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm --version 1.5.0 -n kcm-system --create-namespace"
    return 1
}
