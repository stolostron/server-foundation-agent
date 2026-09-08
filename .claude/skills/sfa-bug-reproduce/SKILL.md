---
name: sfa-bug-reproduce
description: "Orchestrate full bug reproduction workflow: analyze bug, provision ACM cluster, execute test, capture results, and post to Jira. Use this skill when the user wants to reproduce a bug end-to-end, set up a test environment for a bug, or says 'reproduce bug ACM-12345', 'test ACM-12345', 'reproduce this bug automatically'. Skips embargoed issues (Embargoed Bug issuetype or Embargoed Security Issue security level)."
---

# Bug Reproduction

Orchestrate the complete bug reproduction workflow from analysis to cleanup.

Runs [sfa-bug-analyze](../sfa-bug-analyze/SKILL.md) first, then provisions ACM/MCE, executes tests, and posts results. The [bug-analyze workflow](../../../workflows/bug-analyze.md) also redirects to these skills.

### Embargoed issues (do not reproduce)

Honor the same guards as [sfa-bug-analyze](../sfa-bug-analyze/SKILL.md) Step 1.5. Skip when **either**:

| Signal | Jira field | Value |
|--------|------------|-------|
| Issue type | `issuetype` | `Embargoed Bug` |
| Security level | `security` / `security_level` | `Embargoed Security Issue` |

Check **three times**: after initial Jira fetch (before SF/score gates), again **before provisioning** (Step 3), and again **before posting results** (Step 6). Re-fetch the issue on each guard so a mid-run embargo change is caught.

On skip: do **not** provision, test, post Jira comments, or capture/post embargo details. Write `.output/reproduction-<KEY>.json` with `status: "skipped"` and exit successfully.

## Parameters

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| issue-key | Yes | - | Jira issue key (e.g., `ACM-30940`) |
| cluster-name | No | auto-detect | OCP cluster to use (via KUBECONFIG or current context) |
| acm-version | No | from bug | ACM/MCE version to install (extracted from bug if not specified) |
| test-script | No | - | Path to test script to execute (if not provided, manual testing) |
| auto-cleanup | No | `true` | Automatically uninstall ACM after reproduction |
| post-results | No | `true` | Post reproduction results as Jira comment |
| yes | No | `false` | Skip all interactive confirmations (enables full automation) |

## Workflow

### Embargo guard helper

Reuse this snippet at each checkpoint (Steps 1, 3, 6). On match, write skipped outcome and stop.

