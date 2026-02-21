#!/bin/bash

# Common Functions
# Shared functions used across setup.sh and deploy.sh
# Source this file at the beginning of scripts that need these utilities

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    local prefix="${SCRIPT_NAME:-INFO}"
    echo -e "${BLUE}[${prefix}]${NC} $1"
}
