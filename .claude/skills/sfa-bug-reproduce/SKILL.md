---
name: sfa-bug-reproduce
description: "Orchestrate full bug reproduction workflow: analyze bug, provision ACM cluster, execute test, capture results, and post to Jira. Use this skill when the user wants to reproduce a bug end-to-end, set up a test environment for a bug, or says 'reproduce bug ACM-12345', 'test ACM-12345', 'reproduce this bug automatically'."
---

# Bug Reproduction (Phase 3)

Orchestrate the complete bug reproduction workflow from analysis to cleanup.

This is the Phase 3 automation of the [analyze-bug-reproducibility solution](../../../solutions/analyze-bug-reproducibility.md).

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

### Step 1: Analyze bug reproducibility

Use `sfa-bug-analyze` to check if the bug has sufficient information:

```bash
ISSUE_KEY="<issue-key>"

# Run bug analysis (this creates .output/bug-analysis-${ISSUE_KEY}.json)
# Execute sfa-bug-analyze skill inline or call the scripts directly
mkdir -p .output

# Fetch bug
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "https://redhat.atlassian.net/rest/api/2/issue/$ISSUE_KEY" \
  > .output/bug-${ISSUE_KEY}-raw.json

# Extract fields and run analysis (simplified, see sfa-bug-analyze for full implementation)
# ... scoring logic ...

# Load analysis result
SCORE=$(jq -r '.reproducibility_score' .output/bug-analysis-${ISSUE_KEY}.json)
SF_RELEVANCE=$(jq -r '.sf_relevance' .output/bug-analysis-${ISSUE_KEY}.json)

if [[ "$SF_RELEVANCE" == "Not SF" ]]; then
  echo "❌ Bug is not SF-related. Stopping."
  exit 1
fi

if [[ $SCORE -lt 8 ]]; then
  echo "⚠️ Reproducibility score too low ($SCORE/12). Consider requesting more info first."
  echo "Missing: $(jq -r '.missing_info | join(", ")' .output/bug-analysis-${ISSUE_KEY}.json)"
  exit 1
fi

echo "✅ Bug is reproducible (Score: $SCORE/12, Relevance: $SF_RELEVANCE)"
```

**Decision point**: If score < 8 or Not SF, stop here and report to user.

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

## Future Enhancements

- **Smart step parsing**: NLP-based conversion of Jira reproduction steps to executable commands
- **Component-specific test templates**: Pre-built test scripts for common bug patterns
- **Screenshot capture**: Automated browser screenshots for UI bugs
- **Multi-cluster testing**: Test on different OCP versions and cloud providers
- **Regression testing**: Re-run reproduction for verification after fix
