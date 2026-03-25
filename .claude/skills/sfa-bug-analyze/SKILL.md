---
name: sfa-bug-analyze
description: "Analyze a Jira bug for Server Foundation relevance and reproducibility. Use this skill when the user wants to check if a bug can be reproduced, assess if it has enough information, or verify SF team ownership. Trigger phrases: 'analyze bug', 'check bug reproducibility', 'can we reproduce ACM-12345', 'is this bug reproducible', 'analyze ACM-12345', 'check if bug is SF-related'."
---

# Bug Reproducibility Analysis

Analyze a Jira bug to determine:
1. Whether it's relevant to the Server Foundation team
2. If there's sufficient information to reproduce it
3. What information is missing (if any)

This is Phase 2 automation of the [analyze-bug-reproducibility solution](../../../solutions/analyze-bug-reproducibility.md).

## Parameters

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| issue-key | Yes | - | Jira issue key (e.g., `ACM-12345`) |
| request-info | No | `false` | If `true`, draft a Jira comment requesting missing info (with human approval) |

## Workflow

### Step 1: Fetch bug details

Use the Jira REST API v2 to fetch full issue details:

```bash
ISSUE_KEY="<issue-key>"

curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "https://redhat.atlassian.net/rest/api/2/issue/$ISSUE_KEY" \
  > .output/bug-${ISSUE_KEY}-raw.json
```

Extract key fields for analysis:

```bash
cat .output/bug-${ISSUE_KEY}-raw.json | jq '{
  key: .key,
  type: .fields.issuetype.name,
  summary: .fields.summary,
  description: .fields.description,
  status: .fields.status.name,
  priority: .fields.priority.name,
  assignee: .fields.assignee.emailAddress,
  reporter: .fields.reporter.emailAddress,
  component: [.fields.components[].name],
  labels: .fields.labels,
  affects_version: [.fields.versions[].name],
  fix_version: [.fields.fixVersions[].name]
}' > .output/bug-${ISSUE_KEY}-fields.json
```

### Step 2: Check SF relevance

Create a Python script to check SF relevance:

```bash
cat > .output/check_sf_relevance.py << 'ENDOFPYTHON'
import json
import sys

# Load team members
with open('team-members/team-members.md', 'r') as f:
    team_content = f.read()
    # Extract SF team emails (lines 3-12 from team table)
    sf_emails = [
        'leyan@redhat.com', 'qhao@redhat.com', 'jqiu@redhat.com',
        'zxue@redhat.com', 'zyin@redhat.com', 'jiazhu@redhat.com',
        'slai@redhat.com', 'huichen@redhat.com'
    ]

# SF component keywords from docs/repos.md
sf_keywords = [
    'managedcluster-import-controller', 'multicloud-operators-foundation',
    'cluster-proxy', 'cluster-proxy-addon', 'managed-serviceaccount',
    'clusterlifecycle-state-metrics', 'klusterlet-addon-controller',
    'cluster-permission', 'multicluster-role-assignment',
    'apiserver-network-proxy', 'ANP', 'backplane-operator'
]

# Load bug data
bug = json.load(sys.stdin)

relevance = 'Not SF'
reasons = []

# Check component
if 'Server Foundation' in bug.get('component', []):
    relevance = 'SF-owned'
    reasons.append('Component: Server Foundation')

# Check assignee
assignee = bug.get('assignee')
if assignee and assignee in sf_emails:
    if relevance == 'Not SF':
        relevance = 'SF-owned'
    reasons.append(f'Assignee: {assignee} (SF team)')

# Check reporter
reporter = bug.get('reporter')
if reporter and reporter in sf_emails:
    if relevance == 'Not SF':
        relevance = 'SF-related'
    reasons.append(f'Reporter: {reporter} (SF team)')

# Check description/summary for SF keywords
text = (bug.get('summary', '') + ' ' + (bug.get('description') or '')).lower()
found_keywords = [kw for kw in sf_keywords if kw.lower() in text]
if found_keywords and relevance == 'Not SF':
    relevance = 'SF-related'
    reasons.append(f'Mentions: {", ".join(found_keywords[:3])}')

result = {
    'relevance': relevance,
    'reasons': reasons
}

print(json.dumps(result, indent=2))
ENDOFPYTHON

cat .output/bug-${ISSUE_KEY}-fields.json | python3 .output/check_sf_relevance.py > .output/bug-${ISSUE_KEY}-relevance.json
```

