---
name: sfa-jira-to-repo
description: Map a Jira issue to its corresponding GitHub repository. Checks component field, description links, labels, and Konflux when ambiguous. Use when you need to identify which repo a Jira issue belongs to.
allowed-tools:
  - Bash        # Jira MCP, gh CLI
  - Read        # Read docs/repos.md for SF repo list
  - Grep        # Search for repo patterns
---

# Jira to Repo Mapping Skill

Maps a Jira issue to its corresponding GitHub repository by examining multiple signals.

## Purpose

Given a Jira issue key, identify the correct Server Foundation repository. This is useful for:
- Verifying if a fix has shipped in a release
- Creating PRs for bug fixes
- Routing issues to the correct team
- Finding code related to a Jira issue

**Triggers**: Use this skill when:
- "Which repo is ACM-12345 in?"
- "Find the repository for this Jira issue"
- "What repo does this bug belong to?"
- Need to verify release contents for a Jira CVE

## Reference Loading

Before executing, load:
- **For repo list**: Read `docs/repos.md` for SF-owned repositories
- **For Jira fields**: Use Jira MCP tools or gh CLI

## Instructions

### Step 1: Get Jira Issue Details

Fetch the issue using Jira MCP:

```bash
# Get issue with relevant fields
jira issue view ACM-12345 --plain
```

Extract:
- **Component** field (`components[].name`)
- **Description** (look for GitHub links)
- **Labels** (especially `pscomponent:multicluster-engine/<component>-rhel9`)
- **Git Pull Request** custom field (customfield_10875)

### Step 2: Check pscomponent Label (CVE/Security Issues)

Security tracking issues often have a `pscomponent` label that directly indicates the component.

**Label format:** `pscomponent:multicluster-engine/<component>-rhel9`

**Example:**
```
Label: pscomponent:multicluster-engine/addon-manager-rhel9
→ Component: addon_manager
→ Use component_to_repo: addon_manager → ocm
```

**Implementation:**
```bash
# Extract component from pscomponent label
component=$(jira issue view ACM-12345 --plain | \
  grep -o 'pscomponent:multicluster-engine/[^[:space:]]*' | \
  sed 's/pscomponent:multicluster-engine\///' | \
  sed 's/-rhel9$//' | \
  tr '-' '_')

if [[ -n "${component}" ]]; then
  # Use mce-verify.sh to reverse lookup
  source .claude/skills/sfa-find-commit-release/mce-verify.sh
  repo=$(component_to_repo "${component}")
  echo "Found via pscomponent: ${repo}"
fi
```

If found → Skip to Step 6 (Validate)

### Step 3: Check Component Field

The `component` field often directly indicates the repo:

**Server Foundation component → Repo mapping:**
- "Server Foundation" = Need further investigation (generic)
- Check if component name matches a repo name in `docs/repos.md`

### Step 4: Check Description and Links

Look for GitHub repository links in:
1. **Description**: Search for `github.com/stolostron/<repo>` or `github.com/open-cluster-management-io/<repo>`
2. **Git Pull Request field**: Extract repo from PR URL

**Example patterns:**
```
https://github.com/stolostron/managedcluster-import-controller/pull/123
→ repo: managedcluster-import-controller

https://github.com/open-cluster-management-io/cluster-proxy/issues/456  
→ repo: cluster-proxy (upstream)
```

### Step 5: Check Konflux (if still ambiguous)

If component is "Server Foundation" and no clear links:

```bash
# Search Konflux for issue key
gh api search/issues \
  --method GET \
  -f q="ACM-12345 org:stolostron in:title,body" \
  --jq '.items[] | {repo: .repository_url | split("/")[-1], title: .title, url: .html_url}'
```

Konflux PRs often have Jira keys in titles or descriptions.

### Step 6: Return Repository

**Output format:**
```
Repository: <org>/<repo>
Source: <component|link|konflux>
Confidence: <high|medium|low>
```

**Examples:**
```
Repository: stolostron/managedcluster-import-controller
Source: component
Confidence: high

Repository: stolostron/cluster-proxy
Source: description link
Confidence: high

Repository: open-cluster-management-io/ocm
Source: konflux search
Confidence: medium
```

### Step 7: Validate Against Known Repos

Cross-check the result against `docs/repos.md`:
- If found in `server-foundation` section → SF-owned ✓
- If not found → warn user, might be external dependency

## Edge Cases

**Multiple repos mentioned:**
- Prioritize the repo with an open PR
- If multiple PRs, ask user which one they meant

**Upstream vs downstream:**
- stolostron = downstream (default for SF)
- open-cluster-management-io = upstream
- Return downstream by default unless issue explicitly mentions upstream

**No clear match:**
- Report findings and ask user
- Suggest checking issue comments or related issues

## Example Executions

### Example 1: CVE with pscomponent label

```
Input: ACM-31641

Step 1: Fetch issue
  Component: Security, Server Foundation
  Labels: pscomponent:multicluster-engine/addon-manager-rhel9
  Description: "Security Tracking Issue... gRPC-Go authorization bypass..."
  
Step 2: pscomponent label check
  Found label: pscomponent:multicluster-engine/addon-manager-rhel9
  Extracted component: addon_manager
  Mapped to repo: ocm
  
Step 7: Validate
  Found in docs/repos.md: ✓ SF-owned repo (ocm)
  
Output:
  Repository: stolostron/ocm
  Source: pscomponent label
  Confidence: high
```

### Example 2: CVE with GitHub link in description

```
Input: ACM-34139

Step 1: Fetch issue
  Component: Server Foundation
  Description: "CVE-2025-30153... see PR https://github.com/stolostron/managedcluster-import-controller/pull/789"
  
Step 2: pscomponent label check
  No pscomponent label found
  
Step 3: Component check
  "Server Foundation" = generic, need more signals
  
Step 4: Link check
  Found: https://github.com/stolostron/managedcluster-import-controller/pull/789
  Extracted: managedcluster-import-controller
  
Step 7: Validate
  Found in docs/repos.md: ✓ SF-owned repo
  
Output:
  Repository: stolostron/managedcluster-import-controller
  Source: description link
  Confidence: high
```

## Notes

- **Jira component ≠ MCE/ACM component**: The Jira "component" field is organizational, not the container image component name
- **Always verify**: Check `docs/repos.md` to ensure it's an SF-owned repo
- **Konflux is secondary**: Only search Konflux if other methods fail (API rate limits)
