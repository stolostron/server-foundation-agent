# Verifying Release Contents

How to determine if a specific commit, CVE fix, or code change has shipped in a given MCE/ACM release.

## Overview

MCE and ACM releases are published as operator bundles in the Red Hat operator catalog. Each bundle references specific container images with git commit hashes. By extracting bundle information and inspecting images, you can verify exactly which code went into each release.

## OCP Version to MCE/ACM Mapping

MCE and ACM releases ship in specific OCP operator catalogs:

| OCP Version | MCE Versions | ACM Versions | Notes |
|-------------|--------------|--------------|-------|
| 4.18 | 2.7.x, 2.8.x | 2.12.x, 2.13.x | Older releases |
| 4.19 | 2.8.x, 2.9.x | 2.13.x, 2.14.x | |
| 4.20 | 2.9.x, 2.10.x | 2.14.x, 2.15.x | |
| 4.21 | 2.10.x, 2.11.x | 2.15.x, 2.16.x | |

**Important:** Check multiple OCP catalogs if you don't find the MCE/ACM version you're looking for.

## Step-by-Step Process

### 1. Extract the Operator Catalog Bundle

Use `opm render` to extract bundle information in YAML format:

```bash
# Extract both MCE and ACM bundles from OCP 4.18 catalog in one command
podman run --rm --entrypoint opm \
  registry.redhat.io/redhat/redhat-operator-index:v4.18 \
  render /configs/multicluster-engine/ /configs/advanced-cluster-management/ \
  -o=yaml > /tmp/mce-acm-4.18.yaml

# Or extract individually:
podman run --rm --entrypoint opm \
  registry.redhat.io/redhat/redhat-operator-index:v4.18 \
  render /configs/multicluster-engine/ -o=yaml > /tmp/mce-4.18.yaml
```

This method works for all OCP versions without signature verification issues.

### 2. List Available Release Versions

```bash
# List all MCE bundle versions in catalog
yq 'select(.schema == "olm.bundle") | .name' /tmp/mce-4.18.yaml | sort -V -u

# List only MCE 2.8.x bundles
yq 'select(.schema == "olm.bundle") | .name' /tmp/mce-4.18.yaml | \
  grep '^multicluster-engine.v2\.8' | sort -V
```

### 3. Extract Component Image for Specific Release

```bash
# Get managedcluster-import-controller image for MCE 2.8.5
yq 'select(.schema == "olm.bundle" and .name == "multicluster-engine.v2.8.5") | \
  .relatedImages[] | \
  select(.name == "managedcluster_import_controller")' \
  /tmp/mce-4.18.yaml

# Output:
# image: registry.redhat.io/multicluster-engine/managedcluster-import-controller-rhel9@sha256:33f154b...
# name: managedcluster_import_controller
```

**Finding component names:** Component names in `relatedImages` use underscores, not hyphens (e.g., `managedcluster_import_controller`, not `managedcluster-import-controller`). Common components:

- `managedcluster_import_controller`
- `cluster_proxy_addon`
- `addon_manager`
- `work`
- `registration`
- `placement`

### 4. Inspect Container Image for Git Commit

```bash
# Extract git commit from image labels
skopeo inspect --no-tags --override-os linux --override-arch amd64 \
  docker://registry.redhat.io/multicluster-engine/managedcluster-import-controller-rhel9@sha256:33f154b425f4f146187493dde01c320428ad09881cf6f90cfcdc4bfa2a4e89e6 | \
  jq -r '.Labels["vcs-ref"]'

# Output: d28c51bc86660e16e5c8dfd2df234ab5b166cbfb
```

**Alternative label names:**
- `vcs-ref` (most common)
- `org.opencontainers.image.revision`
- `io.openshift.build.commit.id` (older images)

### 5. Verify if Specific Fix Is Included

```bash
# In the component's git repo, check if fix commit is ancestor of release commit
cd /path/to/component-repo
git merge-base --is-ancestor <FIX_COMMIT> <RELEASE_COMMIT> && \
  echo "YES - fix is in this release" || \
  echo "NO - fix is NOT in this release"

# Example: Check if commit 6273aeb2 is in the build at d28c51bc
git merge-base --is-ancestor 6273aeb2 d28c51bc && \
  echo "YES - fix is included" || \
  echo "NO - fix is NOT included"
```

### 6. Compare Across Multiple Releases

Batch check all versions of a release stream:

```bash
for version in 2.8.0 2.8.1 2.8.2 2.8.3 2.8.4 2.8.5; do
  echo "MCE $version:"
  yq "select(.schema == \"olm.bundle\" and .name == \"multicluster-engine.v$version\") | \
    .relatedImages[] | \
    select(.name == \"managedcluster_import_controller\")" \
    /tmp/mce-4.18.yaml
  echo
done
```

## Common Use Cases

### Verify CVE Fix Shipped

1. Find the fix commit in component repo (e.g., from Jira CVE issue or GitHub PR)
2. Extract catalog for appropriate OCP version
3. Find the MCE/ACM version you're checking
4. Get the component image SHA
5. Inspect image to get git commit
6. Use `git merge-base --is-ancestor` to verify fix is included

### Determine Which Release Contains a Fix

1. Get the fix commit hash
2. Extract catalog and list all versions
3. For each version, get component image commit
4. Check which versions include the fix
5. The first version containing the fix is the release it shipped in

### Find When Feature Was Released

Same process as CVE verification, but look for the feature's merge commit instead of a fix commit.

## Troubleshooting

### Component Image Not Found

**Issue:** Component name doesn't match expected format

**Solution:** List all components in a bundle to find correct name:

```bash
yq 'select(.schema == "olm.bundle" and .name == "multicluster-engine.v2.8.5") | \
  .relatedImages[].name' /tmp/mce-4.18.yaml | sort -u
```

### Git Commit Not in Local Repo

**Issue:** `git merge-base` fails because release commit doesn't exist locally

**Solution:** Fetch all branches and tags:

```bash
git fetch --all --tags
git pull origin <branch-name>
```

### Version Not in Expected Catalog

**Issue:** MCE version not found in expected OCP catalog

**Solution:** Check multiple OCP catalogs (4.18, 4.19, 4.20, 4.21). Older MCE versions may not be available in newer OCP catalogs, and newer MCE versions may not have shipped to older OCP versions yet.

## References

- Red Hat Operator Catalog: `registry.redhat.io/redhat/redhat-operator-index`
- OCP Operator Lifecycle Manager (OLM) bundles structure
- Container image label standards: `vcs-ref`, `org.opencontainers.image.revision`
