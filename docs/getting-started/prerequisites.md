# Prerequisites

Before setting up a k0rdent management cluster, ensure you have the required tools installed on your Mac.

## Required Tools

### kubectl

Kubernetes command-line tool for interacting with clusters.

```bash
brew install kubectl
```

Verify installation:
```bash
kubectl version --client
```

### Helm

Package manager for Kubernetes applications.

```bash
brew install helm
```

Verify installation:
```bash
helm version
```

### gh

GitHub CLI for authentication and GitHub operations.

```bash
brew install gh
```

Verify installation and authenticate:
```bash
gh --version
gh auth login
```

## Additional Tools by Setup Type

### For Local Setup (kind)

**kind** - Kubernetes in Docker, for running local clusters.

```bash
brew install kind
```

Verify installation:
```bash
kind version
```

### For Remote Setup (Hetzner)

**hcloud** - Hetzner Cloud CLI for managing cloud resources.

```bash
brew install hcloud
```

Verify installation:
```bash
hcloud version
```

**k0sctl** (recommended) - Tool to bootstrap and manage k0s clusters remotely.

```bash
brew install k0sproject/tap/k0sctl
```

Verify installation:
```bash
k0sctl version
```

## Container Runtime

Both local and remote setups require a container runtime.

### Rancher Desktop (Recommended)

Rancher Desktop is an open-source alternative to Docker Desktop with built-in Kubernetes support.

1. Download from https://rancherdesktop.io/
2. Install and start Rancher Desktop
3. Configure settings:
   - **Container Runtime:** dockerd (moby)
   - **Kubernetes:** Disabled (we'll use kind)
   - **Resources:**
     - **Minimum:** 4 CPU, 8 GB RAM
     - **Recommended:** 6 CPU, 12 GB RAM

### Docker Desktop (Alternative)

If you prefer Docker Desktop:

1. Download from https://www.docker.com/products/docker-desktop
2. Install and start Docker Desktop
3. Allocate sufficient resources in settings

### Verify Installation

Verify container runtime is working:
```bash
docker ps
```

## Next Steps

Choose your setup path:
- **Local Development:** [Setup Management Cluster with kind](./setup-kind.md)
- **Remote Production:** [Setup Management Cluster on Hetzner](./setup-hetzner.md)
