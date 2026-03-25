# Analyze Bug Reproducibility

**Problem**: Need to determine if a Jira bug has sufficient information to reproduce, and whether it's relevant to Server Foundation team.

**Use Case**: Before attempting to reproduce a bug (manually or automatically), verify that:
1. The bug is owned by or relevant to SF team
2. There's enough detail to reproduce it
3. Missing information is clearly identified

---

## Phase 1: Manual Analysis (Current)

This SOP guides manual analysis of a bug. Future phases will add automated cluster provisioning and testing.

### Prerequisites

- Jira API access configured (`JIRA_EMAIL`, `JIRA_API_TOKEN`)
- Bug issue key (e.g., `ACM-12345`)

### Step 1: Fetch Bug Details

```bash
# Use sfa-jira-search skill to fetch bug details
# Example: analyze ACM-12345
```

Or use the REST API directly:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "https://redhat.atlassian.net/rest/api/2/issue/ACM-12345" | jq .
```

### Step 2: Check SF Relevance

**Criteria** (any one is sufficient):

1. **Component**: `Server Foundation` in components list
2. **Assignee**: Member of SF team (see `team-members/team-members.md`)
3. **Reporter**: Member of SF team (indicates SF-discovered bug)
4. **Affected repo**: Mentioned in description/summary and listed in `docs/repos.md`
5. **Labels**: Contains SF-specific labels (e.g., `cluster-proxy`, `import-controller`, `ocm`)

**SF Component Keywords** (extract from `docs/repos.md`):
- managedcluster-import-controller
- multicloud-operators-foundation
- cluster-proxy
- cluster-proxy-addon
- managed-serviceaccount
- clusterlifecycle-state-metrics
- klusterlet-addon-controller
- cluster-permission
- multicluster-role-assignment
- apiserver-network-proxy (ANP)
- backplane-operator (dependency)

**Decision**:
- ✅ **SF-owned**: Component = "Server Foundation" OR assignee in SF team
- ⚠️ **SF-related**: Description mentions SF repo/component, but assigned elsewhere
- ❌ **Not SF**: None of the above

**Action if Not SF**: Stop here. Optionally re-assign or add comment if mis-filed.

### Step 3: Assess Reproducibility

Score each criterion (0 = missing, 1 = partial, 2 = complete):

| Criterion | Score | Notes |
|-----------|-------|-------|
| **Version specified** | 0-2 | ACM/MCE version in `affects-version`, `fix-version`, or description |
| **Environment described** | 0-2 | Cluster type (OCP, EKS, AKS), topology (hub/managed), config notes |
| **Steps to reproduce** | 0-2 | Clear numbered steps OR script/commands OR video/screenshots |
| **Expected behavior** | 0-2 | What should happen (explicit or implied) |
| **Actual behavior** | 0-2 | What actually happens (error message, logs, screenshots) |
| **Reproducible** | 0-2 | Bug reporter confirms it's reproducible (not a one-off) |

**Scoring**:
- **0-3**: Insufficient — cannot reproduce without guessing
- **4-7**: Partial — may be able to reproduce with assumptions
- **8-12**: Good — reproducible with high confidence

### Step 4: Identify Missing Information

Based on scoring, create a checklist of what's missing:

**Version Info**:
- [ ] ACM/MCE version (e.g., "ACM 2.14.0")
- [ ] OpenShift version (if relevant)
- [ ] Affected component version (if not top-level ACM release)

**Environment**:
- [ ] Cluster provider (OpenShift on AWS, GKE, etc.)
- [ ] Hub vs managed cluster configuration
- [ ] Special topology (global hub, hosted mode, etc.)
- [ ] Custom configurations (proxy settings, multi-arch, etc.)

**Reproduction Steps**:
- [ ] Initial cluster state (fresh install, upgraded, etc.)
- [ ] Step-by-step commands or actions
- [ ] Any required resources (YAML manifests, test data)
- [ ] How to verify the bug occurs

**Expected vs Actual**:
- [ ] What the user expected to happen
- [ ] What actually happened (error message, incorrect state)
- [ ] Logs or stack traces
- [ ] Screenshots or recordings

### Step 5: Request More Information (If Needed)

If reproducibility score < 8, draft a Jira comment requesting missing details.

**Template**:

```
h3. Additional Information Needed for Reproduction

To help reproduce this issue, could you please provide:

* *Version*: Which ACM/MCE version are you running? (e.g., ACM 2.14.0)
* *Environment*:
  ** What type of cluster? (OpenShift, EKS, GKE, etc.)
  ** Hub or managed cluster?
* *Steps to Reproduce*:
  1. [Step 1]
  2. [Step 2]
  3. [What command/action triggers the bug?]
* *Expected Behavior*: What should happen?
* *Actual Behavior*: What error or incorrect behavior do you see? Please include:
  ** Error messages or logs
  ** Screenshots (if applicable)

This will help us reproduce and fix the issue faster. Thank you!
```

**Execution**:

```bash
# Use sfa-jira-comment skill (with human approval)
# Example: post comment to ACM-12345
```

Or manually via REST API:

```bash
COMMENT_BODY=$(cat <<'EOF'
h3. Additional Information Needed for Reproduction

To help reproduce this issue, could you please provide:
...
EOF
)

