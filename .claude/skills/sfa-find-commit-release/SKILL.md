---
name: sfa-find-commit-release
description: Find which MCE/ACM release first contained a specific commit or fix. Given a component and commit hash, searches operator catalogs to determine the first release version that shipped the fix. Use for CVE verification, feature tracking, and release auditing.
allowed-tools:
  - Bash        # Run mce-verify.sh script, podman, git
  - Read        # Read repo-component-exceptions.yaml
  - Skill       # Call sfa-jira-to-repo if needed
---

# Find Commit Release Skill

Determine which MCE/ACM release first contained a specific commit or fix by inspecting operator catalog bundles and container image labels.

## Tools

This skill includes a **verification script**:
- **Script**: `.claude/skills/sfa-find-commit-release/mce-verify.sh`
- **Purpose**: Automate catalog fetching, image inspection, and commit ancestry checking
- **Usage**: Source the script and call functions, or run directly for CLI usage

## Reference Loading

Before executing, load:
- **For component mapping**: Read `docs/build-release/repo-component-exceptions.yaml`
- **For repo identification**: Use `sfa-jira-to-repo` skill if starting from Jira issue

## Purpose

Systematically verify if a commit has shipped in a release by:
1. Mapping repo → component name(s)
2. Fetching MCE/ACM operator catalog bundles
3. Extracting component images from bundles
4. Inspecting image labels for git commits
5. Using `git merge-base` to verify commit ancestry

**Triggers**: Use this skill when:
- "Has CVE-2026-XXXXX shipped?"
- "Which MCE release contains commit abc123?"
- "Did fix XYZ make it into ACM 2.13.5?"
- "Check if ACM-12345 is in the latest release"

## Instructions

### Step 1: Determine Component Name

Given a repository name, determine the MCE/ACM component name(s).

**Using the script:**
```bash
source .claude/skills/sfa-find-commit-release/mce-verify.sh
component=$(repo_to_component "managedcluster-import-controller")
echo "Component: ${component}"
# Output: managedcluster_import_controller
```

**Special cases:**
- **ocm repo** → multiple components (registration, work, placement)
- **Deprecated components** → cluster_proxy_addon (only in MCE ≤ 2.10)

### Step 2: Fetch Operator Catalog

Get the catalog bundle for the OCP version containing the MCE/ACM releases you want to check.

**OCP to MCE/ACM mapping:**
- OCP 4.18: MCE 2.7-2.8, ACM 2.12-2.13
- OCP 4.19: MCE 2.8-2.9, ACM 2.13-2.14
- OCP 4.20: MCE 2.9-2.10, ACM 2.14-2.15
- OCP 4.21: MCE 2.10-2.11, ACM 2.15-2.16

**Using the script:**
```bash
source .claude/skills/sfa-find-commit-release/mce-verify.sh
get_catalog_bundle "4.18" "/tmp/mce-acm-4.18.yaml"
```

### Step 3: Find First Release with Commit

Search through all versions to find the first one containing the commit.

**Prerequisites:**
- Catalog file from Step 2
- Component name from Step 1
- Fix commit hash
- Local clone of the repo (for `git merge-base` check)

**Using the script:**
```bash
source .claude/skills/sfa-find-commit-release/mce-verify.sh

# Find first MCE 2.8.x release with commit
first_version=$(find_first_release_with_commit \
  "/tmp/mce-acm-4.18.yaml" \
  "mce" \
  "managedcluster_import_controller" \
  "6273aeb2" \
  "repos/server-foundation/stolostron/managedcluster-import-controller" \
  "2.8")

echo "First release: MCE ${first_version}"
```

**Output format:**
```
Checking mce 2.8.0...
  Release commit: abc123...
  ✗ Fix not yet included
Checking mce 2.8.1...
  Release commit: def456...
  ✗ Fix not yet included
Checking mce 2.8.5...
  Release commit: d28c51bc...
  ✓ Fix is included!
First release: MCE 2.8.5
```

### Step 4: Report Results

Format the results for the user:

**Success:**
```
✓ Commit 6273aeb2 first shipped in MCE 2.8.5

Details:
  Component: managedcluster_import_controller
  Repository: stolostron/managedcluster-import-controller
  Fix commit: 6273aeb2
  First release: MCE 2.8.5
  Release image commit: d28c51bc
```

**Not found:**
```
✗ Commit 6273aeb2 not found in any MCE 2.8.x release

Details:
  Component: managedcluster_import_controller
  Checked versions: 2.8.0 - 2.8.7
  Suggestion: Check MCE 2.9.x or later releases
```

