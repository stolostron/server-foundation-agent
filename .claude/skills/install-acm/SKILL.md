---
name: acm-tools:install-acm
description: Install ACM (Advanced Cluster Management) or MCE (Multicluster Engine) on an OpenShift cluster. Supports both downstream (dev/pre-release) and release (GA) versions. Handles OCP cluster connectivity checks, version selection with Quay.io tag querying, ACM-MCE version mapping, CatalogSource creation for downstream builds, pull-secret configuration for private registries, namespace and OperatorGroup setup, and Subscription creation. Use when installing, deploying, or setting up ACM or MCE on an OpenShift cluster.
---

# Install ACM/MCE Skill

Install ACM or MCE on an OpenShift cluster with interactive configuration.

## Usage

```bash
./scripts/install-acm.sh [options]
```

### Options

| Flag | Description | Example |
|------|-------------|---------|
| `--kubeconfig PATH` | Path to kubeconfig file | `--kubeconfig ~/.kube/config` |
| `--product PRODUCT` | Product to install: `acm` or `mce` | `--product acm` |
| `--type TYPE` | Install type: `downstream` or `release` | `--type downstream` |
| `--version VERSION` | Product version (major.minor) | `--version 2.13` |
| `--catalog-image IMAGE` | Catalog image (overrides --version/--latest) | `--catalog-image quay.io:443/acm-d/acm-dev-catalog:2.13.4-DOWNSTREAM-...` |
| `--pull-secret PATH` | Path to pull-secret file | `--pull-secret ~/pull-secret.json` |
| `--channel CHANNEL` | Subscription channel | `--channel release-2.13` |
| `--latest` | Query Quay.io for latest DOWNSTREAM tag | `--latest` |

### ACM-MCE Version Mapping

- ACM 2.17+ -> MCE same version (e.g., ACM 2.17 = MCE 2.17)
- ACM < 2.17 -> MCE minor = ACM minor - 5 (e.g., ACM 2.16 = MCE 2.11, ACM 2.13 = MCE 2.8)

### Interactive Mode

Run without flags for interactive prompts. The script will:
1. Check OCP cluster connectivity (or prompt for kubeconfig/credentials)
2. Ask which product to install (ACM or MCE)
3. Ask for install type (downstream or release)
4. If downstream: ask for pull-secret (needed for Quay.io API and cluster)
5. Ask for version (lists available versions from Quay.io)
6. If downstream: query Quay.io for latest DOWNSTREAM tag or ask for specific image
7. If ACM downstream: also resolve the corresponding MCE catalog image automatically
8. Create required resources (Namespace, OperatorGroup, CatalogSources, Subscription)

### Non-Interactive Examples

```bash
# Install ACM release version
./scripts/install-acm.sh --product acm --type release --version 2.13

# Install ACM downstream latest build for version 2.13
./scripts/install-acm.sh --product acm --type downstream --version 2.13 --latest \
  --pull-secret ~/pull-secret.json

# Install MCE downstream with specific image
./scripts/install-acm.sh --product mce --type downstream \
  --catalog-image quay.io:443/acm-d/mce-dev-catalog:2.8.0-DOWNSTREAM-2025-03-15 \
  --pull-secret ~/pull-secret.json
```

### Quay.io Image Repositories

- **ACM**: `quay.io:443/acm-d/acm-dev-catalog` (requires auth)
- **MCE**: `quay.io:443/acm-d/mce-dev-catalog` (requires auth)

When `--latest` is used with `--version`, the script queries the Quay.io Docker v2 API using credentials from the pull-secret to find the most recent DOWNSTREAM tag matching the specified version.

### CatalogSource Creation (Downstream)

- **MCE only**: Creates one CatalogSource for `mce-dev-catalog`
- **ACM**: Creates TWO CatalogSources - one for `acm-dev-catalog` and one for `mce-dev-catalog` (ACM depends on MCE). The MCE catalog image is automatically resolved based on the ACM-MCE version mapping.

### Pull-Secret Requirement

A pull-secret file is required for downstream installations. It is used for:
1. Authenticating with Quay.io API to query available image tags
2. Configuring the OCP cluster's global pull-secret to pull downstream images