curl -X POST -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://redhat.atlassian.net/rest/api/2/issue/ACM-12345/comment" \
  -d "{\"body\": $(echo "$COMMENT_BODY" | jq -Rs .)}"
```

**IMPORTANT**: Always get human approval before posting the comment. Present the draft to the user first.

### Step 6: Document Analysis Results

Create an analysis report in `.output/`:

```bash
mkdir -p .output
cat > .output/bug-analysis-ACM-12345.json <<EOF
{
  "issue_key": "ACM-12345",
  "analyzed_at": "$(date -Iseconds)",
  "sf_relevance": "SF-owned|SF-related|Not SF",
  "reproducibility_score": 8,
  "scoring_breakdown": {
    "version": 2,
    "environment": 1,
    "steps": 2,
    "expected": 2,
    "actual": 1,
    "reproducible": 0
  },
  "missing_info": [
    "OpenShift version",
    "Cluster provider details",
    "Logs or error messages"
  ],
  "recommendation": "Request more info|Ready to reproduce|Not SF - skip"
}
EOF
```

---

## Phase 2: Semi-Automated (Future)

- **Auto-score reproducibility**: Parse Jira fields and score automatically
- **Auto-draft comment**: Generate missing-info comment from analysis
- **Human approval loop**: Present analysis and draft comment for user review

## Phase 3: Full Automation (Implemented)

**Skill**: [`sfa-bug-reproduce`](../.claude/skills/sfa-bug-reproduce/SKILL.md) - Full end-to-end bug reproduction workflow

Orchestrates the complete process:
- **Cluster provisioning**: Spin up ephemeral ACM cluster with specified version (using `install-acm` skill)
- **Test execution**: Run user-provided test script or interactive manual testing
- **Result capture**: Logs, cluster state, evidence collection
- **Jira update**: Post reproduction results as comment
- **Cleanup**: Teardown environment using `uninstall-acm` skill

**Usage**:
```bash
# With automated test script
.claude/skills/sfa-bug-reproduce/reproduce.sh \
  --issue-key ACM-30940 \
  --test-script ./test-acm-30940.sh

# Manual testing mode
.claude/skills/sfa-bug-reproduce/reproduce.sh \
  --issue-key ACM-31402

# Skip cleanup for inspection
.claude/skills/sfa-bug-reproduce/reproduce.sh \
  --issue-key ACM-30940 \
  --auto-cleanup false
```

---

## Quick Reference

### SF Team Members

See `team-members/team-members.md` for the full list. Key members:
- elgnay, haoqing0110, qiujian16, xuezhaojun, zhiweiyin318, zhujian7, laisongls, hchenxa

### SF Components

See `docs/repos.md` for the full inventory. Key repos:
- managedcluster-import-controller, cluster-proxy, managed-serviceaccount, cluster-permission, multicloud-operators-foundation

### Jira Fields Reference

- **Component**: `project.components[].name`
- **Affects Version**: `fields.versions[]` or `fields.customfield_xxxxx`
- **Fix Version**: `fields.fixVersions[]`
- **Description**: `fields.description` (may contain environment/version details)
- **Labels**: `fields.labels[]`

---

## Examples

### Example 1: Good Reproducibility (Score: 10)

```
Summary: cluster-proxy-addon fails to connect after OCP upgrade
Component: Server Foundation
Affects Version: ACM 2.14.0
Description:
  Environment: OpenShift 4.16 on AWS
  Steps:
    1. Install ACM 2.14.0 on hub cluster
    2. Import managed cluster (OCP 4.15)
    3. Upgrade managed cluster to OCP 4.16
    4. cluster-proxy-addon fails with "connection refused"
  Expected: Addon should reconnect after upgrade
  Actual: Error: "dial tcp 10.0.0.1:8090: connection refused"
  Logs attached.
```

**Analysis**: SF-owned, version clear, environment described, steps detailed, error message included. **Ready to reproduce**.

### Example 2: Poor Reproducibility (Score: 3)

```
Summary: Import fails sometimes
Component: Server Foundation
Description:
  Import doesn't work. Please fix.
```

**Analysis**: SF-owned, but no version, no environment, no steps, no error. **Request more info**.

### Example 3: Not SF (Score: N/A)

```
Summary: Application deployment timeout
Component: Application Lifecycle
Assignee: appmgmt-team
Description: [detailed steps for app deployment issue]
```

**Analysis**: Not SF component, not SF assignee. **Stop here** (or suggest re-assignment if mis-filed).

---

## Automation Hooks

```bash
# Phase 2: Auto-analyze bug (implemented)
.claude/skills/sfa-bug-analyze/SKILL.md  # See skill documentation

# Phase 3: Full automated reproduction (implemented)
.claude/skills/sfa-bug-reproduce/reproduce.sh \
  --issue-key ACM-12345 \
  --acm-version "MCE 2.17.0" \
  --test-script ./my-test.sh
```