## Advanced Usage

### Check Multiple OCP Catalogs

If version not found in expected catalog, check adjacent OCP versions:

```bash
for ocp_ver in 4.18 4.19 4.20; do
  catalog="/tmp/mce-acm-${ocp_ver}.yaml"
  get_catalog_bundle "${ocp_ver}" "${catalog}"
  
  first_version=$(find_first_release_with_commit \
    "${catalog}" "mce" "${component}" "${commit}" "${repo_path}" "" || echo "")
  
  if [[ -n "${first_version}" ]]; then
    echo "Found in OCP ${ocp_ver}: MCE ${first_version}"
    break
  fi
done
```

### Handle Multi-Component Repos

For repos like `ocm` that build multiple components:

```bash
components=$(repo_to_component "ocm")  # Returns multiple lines

for component in ${components}; do
  echo "Checking component: ${component}"
  first_version=$(find_first_release_with_commit \
    "${catalog}" "mce" "${component}" "${commit}" "${repo_path}" "2.8")
  
  if [[ -n "${first_version}" ]]; then
    echo "  ${component}: MCE ${first_version}"
  fi
done
```

### From Jira Issue (Full Workflow)

Starting from a Jira CVE issue, combining both skills:

```bash
# Example: ACM-31641 (CVE-2026-33186)

# Step 1: Get repo from Jira (use sfa-jira-to-repo skill)
# Input: ACM-31641
# Label: pscomponent:multicluster-engine/addon-manager-rhel9
# Output: stolostron/ocm

# Step 2: Get commit from Jira
# Check comments for PR link: https://github.com/stolostron/ocm/pull/675
# Get merge commit from PR:
commit=$(gh pr view 675 --repo stolostron/ocm --json mergeCommit --jq '.mergeCommit.oid')
# Result: 1ba9da8e9ff0c6ad9e60fba282da7f2a1902c698

# Step 3: Map repo to component(s)
# ocm builds multiple components - use repo_to_component
source .claude/skills/sfa-find-commit-release/mce-verify.sh
components=$(repo_to_component "ocm")
# Returns: registration, work, placement

# Step 4: Fetch catalog for target MCE version
# From Jira fix_versions: MCE 2.10.3
# MCE 2.10.x is in OCP 4.20 catalog
get_catalog_bundle "4.20" "/tmp/mce-acm-4.20.yaml"

# Step 5: Find first release with commit
# Check one component (all share same image base)
first_version=$(find_first_release_with_commit \
  "/tmp/mce-acm-4.20.yaml" "mce" "registration" "${commit}" \
  "repos/server-foundation/stolostron/ocm" "2.10")

# Step 6: Report
if [[ -n "${first_version}" ]]; then
  echo "✓ ACM-31641 fix shipped in MCE ${first_version}"
else
  echo "✗ Fix not yet in any MCE 2.10.x release"
  echo "Jira indicates it will ship in MCE 2.10.3 (pending)"
fi
```

## Edge Cases

**Component not found in bundle:**
- May be deprecated (e.g., cluster_proxy_addon after 2.10)
- May not exist in that release stream (check other versions)
- Component name might be wrong (verify spelling, underscores vs hyphens)

**Multiple OCP catalogs needed:**
- Older MCE versions may not be in newer OCP catalogs
- Newer MCE versions may not have shipped to older OCP catalogs
- Check mapping table in Step 2 above

**Commit not in local repo:**
- Run `git fetch --all --tags` in the repo
- Release commit may be from a newer branch than you have locally

**Deprecated components:**
- Script will still return the component name
- Warn user if checking versions beyond deprecation date
- Suggest replacement component if applicable

## Dependencies

**Required tools:**
- `podman` - Fetch operator catalog images
- `opm` - Render catalog bundles (via podman entrypoint)
- `yq` - Parse YAML catalog output
- `skopeo` - Inspect container image labels
- `jq` - Parse JSON from skopeo
- `git` - Check commit ancestry with merge-base

**Required files:**
- `docs/build-release/repo-component-exceptions.yaml` - Component mapping exceptions
- Local repo clones under `repos/` - For git merge-base checks

## Notes

- **Catalog caching**: Save catalogs to `/tmp/` to avoid re-fetching
- **Version patterns**: Use version_pattern parameter to limit search (e.g., "2.8" for 2.8.x only)
- **Performance**: Checking all versions can take time; specify version_pattern when possible
- **Rate limits**: podman/skopeo may have registry rate limits; use `--no-tags` flag to reduce requests