```bash
write_skipped_embargo_outcome() {
  local signal="$1"
  cat > ".output/reproduction-${ISSUE_KEY}.json" <<EOF
{
  "issue_key": "${ISSUE_KEY}",
  "status": "skipped",
  "skip_reason": "embargoed",
  "embargo_signal": "${signal}",
  "completed_at": "$(date -Iseconds)"
}
EOF
}

write_jira_validation_failed_outcome() {
  local detail="$1"
  cat > ".output/reproduction-${ISSUE_KEY}.json" <<EOF
{
  "issue_key": "${ISSUE_KEY}",
  "status": "skipped",
  "skip_reason": "jira_validation_failed",
  "validation_error": "${detail}",
  "completed_at": "$(date -Iseconds)"
}
EOF
}

# Fail closed: require HTTP 200, valid JSON, fields.issuetype.name (string).
# fields.security must be JSON null (unset) or an object with a non-empty name.
load_jira_embargo_fields() {
  local raw="$1"
  local issue_type="$2"
  local security_level="$3"

  if ! jq -e . "$raw" >/dev/null 2>&1; then
    return 1
  fi
  if ! jq -e '.fields.issuetype.name | type == "string" and length > 0' "$raw" >/dev/null 2>&1; then
    return 1
  fi
  local sec_kind
  sec_kind=$(jq -r '.fields.security | type' "$raw" 2>/dev/null || echo "invalid")
  case "$sec_kind" in
    null)
      printf -v "$issue_type" '%s' "$(jq -r '.fields.issuetype.name' "$raw")"
      printf -v "$security_level" '%s' ""
      return 0
      ;;
    object)
      if ! jq -e '.fields.security.name | type == "string" and length > 0' "$raw" >/dev/null 2>&1; then
        return 1
      fi
      printf -v "$issue_type" '%s' "$(jq -r '.fields.issuetype.name' "$raw")"
      printf -v "$security_level" '%s' "$(jq -r '.fields.security.name' "$raw")"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_jira_embargo_raw() {
  local raw="$1"
  local fields="${2:-issuetype,security}"
  local http_code
  http_code=$(curl -sS -w "%{http_code}" -o "$raw" \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    "https://redhat.atlassian.net/rest/api/2/issue/${ISSUE_KEY}?fields=${fields}") || return 1
  [[ "$http_code" == "200" ]]
}

check_embargo_or_skip() {
  local raw=".output/bug-${ISSUE_KEY}-raw.json"
  if ! fetch_jira_embargo_raw "$raw" "issuetype,security,summary,components,versions,description,priority"; then
    write_jira_validation_failed_outcome "Jira fetch failed or non-200 response"
    echo "Skipped: could not fetch Jira issue for embargo check (fail closed)."
    exit 0
  fi
  local issue_type security_level
  if ! load_jira_embargo_fields "$raw" issue_type security_level; then
    write_jira_validation_failed_outcome "missing or invalid issuetype/security fields"
    echo "Skipped: could not validate Jira embargo fields (fail closed)."
    exit 0
  fi
  if [[ "$issue_type" == "Embargoed Bug" ]]; then
    write_skipped_embargo_outcome "Embargoed Bug"
    echo "Skipped: issuetype Embargoed Bug (human handling only)."
    exit 0
  fi
  if [[ "$security_level" == "Embargoed Security Issue" ]]; then
    write_skipped_embargo_outcome "Embargoed Security Issue"
    echo "Skipped: security level Embargoed Security Issue (human handling only)."
    exit 0
  fi
}
```

### Step 1: Analyze bug reproducibility

Use `sfa-bug-analyze` to check if the bug has sufficient information:

```bash
ISSUE_KEY="<issue-key>"

mkdir -p .output

# Guard 1 — before analysis / SF relevance / score checks
check_embargo_or_skip

# Run sfa-bug-analyze (creates .output/bug-analysis-${ISSUE_KEY}.json)
# Or execute its scripts inline — see sfa-bug-analyze/SKILL.md

SCORE=$(jq -r '.reproducibility_score' .output/bug-analysis-${ISSUE_KEY}.json)
SF_RELEVANCE=$(jq -r '.sf_relevance' .output/bug-analysis-${ISSUE_KEY}.json)

if [[ "$SF_RELEVANCE" == "Not SF" ]]; then
  echo "Bug is not SF-related. Stopping."
  exit 1
fi

if [[ $SCORE -lt 8 ]]; then
  echo "Reproducibility score too low ($SCORE/12). Consider requesting more info first."
  echo "Missing: $(jq -r '.missing_info | join(", ")' .output/bug-analysis-${ISSUE_KEY}.json)"
  exit 1
fi

echo "Bug is reproducible (Score: $SCORE/12, Relevance: $SF_RELEVANCE)"
```

**Decision point**: Embargo skip exits 0 with `status: skipped`. If score < 8 or Not SF, stop and report to user.

### Step 2: Extract ACM/MCE version

Extract version from the bug analysis:

```bash
# Get version from affects-version or description
ACM_VERSION=${acm-version:-$(jq -r '.summary' .output/bug-analysis-${ISSUE_KEY}.json | grep -oP '(ACM|MCE) \d+\.\d+' | head -1)}

if [[ -z "$ACM_VERSION" ]]; then
  echo "❌ Cannot determine ACM/MCE version from bug. Please specify --acm-version"
  exit 1
fi

echo "📦 Target version: $ACM_VERSION"

# Save to reproduction context
cat > .output/reproduction-${ISSUE_KEY}.json << EOF
{
  "issue_key": "$ISSUE_KEY",
  "acm_version": "$ACM_VERSION",
  "started_at": "$(date -Iseconds)",
  "cluster": "$(kubectl config current-context 2>/dev/null || echo 'unknown')"
}
EOF
```