If relevance is "Not SF", stop here and inform the user.

### Step 3: Score reproducibility

Create a Python script to score reproducibility (0-12):

```bash
cat > .output/score_reproducibility.py << 'ENDOFPYTHON'
import json
import sys
import re

bug = json.load(sys.stdin)
summary = bug.get('summary', '').lower()
description = (bug.get('description') or '').lower()
text = summary + ' ' + description

scores = {}
missing = []

# 1. Version specified (0-2)
versions = bug.get('affects_version', []) + bug.get('fix_version', [])
version_in_desc = bool(re.search(r'(mce|acm)\s*\d+\.\d+', text))
if versions or version_in_desc:
    scores['version'] = 2
    if not versions:
        scores['version'] = 1  # Only in description
else:
    scores['version'] = 0
    missing.append('ACM/MCE version')

# 2. Environment described (0-2)
env_keywords = ['openshift', 'ocp', 'eks', 'aks', 'gke', 'hub', 'managed', 'cluster']
env_matches = sum(1 for kw in env_keywords if kw in text)
if env_matches >= 3:
    scores['environment'] = 2
elif env_matches >= 1:
    scores['environment'] = 1
else:
    scores['environment'] = 0
    missing.append('Environment details (cluster type, topology)')

# 3. Steps to reproduce (0-2)
step_patterns = [
    r'\d+\.\s+',  # Numbered steps
    r'step \d+',
    r'reproduce',
    r'to reproduce',
    r'how to',
]
has_steps = any(re.search(p, text) for p in step_patterns)
step_count = len(re.findall(r'\d+\.\s+', description))
if step_count >= 3 or 'steps:' in text.lower():
    scores['steps'] = 2
elif has_steps:
    scores['steps'] = 1
else:
    scores['steps'] = 0
    missing.append('Steps to reproduce')

# 4. Expected behavior (0-2)
expected_keywords = ['expected', 'should', 'supposed to', 'correct behavior']
has_expected = any(kw in text for kw in expected_keywords)
if has_expected and len(description) > 100:
    scores['expected'] = 2
elif has_expected or len(description) > 50:
    scores['expected'] = 1
else:
    scores['expected'] = 0
    missing.append('Expected behavior')

# 5. Actual behavior (0-2)
actual_keywords = ['error', 'actual', 'fails', 'crash', 'incorrect', 'logs', 'stack trace']
has_actual = any(kw in text for kw in actual_keywords)
has_error_detail = bool(re.search(r'error:|exception:|traceback:|failed with', text))
if has_actual and has_error_detail:
    scores['actual'] = 2
elif has_actual:
    scores['actual'] = 1
else:
    scores['actual'] = 0
    missing.append('Actual behavior (error message, logs)')

# 6. Reproducible status (0-2)
reproducible_keywords = ['reproducible', 'consistently', 'every time', 'always', '100%']
sometimes_keywords = ['sometimes', 'intermittent', 'occasionally', 'random']
if any(kw in text for kw in reproducible_keywords):
    scores['reproducible'] = 2
elif any(kw in text for kw in sometimes_keywords):
    scores['reproducible'] = 1
else:
    scores['reproducible'] = 0
    missing.append('Reproducibility confirmation')

total = sum(scores.values())

result = {
    'total_score': total,
    'scoring_breakdown': scores,
    'missing_info': missing,
    'recommendation': 'Ready to reproduce' if total >= 8 else ('Partial - may reproduce' if total >= 4 else 'Request more info')
}

print(json.dumps(result, indent=2))
ENDOFPYTHON

cat .output/bug-${ISSUE_KEY}-fields.json | python3 .output/score_reproducibility.py > .output/bug-${ISSUE_KEY}-score.json
```

### Step 4: Combine and present analysis

Merge results and create final analysis report:

