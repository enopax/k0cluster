#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}[PACKAGE]${NC} $1"
}

# Parse arguments
PUSH_TO_REGISTRY=true  # Push by default
if [ "$1" = "--local" ] || [ "$1" = "--no-push" ]; then
    PUSH_TO_REGISTRY=false
fi

print_header "Packaging Helm charts"
echo ""

# Check if helm is available
if ! command -v helm &> /dev/null; then
    print_error "helm is not installed!"
    print_info "Install it with: brew install helm"
    exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    print_error "yq is not installed!"
    print_info "Install it with: brew install yq"
    exit 1
fi

TEMPLATES_DIR="${SCRIPT_DIR}/templates"
CLUSTER_CHART_DIR="${TEMPLATES_DIR}/cluster/hetzner-standalone-cp"
PROVIDER_CHART_DIR="${TEMPLATES_DIR}/provider/cluster-api-provider-hetzner"

# Check if chart directories exist
if [ ! -d "${CLUSTER_CHART_DIR}" ]; then
    print_error "Cluster chart not found: ${CLUSTER_CHART_DIR}"
    exit 1
fi

if [ ! -d "${PROVIDER_CHART_DIR}" ]; then
    print_error "Provider chart not found: ${PROVIDER_CHART_DIR}"
    exit 1
fi

# Extract versions from Chart.yaml files
CLUSTER_CHART_VERSION=$(yq -oy '.version' "${CLUSTER_CHART_DIR}/Chart.yaml")
PROVIDER_CHART_VERSION=$(yq -oy '.version' "${PROVIDER_CHART_DIR}/Chart.yaml")

CLUSTER_PACKAGE="hetzner-standalone-cp-${CLUSTER_CHART_VERSION}.tgz"
PROVIDER_PACKAGE="cluster-api-provider-hetzner-${PROVIDER_CHART_VERSION}.tgz"

CLUSTER_PACKAGE_PATH="${TEMPLATES_DIR}/cluster/${CLUSTER_PACKAGE}"
PROVIDER_PACKAGE_PATH="${TEMPLATES_DIR}/provider/${PROVIDER_PACKAGE}"

print_info "Cluster chart: hetzner-standalone-cp v${CLUSTER_CHART_VERSION}"
print_info "Provider chart: cluster-api-provider-hetzner v${PROVIDER_CHART_VERSION}"
echo ""

# Function to check if package needs updating
needs_packaging() {
    local chart_dir=$1
    local package_path=$2

    if [ ! -f "${package_path}" ]; then
        return 0  # Package doesn't exist, needs packaging
    fi

    # Check if any chart files are newer than the package
    if [ -n "$(find "${chart_dir}" -type f -newer "${package_path}")" ]; then
        return 0  # Chart files modified, needs re-packaging
    fi

    return 1  # Package is up-to-date
}

# Package cluster chart (only if needed)
if needs_packaging "${CLUSTER_CHART_DIR}" "${CLUSTER_PACKAGE_PATH}"; then
    print_info "Packaging cluster chart..."
    cd "${TEMPLATES_DIR}/cluster"
    helm package hetzner-standalone-cp >/dev/null 2>&1
    cd "${SCRIPT_DIR}"
else
    print_info "Cluster chart already packaged (up-to-date)"
fi

# Package provider chart (only if needed)
if needs_packaging "${PROVIDER_CHART_DIR}" "${PROVIDER_PACKAGE_PATH}"; then
    print_info "Packaging provider chart..."
    cd "${TEMPLATES_DIR}/provider"
    helm package cluster-api-provider-hetzner >/dev/null 2>&1
    cd "${SCRIPT_DIR}"
else
    print_info "Provider chart already packaged (up-to-date)"
fi

echo ""
print_info "✓ Charts ready"
print_info "  - ${CLUSTER_PACKAGE_PATH}"
print_info "  - ${PROVIDER_PACKAGE_PATH}"

# Push to OCI registry (default behavior)
if [ "$PUSH_TO_REGISTRY" = true ]; then
    echo ""
    print_info "Pushing charts to OCI registry..."

    print_info "Pushing cluster chart..."
    helm push "${CLUSTER_PACKAGE_PATH}" oci://ghcr.io/enopax/templates

    print_info "Pushing provider chart..."
    helm push "${PROVIDER_PACKAGE_PATH}" oci://ghcr.io/enopax/templates

    echo ""
    print_info "✓ Charts published to oci://ghcr.io/enopax/templates"
else
    echo ""
    print_info "Local packaging only (--local flag used)"
    print_info "To publish charts, run without --local flag"
fi