### Step 3: Provision ACM cluster

**Guard 2** — re-fetch and skip before any cluster work:

```bash
check_embargo_or_skip
```

Use `install-acm` skill to set up the test environment:

```bash
echo "🚀 Provisioning ACM $ACM_VERSION on cluster..."

# Check cluster connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "❌ Cannot connect to Kubernetes cluster. Check KUBECONFIG."
  exit 1
fi

CLUSTER_NAME=$(kubectl config current-context)
echo "📍 Using cluster: $CLUSTER_NAME"

# Install ACM (this will invoke install-acm skill or script)
# For now, user needs to run: /install-acm --version "$ACM_VERSION"
# Or we can call the script directly:

.claude/skills/install-acm/scripts/install-acm.sh --version "$ACM_VERSION" --wait

if [[ $? -ne 0 ]]; then
  echo "❌ ACM installation failed"
  exit 1
fi

echo "✅ ACM $ACM_VERSION installed successfully"
```

### Step 4: Execute reproduction steps

**Option A: Automated execution (future)**
Parse steps from Jira description and attempt to execute them.

**Option B: User-provided test script (Phase 3 MVP)**
Execute a test script provided by the user:

```bash
if [[ -n "$test-script" ]]; then
  echo "🧪 Executing test script: $test-script"

  # Capture output
  bash "$test-script" 2>&1 | tee .output/test-${ISSUE_KEY}.log
  TEST_EXIT_CODE=${PIPESTATUS[0]}

  if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "✅ Test script passed"
    RESULT="PASS"
  else
    echo "❌ Test script failed (exit code: $TEST_EXIT_CODE)"
    RESULT="FAIL"
  fi
else
  echo "📝 Manual testing mode"
  echo ""
  echo "Reproduction steps from Jira:"
  jq -r '.description' .output/bug-${ISSUE_KEY}-fields.json | grep -A 20 "Steps to Reproduce"
  echo ""
  echo "Please execute the steps manually and verify the bug."
  echo "Press Enter when done, then type PASS or FAIL:"
  read -r RESULT
fi

# Update reproduction context
jq --arg result "$RESULT" \
   --arg log "$(cat .output/test-${ISSUE_KEY}.log 2>/dev/null || echo 'Manual testing - no log')" \
   '.result = $result | .test_log = $log | .completed_at = (now | strftime("%Y-%m-%dT%H:%M:%S%z"))' \
   .output/reproduction-${ISSUE_KEY}.json > .output/reproduction-${ISSUE_KEY}.tmp.json
mv .output/reproduction-${ISSUE_KEY}.tmp.json .output/reproduction-${ISSUE_KEY}.json
```

**Option C: Interactive mode**
Guide the user through each step interactively.

### Step 5: Capture evidence

Collect logs, screenshots, and cluster state:

```bash
echo "📸 Capturing evidence..."

mkdir -p .output/evidence-${ISSUE_KEY}

# Capture relevant logs based on bug component
# Example: for cluster-proxy bugs
if jq -r '.summary' .output/bug-${ISSUE_KEY}-fields.json | grep -qi "cluster-proxy"; then
  kubectl logs -n open-cluster-management-addon deployment/cluster-proxy-addon-manager \
    > .output/evidence-${ISSUE_KEY}/cluster-proxy-logs.txt 2>&1 || true
  kubectl get pods -n open-cluster-management-addon \
    > .output/evidence-${ISSUE_KEY}/addon-pods.txt 2>&1 || true
fi

# Capture MultiClusterHub status
kubectl get mch -n open-cluster-management -o yaml \
  > .output/evidence-${ISSUE_KEY}/mch-status.yaml 2>&1 || true

# Capture operator logs
kubectl logs -n open-cluster-management-hub deployment/multiclusterhub-operator --tail=100 \
  > .output/evidence-${ISSUE_KEY}/mch-operator-logs.txt 2>&1 || true

echo "✅ Evidence captured to .output/evidence-${ISSUE_KEY}/"
```