```bash
jq -s '
{
  issue_key: $ISSUE_KEY,
  analyzed_at: now | strftime("%Y-%m-%dT%H:%M:%S%z"),
  summary: .[0].summary,
  type: .[0].type,
  status: .[0].status,
  sf_relevance: .[1].relevance,
  sf_reasons: .[1].reasons,
  reproducibility_score: .[2].total_score,
  scoring_breakdown: .[2].scoring_breakdown,
  missing_info: .[2].missing_info,
  recommendation: .[2].recommendation
}' \
  .output/bug-${ISSUE_KEY}-fields.json \
  .output/bug-${ISSUE_KEY}-relevance.json \
  .output/bug-${ISSUE_KEY}-score.json \
  --arg ISSUE_KEY "$ISSUE_KEY" \
  > .output/bug-analysis-${ISSUE_KEY}.json
```

Present results to the user in markdown format:

```markdown
# Bug Analysis: ACM-12345

**Summary**: [Bug summary]
**Type**: Bug | **Status**: In Progress
**Browse**: https://redhat.atlassian.net/browse/ACM-12345

## SF Relevance: ✅ SF-owned / ⚠️ SF-related / ❌ Not SF

**Reasons**:
- Component: Server Foundation
- Assignee: zxue@redhat.com (SF team)

## Reproducibility Score: 8/12 (Ready to reproduce)

| Criterion | Score | Max |
|-----------|-------|-----|
| Version specified | 2 | 2 |
| Environment described | 1 | 2 |
| Steps to reproduce | 2 | 2 |
| Expected behavior | 2 | 2 |
| Actual behavior | 1 | 2 |
| Reproducible | 0 | 2 |

## Missing Information

- Environment details (cluster provider, topology)
- Logs or error messages
- Reproducibility confirmation

## Recommendation

**Ready to reproduce** (Score >= 8)
- Proceed with manual reproduction
- Or set up automated reproduction environment

**Analysis saved to**: `.output/bug-analysis-ACM-12345.json`
```

### Step 5: Draft missing-info comment (optional)

If `--request-info=true` and score < 8, draft a Jira comment:

```bash
cat > .output/bug-${ISSUE_KEY}-comment-draft.txt << 'ENDOFCOMMENT'
h3. Additional Information Needed for Reproduction

To help reproduce this issue, could you please provide:

[Generate checklist based on missing_info array]

This will help us reproduce and fix the issue faster. Thank you!

---
_Automated analysis by [server-foundation-agent|https://github.com/stolostron/server-foundation-agent]_
ENDOFCOMMENT
```

**IMPORTANT**: Present the draft to the user for approval. DO NOT post automatically.

If approved by user:

```bash
COMMENT_BODY=$(cat .output/bug-${ISSUE_KEY}-comment-draft.txt)

curl -s -X POST \
  -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"body\": $(echo "$COMMENT_BODY" | jq -Rs .)}" \
  "https://redhat.atlassian.net/rest/api/2/issue/${ISSUE_KEY}/comment"
```

## Output Files

All artifacts saved to `.output/`:

| File | Description |
|------|-------------|
| `bug-<KEY>-raw.json` | Full Jira API response |
| `bug-<KEY>-fields.json` | Extracted fields |
| `bug-<KEY>-relevance.json` | SF relevance check result |
| `bug-<KEY>-score.json` | Reproducibility scoring |
| `bug-analysis-<KEY>.json` | Final analysis report |
| `bug-<KEY>-comment-draft.txt` | Draft comment (if requested) |

## Examples

```bash
# Basic analysis
/sfa-bug-analyze --issue-key ACM-12345

# Analyze and draft request-info comment
/sfa-bug-analyze --issue-key ACM-12345 --request-info

# Natural language
Analyze bug ACM-12345
Can we reproduce ACM-12345?
Check if ACM-12345 is SF-related and reproducible
```

## Notes

- **SF team members**: Loaded from `team-members/team-members.md`
- **SF components**: Keywords from `docs/repos.md`
- **Scoring thresholds**:
  - 0-3: Insufficient (cannot reproduce)
  - 4-7: Partial (may reproduce with assumptions)
  - 8-12: Good (ready to reproduce)
- **Authentication**: Uses `$JIRA_EMAIL` and `$JIRA_API_TOKEN`
- **Browse URL**: `https://redhat.atlassian.net/browse/<ISSUE-KEY>`

## Future Enhancements (Phase 3)

- Automated cluster provisioning with specified ACM/MCE version (using `install-acm` skill)
- Test execution based on parsed steps
- Result capture (logs, screenshots, success/failure)
- Jira comment with reproduction results
- Cleanup via `uninstall-acm` skill after reproduction
