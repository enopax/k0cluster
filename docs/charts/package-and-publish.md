# Package and Publish Charts

This guide covers how to package Helm charts and publish them to the GitHub Container Registry (GHCR).

## Prerequisites

Ensure you have:
- `helm` installed
- `gh` CLI authenticated (`gh auth login`)
- Write access to the `enopax` organization on GitHub

## When to Package Charts

You need to package and publish charts when:
- You've created new charts
- You've modified existing charts (version bump required)
- Setting up for the first time (charts not yet in OCI registry)

**Note:** If charts are already published to `oci://ghcr.io/enopax/templates`, you can skip this step.

## Package Charts

Navigate to each chart directory and package it:

### Cluster Template

```bash
cd charts/hetzner-standalone-cp
helm package .
```

**Output:** `hetzner-standalone-cp-1.0.0.tgz`

### Provider Template

```bash
cd charts/cluster-api-provider-hetzner
helm package .
```

**Output:** `cluster-api-provider-hetzner-0.0.5.tgz`

## Authenticate to GitHub Container Registry

Use the `gh` CLI to authenticate Helm to GHCR:

```bash
# Ensure you're authenticated
gh auth login  # If not already authenticated

# Login to GHCR
gh auth token | helm registry login ghcr.io -u $(gh api user -q .login) --password-stdin
```

**Alternative:** If you prefer using a token directly:
```bash
echo $GITHUB_TOKEN | helm registry login ghcr.io -u $GITHUB_USERNAME --password-stdin
```

## Push Charts to Registry

Push the packaged charts to the OCI registry:

### Push Cluster Template

```bash
cd charts/hetzner-standalone-cp
helm push hetzner-standalone-cp-1.0.0.tgz oci://ghcr.io/enopax/templates
```

### Push Provider Template

```bash
cd charts/cluster-api-provider-hetzner
helm push cluster-api-provider-hetzner-0.0.5.tgz oci://ghcr.io/enopax/templates
```

## Verify Published Charts

Browse published charts in GitHub Packages:
- https://github.com/orgs/enopax/packages?repo_name=templates

Or use Helm to inspect:

```bash
# Show chart info
helm show chart oci://ghcr.io/enopax/templates/hetzner-standalone-cp --version 1.0.0

# Show chart values
helm show values oci://ghcr.io/enopax/templates/hetzner-standalone-cp --version 1.0.0
```

## Version Management

### Updating Chart Versions

When modifying charts, update the version in `Chart.yaml`:

```yaml
# Chart.yaml
version: 1.0.1  # Increment version
```

Follow [Semantic Versioning](https://semver.org/):
- **Major** (X.0.0): Breaking changes
- **Minor** (x.X.0): New features, backward compatible
- **Patch** (x.x.X): Bug fixes, backward compatible

### Re-package and Push

After version bump:

```bash
cd charts/hetzner-standalone-cp
helm package .
helm push hetzner-standalone-cp-1.0.1.tgz oci://ghcr.io/enopax/templates
```

**Important:** Update manifest references to use the new version:
```yaml
# manifests/mgmt/hetzner-clustertemplate.yaml
spec:
  helm:
    chartSpec:
      version: 1.0.1  # Update version
```

## Troubleshooting

### Authentication Failed

```bash
Error: failed to authorize: failed to fetch oauth token
```

**Solution:** Re-authenticate with `gh`:
```bash
gh auth login
gh auth token | helm registry login ghcr.io -u $(gh api user -q .login) --password-stdin
```

### Chart Already Exists

```bash
Error: chart already exists
```

**Solution:**
- If intentional replacement: Delete the package from GHCR first
- If new version: Bump the version in `Chart.yaml`

### Permission Denied

```bash
Error: failed to authorize: insufficient permissions
```

**Solution:** Ensure you have write access to the `enopax` organization and the repository.

### Chart Not Found After Push

Wait a few seconds for GHCR to propagate the chart. Then verify:

```bash
helm pull oci://ghcr.io/enopax/templates/hetzner-standalone-cp --version 1.0.0
```

## Package Visibility

Charts pushed to GHCR inherit repository visibility:
- **Public repository** → Public charts (recommended)
- **Private repository** → Private charts (requires authentication to pull)

To make charts public:
1. Go to https://github.com/orgs/enopax/packages
2. Find the chart package
3. Settings → Change visibility → Public

## Cleanup

Remove local `.tgz` files after successful push:

```bash
rm charts/hetzner-standalone-cp/*.tgz
rm charts/cluster-api-provider-hetzner/*.tgz
```

Or add to `.gitignore`:
```
*.tgz
```

## Next Steps

After publishing charts:
- [Setup Management Cluster with kind](../getting-started/setup-kind.md)
- [Setup Management Cluster on Hetzner](../getting-started/setup-hetzner.md)

The manifests in `manifests/mgmt/` will reference these published charts.