### Step 6: Post results to Jira

**Guard 3** — re-fetch before posting; if embargoed now, skip comment only (preserve local artifacts):

```bash
if [[ "$post-results" == "true" ]]; then
  raw=".output/bug-${ISSUE_KEY}-raw.json"
  if ! fetch_jira_embargo_raw "$raw" "issuetype,security"; then
    write_jira_validation_failed_outcome "Jira fetch failed or non-200 response"
    echo "Skipped Jira post: could not fetch issue for embargo check (fail closed)."
    post-results="false"
  elif ! load_jira_embargo_fields "$raw" issue_type security_level; then
    write_jira_validation_failed_outcome "missing or invalid issuetype/security fields"
    echo "Skipped Jira post: could not validate embargo fields (fail closed)."
    post-results="false"
  elif [[ "$issue_type" == "Embargoed Bug" || "$security_level" == "Embargoed Security Issue" ]]; then
    signal="$issue_type"
    [[ "$security_level" == "Embargoed Security Issue" ]] && signal="$security_level"
    write_skipped_embargo_outcome "$signal"
    echo "Skipped Jira post: embargoed issue (human handling only)."
    post-results="false"
  fi
fi
```

If `--post-results=true`, post reproduction results as a Jira comment:

```bash
if [[ "$post-results" == "true" ]]; then
  echo "📤 Posting results to Jira..."

  # Build comment body
  if [[ "$RESULT" == "PASS" ]]; then
    ICON="(x)"
    SUMMARY="Reproduction attempt: *Bug NOT reproduced*"
  elif [[ "$RESULT" == "FAIL" ]]; then
    ICON="(!)"
    SUMMARY="Reproduction attempt: *Bug confirmed*"
  else
    ICON="(?)"
    SUMMARY="Reproduction attempt: *$RESULT*"
  fi

  cat > .output/jira-comment-${ISSUE_KEY}.txt << 'ENDOFCOMMENT'
h3. $ICON $SUMMARY

*Environment:*
* ACM Version: $ACM_VERSION
* Cluster: $CLUSTER_NAME
* Date: $(date +%Y-%m-%d)

*Test Result:* $RESULT

*Evidence:*
See attached logs in comment attachments or reproduction log below.

{noformat}
$(head -50 .output/test-${ISSUE_KEY}.log 2>/dev/null || echo "No test log available")
{noformat}

---
_Automated reproduction by [server-foundation-agent|https://github.com/stolostron/server-foundation-agent] (sfa-bug-reproduce skill)_
ENDOFCOMMENT

  # Expand variables in comment
  eval "cat <<EOF
$(cat .output/jira-comment-${ISSUE_KEY}.txt)
EOF
" > .output/jira-comment-${ISSUE_KEY}-expanded.txt

  # Post to Jira
  COMMENT_BODY=$(cat .output/jira-comment-${ISSUE_KEY}-expanded.txt)

  curl -s -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"body\": $(echo "$COMMENT_BODY" | jq -Rs .)}" \
    "https://redhat.atlassian.net/rest/api/2/issue/${ISSUE_KEY}/comment"

  echo "✅ Results posted to https://redhat.atlassian.net/browse/${ISSUE_KEY}"
fi
```

### Step 7: Cleanup

If `--auto-cleanup=true`, uninstall ACM after testing:

```bash
if [[ "$auto-cleanup" == "true" ]]; then
  echo "🧹 Cleaning up ACM installation..."

  # Use uninstall-acm skill
  .claude/skills/uninstall-acm/scripts/uninstall-acm.sh --yes

  echo "✅ Cleanup complete"
else
  echo "ℹ️  Skipping cleanup. ACM installation preserved for manual inspection."
  echo "   To cleanup manually: /uninstall-acm"
fi
```

