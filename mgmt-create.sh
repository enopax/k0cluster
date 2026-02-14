#!/bin/bash

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests/mgmt"  # Management cluster templates

# Set script name for print_header
SCRIPT_NAME="MGMT-CREATE"

# Source common functions
source "${SCRIPT_DIR}/scripts/common.sh"

# Function to show usage
usage() {
    echo "Usage: $0 <cluster_name>"
    echo ""
    echo "Arguments:"
    echo "  cluster_name    Required. Name for the management cluster."
    echo ""
    echo "Examples:"
    echo "  $0 test          # Create management cluster named 'test'"
    echo "  $0 production    # Create management cluster named 'production'"
    echo ""
    echo "This script will:"
    echo "  1. Create mgmt/<cluster_name>/.env.mgmt"
    echo "  2. Extract Hetzner token from hcloud CLI (if available)"
    echo "  3. Generate manifests in mgmt/<cluster_name>/manifests/"
    exit 1
}

# Get cluster name (required argument)
if [ $# -eq 0 ]; then
    print_error "Cluster name is required"
    echo ""
    usage
elif [ $# -eq 1 ]; then
    # Check for help flag
    if [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
        usage
    fi
    CLUSTER_NAME=$1
else
    print_error "Too many arguments"
    usage
fi

# Define management cluster directory
MGMT_DIR="${SCRIPT_DIR}/mgmt/${CLUSTER_NAME}"
# .env file is in the management cluster directory
ENV_FILE="${MGMT_DIR}/.env"
# Manifests will be generated here
MANIFESTS_OUT_DIR="${MGMT_DIR}/manifests"

print_header "Setting up cluster: ${CLUSTER_NAME}"
echo ""

# Function to get token from hcloud CLI
get_hcloud_token() {
    local hcloud_config="${HOME}/.config/hcloud/cli.toml"

    # Check if hcloud CLI is installed
    if ! command -v hcloud &> /dev/null; then
        return 1
    fi

    # Check if config file exists
    if [ ! -f "${hcloud_config}" ]; then
        return 1
    fi

    # Get active context
    local active_context=$(hcloud context active 2>/dev/null)
    if [ -z "${active_context}" ]; then
        return 1
    fi

    # Extract token using yq
    local token=$(yq -p toml -oy ".contexts[] | select(.name == \"${active_context}\") | .token" "${hcloud_config}" 2>/dev/null)

    if [ -n "${token}" ]; then
        # Base64 encode the token
        echo -n "${token}" | base64
        return 0
    fi

    return 1
}

# Function to merge new variables from .env.example into existing .env file
merge_env_updates() {
    local env_file=$1
    local example_file="${SCRIPT_DIR}/.env.example"

    # Extract variable names from both files (ignore comments and empty lines)
    local example_vars=$(grep -E '^[A-Z_]+=.*' "${example_file}" | cut -d= -f1 | sort)
    local existing_vars=$(grep -E '^[A-Z_]+=.*' "${env_file}" | cut -d= -f1 | sort)

    # Find new variables to add
    local new_vars=$(comm -23 <(echo "$example_vars") <(echo "$existing_vars"))

    # Find obsolete variables to remove
    local obsolete_vars=$(comm -13 <(echo "$example_vars") <(echo "$existing_vars"))

    # Remove obsolete variables
    if [ -n "$obsolete_vars" ]; then
        print_warn "Found obsolete configuration options (not in .env.example)"
        while IFS= read -r var; do
            if [ -n "$var" ]; then
                sed -i.bak "/^${var}=/d" "${env_file}"
                print_info "  - Removed: ${var}"
            fi
        done <<< "$obsolete_vars"
        rm "${env_file}.bak"
        echo ""
    fi

    # Add new variables
    if [ -n "$new_vars" ]; then
        print_warn "Found new configuration options in .env.example"
        echo "" >> "${env_file}"
        echo "# ── New variables added from .env.example $(date +%Y-%m-%d) ──" >> "${env_file}"

        # Add each new variable with its value and surrounding comments
        while IFS= read -r var; do
            if [ -n "$var" ]; then
                # Extract the variable line and any comment lines above it from .env.example
                awk -v var="$var" '
                    /^#/ { comment = comment $0 "\n"; next }
                    /^[A-Z_]+=/ {
                        if ($0 ~ "^" var "=") {
                            printf "%s%s\n", comment, $0
                            exit
                        }
                        comment = ""
                    }
                    /^$/ { comment = "" }
                ' "${example_file}" >> "${env_file}"

                print_info "  + Added: ${var}"
            fi
        done <<< "$new_vars"

        echo ""
        print_info "Updated ${env_file} with new configuration options"
        print_warn "Please review the new variables and adjust as needed"
        echo ""
    fi
}

# Ensure management cluster directories exist
mkdir -p "${MGMT_DIR}"
mkdir -p "${MANIFESTS_OUT_DIR}"

# Create or validate .env file for this cluster
CLUSTER_EXISTS=false
if [ ! -f "${ENV_FILE}" ]; then
    print_info "Creating new cluster configuration..."

    # Check if .env.example exists
    if [ ! -f "${SCRIPT_DIR}/.env.example" ]; then
        print_error ".env.example not found!"
        print_info "Please ensure .env.example exists in the repository"
        exit 1
    fi

    # Copy template to cluster directory
    cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"

    print_info "Created ${ENV_FILE} from .env.example"
    print_warn "Please review and edit ${ENV_FILE} if needed"
    echo ""
else
    CLUSTER_EXISTS=true
    print_info "Cluster configuration exists, checking for updates..."

    # Merge any new variables from .env.example
    merge_env_updates "${ENV_FILE}"

    print_info "Using configuration from ${ENV_FILE}"
fi

# Load environment variables
print_info "Loading environment variables from ${ENV_FILE}..."
set -a
source "${ENV_FILE}"
set +a

# Export CLUSTER_NAME (derived from filename, not from .env)
export CLUSTER_NAME="${CLUSTER_NAME}"

# Auto-detect Hetzner token if not set
if [ -z "${HETZNER_TOKEN_BASE64}" ]; then
    print_info "HETZNER_TOKEN_BASE64 not set, attempting to extract from hcloud CLI..."

    # Check if yq is available (required for TOML parsing)
    if ! command -v yq &> /dev/null; then
        print_error "yq is not installed!"
        print_info "yq is required to parse hcloud config (TOML format)"
        print_info "Install it with: brew install yq"
        print_info "Alternatively, set HETZNER_TOKEN_BASE64 manually in ${ENV_FILE}"
        exit 1
    fi

    HETZNER_TOKEN_BASE64=$(get_hcloud_token)

    if [ -n "${HETZNER_TOKEN_BASE64}" ]; then
        ACTIVE_CTX=$(hcloud context active)
        print_info "Successfully extracted token from hcloud context: ${ACTIVE_CTX}"

        # Update the env file with the token
        if grep -q "^HETZNER_TOKEN_BASE64=" "${ENV_FILE}"; then
            sed -i.bak "s|^HETZNER_TOKEN_BASE64=.*|HETZNER_TOKEN_BASE64=${HETZNER_TOKEN_BASE64}|" "${ENV_FILE}"
            rm "${ENV_FILE}.bak"
            print_info "Updated ${ENV_FILE} with token from hcloud context"
        fi
    else
        print_error "Could not extract token from hcloud CLI"
        print_info "Please either:"
        print_info "  1. Set HETZNER_TOKEN_BASE64 in ${ENV_FILE}, OR"
        print_info "  2. Configure hcloud CLI: hcloud context create <name>"
        exit 1
    fi
fi

# Function to parse chart source (OCI URL) and extract name and version
parse_chart_source() {
    local source=$1
    local chart_name=""
    local chart_version=""

    # Parse OCI URL format: oci://registry/path/chart-name:version
    if [[ "$source" =~ oci://.*/(.*):(.*)$ ]]; then
        chart_name="${BASH_REMATCH[1]}"
        chart_version="${BASH_REMATCH[2]}"
    elif [[ "$source" =~ oci://.*/(.*)$ ]]; then
        # No version specified
        chart_name="${BASH_REMATCH[1]}"
        chart_version="latest"
    fi

    echo "${chart_name}|${chart_version}"
}

# Parse chart sources and export as environment variables
if [ -n "${CLUSTER_CHART_SOURCE}" ]; then
    CHART_INFO=$(parse_chart_source "${CLUSTER_CHART_SOURCE}")
    export CLUSTER_CHART_NAME="${CHART_INFO%%|*}"
    export CLUSTER_CHART_VERSION="${CHART_INFO##*|}"
    print_info "Cluster chart: ${CLUSTER_CHART_NAME} v${CLUSTER_CHART_VERSION}"
fi

if [ -n "${PROVIDER_CHART_SOURCE}" ]; then
    CHART_INFO=$(parse_chart_source "${PROVIDER_CHART_SOURCE}")
    export PROVIDER_CHART_NAME="${CHART_INFO%%|*}"
    export PROVIDER_CHART_VERSION="${CHART_INFO##*|}"
    print_info "Provider chart: ${PROVIDER_CHART_NAME} v${PROVIDER_CHART_VERSION}"
fi

# Validate required variables
REQUIRED_VARS=(
    "HETZNER_TOKEN_BASE64"
    "CLUSTER_NAME"
    "CLUSTER_NAMESPACE"
    "CLUSTER_CHART_SOURCE"
    "PROVIDER_CHART_SOURCE"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required variable $var is not set in ${ENV_FILE}"
        exit 1
    fi
done

# Check if envsubst is available
if ! command -v envsubst &> /dev/null; then
    print_error "envsubst is not installed!"
    print_info "Install it with: brew install gettext && brew link --force gettext"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    print_error "helm is not installed!"
    print_info "Install it with: brew install helm"
    exit 1
fi

# Ensure Helm charts are packaged (local only, don't push)
print_info "Ensuring Helm charts are packaged..."
if [ -x "${SCRIPT_DIR}/package-charts.sh" ]; then
    "${SCRIPT_DIR}/package-charts.sh" --local | grep -E "(\[INFO\]|\[WARN\]|\[ERROR\])" || true
    echo ""
else
    print_warn "package-charts.sh not found or not executable"
    print_info "Charts may need to be packaged manually"
    echo ""
fi

# Function to process a manifest
# Usage: process_manifest <source_filename> [dest_filename]
# If dest_filename is not provided, uses source_filename
process_manifest() {
    local source_filename=$1
    local dest_filename=${2:-$1}  # Use source filename if dest not provided

    local source_file="${MANIFESTS_DIR}/${source_filename}"
    local dest_file="${MANIFESTS_OUT_DIR}/${dest_filename}"

    print_info "Processing ${source_filename}..."
    envsubst < "${source_file}" > "${dest_file}"
}

# Process manifests
if [ "$CLUSTER_EXISTS" = true ]; then
    print_info "Regenerating manifests in ${MANIFESTS_OUT_DIR}..."
else
    print_info "Generating manifests in ${MANIFESTS_OUT_DIR}..."
fi
echo ""

# Define which manifests belong to management cluster
# These are created once and shared by all workload clusters
MGMT_MANIFESTS=(
    "helm-repository.yaml"
    "hetzner-clustertemplate.yaml"
    "hetzner-providertemplate.yaml"
    "credential.yaml"                # Hetzner credentials (shared)
    "secret.yaml"                    # Hetzner API token (shared)
)

# Get list of management template files (for cleanup later)
TEMPLATE_FILES=("${MGMT_MANIFESTS[@]}")

# Process only management manifests
for manifest_name in "${MGMT_MANIFESTS[@]}"; do
    if [ -f "${MANIFESTS_DIR}/${manifest_name}" ]; then
        process_manifest "${manifest_name}"
    else
        print_warn "Template not found: ${manifest_name}"
    fi
done

echo ""

# Clean up orphaned manifests (files in manifests dir but not in source templates)
if [ "$CLUSTER_EXISTS" = true ] && [ -d "${MANIFESTS_OUT_DIR}" ]; then
    print_info "Checking for orphaned manifests..."

    REMOVED_COUNT=0
    for manifest_file in "${MANIFESTS_OUT_DIR}"/*.yaml; do
        if [ -f "${manifest_file}" ]; then
            filename=$(basename "${manifest_file}")

            # Check if this file exists in templates
            if [[ ! " ${TEMPLATE_FILES[@]} " =~ " ${filename} " ]]; then
                print_warn "Removing orphaned manifest: ${filename}"
                rm -f "${manifest_file}"
                REMOVED_COUNT=$((REMOVED_COUNT + 1))
            fi
        fi
    done

    if [ $REMOVED_COUNT -gt 0 ]; then
        print_info "Removed ${REMOVED_COUNT} orphaned manifest(s)"
    else
        print_info "No orphaned manifests found"
    fi
    echo ""
fi
if [ "$CLUSTER_EXISTS" = true ]; then
    print_info "✓ Management cluster manifests updated: ${CLUSTER_NAME}"
    print_info "✓ Configuration: ${ENV_FILE}"
    print_info "✓ Manifests: ${MANIFESTS_OUT_DIR}/"
    echo ""
    print_info "Next steps:"
    print_info "  1. Review manifests: ls -la ${MANIFESTS_OUT_DIR}/"
    print_info "  2. Deploy k0rdent: ./deploy.sh ${CLUSTER_NAME}"
    print_info "  3. Create workload clusters: ./cluster.sh create <worker-name>"
else
    print_info "✓ Management cluster setup complete: ${CLUSTER_NAME}"
    print_info "✓ Configuration: ${ENV_FILE}"
    print_info "✓ Manifests: ${MANIFESTS_OUT_DIR}/"
    echo ""
    print_info "Next steps:"
    print_info "  1. Review manifests: ls -la ${MANIFESTS_OUT_DIR}/"
    print_info "  2. Deploy k0rdent: ./deploy.sh ${CLUSTER_NAME}"
    print_info "  3. Create workload clusters: ./cluster.sh create <worker-name>"
fi