### Step 8: Generate reproduction report

Create a final summary report:

```bash
cat > .output/reproduction-report-${ISSUE_KEY}.md << EOF
# Bug Reproduction Report: $ISSUE_KEY

**Bug**: $(jq -r '.summary' .output/bug-${ISSUE_KEY}-fields.json)
**Jira**: https://redhat.atlassian.net/browse/${ISSUE_KEY}

## Analysis

- **SF Relevance**: $SF_RELEVANCE
- **Reproducibility Score**: $SCORE/12
- **Recommendation**: $(jq -r '.recommendation' .output/bug-analysis-${ISSUE_KEY}.json)

## Test Environment

- **ACM Version**: $ACM_VERSION
- **Cluster**: $CLUSTER_NAME
- **Started**: $(jq -r '.started_at' .output/reproduction-${ISSUE_KEY}.json)
- **Completed**: $(jq -r '.completed_at' .output/reproduction-${ISSUE_KEY}.json)

## Reproduction Result

**Result**: $RESULT

### Test Log

\`\`\`
$(cat .output/test-${ISSUE_KEY}.log 2>/dev/null || echo "No test log")
\`\`\`

## Evidence

Evidence files saved to: \`.output/evidence-${ISSUE_KEY}/\`

$(ls -lh .output/evidence-${ISSUE_KEY}/ 2>/dev/null || echo "No evidence files")

## Next Steps

- [x] Bug analyzed
- [x] Environment provisioned
- [x] Reproduction attempted
- [x] Evidence captured
- [x] Results posted to Jira
- [x] Cleanup completed

**Recommendation**: $(if [[ "$RESULT" == "FAIL" ]]; then echo "Bug confirmed. Proceed with fix."; else echo "Bug not reproduced. Request more info or close as cannot reproduce."; fi)
EOF

cat .output/reproduction-report-${ISSUE_KEY}.md
```

## Output Files

All artifacts saved to `.output/`:

| File | Description |
|------|-------------|
| `bug-analysis-<KEY>.json` | Bug analysis from sfa-bug-analyze |
| `reproduction-<KEY>.json` | Reproduction context and results |
| `test-<KEY>.log` | Test execution log |
| `evidence-<KEY>/` | Directory with captured logs, YAML dumps |
| `jira-comment-<KEY>.txt` | Draft Jira comment |
| `reproduction-report-<KEY>.md` | Final summary report |

## Examples

```bash
# Full automated reproduction with test script
/sfa-bug-reproduce --issue-key ACM-30940 --test-script ./test-acm-30940.sh

# Manual testing mode
/sfa-bug-reproduce --issue-key ACM-31402

# Specify version explicitly, skip cleanup
/sfa-bug-reproduce --issue-key ACM-30940 --acm-version "MCE 2.17.0" --auto-cleanup false

# Natural language
Reproduce bug ACM-30940
Test ACM-31402 on a fresh cluster
```

## Notes

- **Cluster access**: Requires valid `KUBECONFIG` and cluster admin permissions
- **ACM installation time**: Typically 10-15 minutes
- **Test scripts**: Should exit 0 for pass, non-zero for fail
- **Evidence collection**: Customize based on bug component (cluster-proxy, import-controller, etc.)
- **Jira auth**: Uses `$JIRA_EMAIL` and `$JIRA_API_TOKEN`
- **Embargoed issues**: Skipped with `status: skipped` in `reproduction-<KEY>.json` — no Jira comments

## Future Enhancements

- **Smart step parsing**: NLP-based conversion of Jira reproduction steps to executable commands
- **Component-specific test templates**: Pre-built test scripts for common bug patterns
- **Screenshot capture**: Automated browser screenshots for UI bugs
- **Multi-cluster testing**: Test on different OCP versions and cloud providers
- **Regression testing**: Re-run reproduction for verification after fix
