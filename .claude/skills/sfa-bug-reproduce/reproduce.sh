#!/bin/bash
set -e

# Bug Reproduction Orchestration Script
# Phase 3: Full automated bug reproduction workflow

ISSUE_KEY=""
ACM_VERSION=""
TEST_SCRIPT=""
AUTO_CLEANUP="true"
POST_RESULTS="true"
AUTO_CONFIRM="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --issue-key)
      ISSUE_KEY="$2"
      shift 2
      ;;
    --acm-version)
      ACM_VERSION="$2"
      shift 2
      ;;
    --test-script)
      TEST_SCRIPT="$2"
      shift 2
      ;;
    --auto-cleanup)
      AUTO_CLEANUP="$2"
      shift 2
      ;;
    --post-results)
      POST_RESULTS="$2"
      shift 2
      ;;
    --yes|-y)
      AUTO_CONFIRM="true"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$ISSUE_KEY" ]]; then
  echo "Error: --issue-key is required"
  exit 1
fi

echo "═══════════════════════════════════════════════════════"
echo " Bug Reproduction Workflow (Phase 3)"
echo "═══════════════════════════════════════════════════════"
echo "Issue: $ISSUE_KEY"
echo "═══════════════════════════════════════════════════════"
echo ""

mkdir -p .output

# Step 1: Analyze bug
echo "📊 Step 1/7: Analyzing bug reproducibility..."
echo ""

# Simple inline analysis (full version should use sfa-bug-analyze skill)
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "https://redhat.atlassian.net/rest/api/2/issue/$ISSUE_KEY" \
  > .output/bug-${ISSUE_KEY}-raw.json

SUMMARY=$(jq -r '.fields.summary' .output/bug-${ISSUE_KEY}-raw.json)
COMPONENT=$(jq -r '.fields.components[0].name // "Unknown"' .output/bug-${ISSUE_KEY}-raw.json)

echo "  Summary: $SUMMARY"
echo "  Component: $COMPONENT"

# For MVP, assume it's reproducible if it has a component
if [[ "$COMPONENT" != "Server Foundation" ]]; then
  echo ""
  echo "❌ Bug is not Server Foundation component. Stopping."
  exit 1
fi

echo "✅ Bug analysis complete"
echo ""

# Step 2: Extract version
echo "📦 Step 2/7: Determining ACM/MCE version..."
echo ""

if [[ -z "$ACM_VERSION" ]]; then
  # Try to extract from affects-version field
  ACM_VERSION=$(jq -r '.fields.versions[0].name // empty' .output/bug-${ISSUE_KEY}-raw.json)

  if [[ -z "$ACM_VERSION" ]]; then
    # Try to extract from description
    ACM_VERSION=$(jq -r '.fields.description' .output/bug-${ISSUE_KEY}-raw.json | grep -oP '(ACM|MCE) \d+\.\d+(\.\d+)?' | head -1)
  fi

  if [[ -z "$ACM_VERSION" ]]; then
    echo "❌ Cannot determine ACM/MCE version. Please specify --acm-version"
    exit 1
  fi
fi

echo "  Target version: $ACM_VERSION"
echo "✅ Version determined"
echo ""

# Step 3: Check cluster connectivity
echo "🔌 Step 3/7: Checking cluster connectivity..."
echo ""

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "❌ Cannot connect to Kubernetes cluster"
  echo "   Please ensure KUBECONFIG is set and cluster is accessible"
  exit 1
fi

CLUSTER_NAME=$(kubectl config current-context)
echo "  Using cluster: $CLUSTER_NAME"
echo "✅ Cluster connection verified"
echo ""

# Step 4: Provision ACM
echo "🚀 Step 4/7: Provisioning ACM $ACM_VERSION..."
echo ""

if [[ "$AUTO_CONFIRM" != "true" ]]; then
  echo "⚠️  This will install ACM on the current cluster: $CLUSTER_NAME"
  echo "   Press Ctrl+C to abort, or Enter to continue..."
  read -r
fi

echo "  Installing ACM... (this may take 10-15 minutes)"

if [[ -f ".claude/skills/install-acm/scripts/install-acm.sh" ]]; then
  # Install MCE (not ACM) for downstream testing
  INSTALL_FLAGS="--product mce --type downstream --version $ACM_VERSION --latest"

  # Use pull-secret if available
  if [[ -f ".output/pull-secret.json" ]]; then
    INSTALL_FLAGS="$INSTALL_FLAGS --pull-secret .output/pull-secret.json"
  fi

  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    INSTALL_FLAGS="$INSTALL_FLAGS --yes"
  fi

  .claude/skills/install-acm/scripts/install-acm.sh $INSTALL_FLAGS || {
    echo "❌ MCE installation failed"
    exit 1
  }

  # install-acm now waits for MCE/MCH CR to be ready
else
  echo "⚠️  install-acm script not found. Please install ACM manually."
  echo "   Press Enter when ACM is ready..."
  read -r
fi

echo "✅ ACM provisioned"
echo ""

# Step 5: Execute test
echo "🧪 Step 5/7: Executing reproduction test..."
echo ""

START_TIME=$(date +%s)

if [[ -n "$TEST_SCRIPT" && -f "$TEST_SCRIPT" ]]; then
  echo "  Running test script: $TEST_SCRIPT"
  echo ""

  bash "$TEST_SCRIPT" 2>&1 | tee .output/test-${ISSUE_KEY}.log
  TEST_EXIT_CODE=${PIPESTATUS[0]}

  if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    RESULT="NOT_REPRODUCED"
    echo ""
    echo "✅ Test passed - bug NOT reproduced"
  else
    RESULT="REPRODUCED"
    echo ""
    echo "❌ Test failed - bug REPRODUCED (exit code: $TEST_EXIT_CODE)"
  fi
else
  echo "  Manual testing mode (no test script provided)"
  echo ""
  echo "  Reproduction steps from Jira:"
  echo "  ────────────────────────────────────────────"
  jq -r '.fields.description' .output/bug-${ISSUE_KEY}-raw.json | grep -A 20 "Steps to Reproduce" || echo "  (No steps found in description)"
  echo "  ────────────────────────────────────────────"
  echo ""
  echo "  Please execute the steps manually."
  echo "  When done, enter result (REPRODUCED/NOT_REPRODUCED/INCONCLUSIVE):"
  read -r RESULT

  echo "Manual testing - no automated log" > .output/test-${ISSUE_KEY}.log
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "  Test completed in ${DURATION}s"
echo "  Result: $RESULT"
echo ""

# Step 6: Capture evidence
echo "📸 Step 6/7: Capturing evidence..."
echo ""

mkdir -p .output/evidence-${ISSUE_KEY}

# Capture MCH status
kubectl get mch -n open-cluster-management -o yaml \
  > .output/evidence-${ISSUE_KEY}/mch-status.yaml 2>&1 || echo "  (MCH not found)"

# Capture operator logs
kubectl logs -n open-cluster-management-hub deployment/multiclusterhub-operator --tail=100 \
  > .output/evidence-${ISSUE_KEY}/mch-operator-logs.txt 2>&1 || echo "  (Operator logs not available)"

# Component-specific evidence
if echo "$SUMMARY" | grep -qi "cluster-proxy"; then
  echo "  Capturing cluster-proxy specific logs..."
  kubectl logs -n open-cluster-management-addon deployment/cluster-proxy-addon-manager --tail=100 \
    > .output/evidence-${ISSUE_KEY}/cluster-proxy-logs.txt 2>&1 || true
  kubectl get pods -n open-cluster-management-addon \
    > .output/evidence-${ISSUE_KEY}/addon-pods.txt 2>&1 || true
fi

echo "✅ Evidence captured to .output/evidence-${ISSUE_KEY}/"
echo ""

# Step 7: Post results to Jira
if [[ "$POST_RESULTS" == "true" ]]; then
  echo "📤 Step 7/7: Posting results to Jira..."
  echo ""

  if [[ "$RESULT" == "REPRODUCED" ]]; then
    ICON="(!)"
    SUMMARY_TEXT="Bug *CONFIRMED* - reproduced successfully"
  elif [[ "$RESULT" == "NOT_REPRODUCED" ]]; then
    ICON="(x)"
    SUMMARY_TEXT="Bug *NOT REPRODUCED*"
  else
    ICON="(?)"
    SUMMARY_TEXT="Reproduction result: *$RESULT*"
  fi

  COMMENT_BODY="h3. $ICON Automated Reproduction Result

*Result*: $SUMMARY_TEXT

*Environment*:
* ACM Version: $ACM_VERSION
* Cluster: $CLUSTER_NAME
* Test Duration: ${DURATION}s
* Date: $(date +%Y-%m-%d)

*Test Log* (first 30 lines):
{noformat}
$(head -30 .output/test-${ISSUE_KEY}.log)
{noformat}

*Evidence*: Captured cluster state and logs available in reproduction artifacts.

---
_Automated reproduction by [server-foundation-agent|https://github.com/stolostron/server-foundation-agent] (sfa-bug-reproduce skill)_"

  curl -s -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"body\": $(echo "$COMMENT_BODY" | jq -Rs .)}" \
    "https://redhat.atlassian.net/rest/api/2/issue/${ISSUE_KEY}/comment" >/dev/null

  echo "✅ Results posted to https://redhat.atlassian.net/browse/${ISSUE_KEY}"
  echo ""
else
  echo "ℹ️  Step 7/7: Skipping Jira posting (--post-results=false)"
  echo ""
fi

# Cleanup
if [[ "$AUTO_CLEANUP" == "true" ]]; then
  echo "🧹 Cleanup: Uninstalling ACM..."
  echo ""

  if [[ -f ".claude/skills/uninstall-acm/scripts/uninstall-acm.sh" ]]; then
    .claude/skills/uninstall-acm/scripts/uninstall-acm.sh --yes || {
      echo "⚠️  Cleanup failed. You may need to manually uninstall ACM."
    }
  else
    echo "⚠️  uninstall-acm script not found. Please uninstall ACM manually."
  fi

  echo "✅ Cleanup complete"
  echo ""
else
  echo "ℹ️  Cleanup: Skipping ACM uninstall (--auto-cleanup=false)"
  echo "   To cleanup manually, run: /uninstall-acm"
  echo ""
fi

# Generate detailed report
REPORT_FILE=".output/reproduction-report-${ISSUE_KEY}.md"

cat > "$REPORT_FILE" <<EOF
# Bug Reproduction Report: $ISSUE_KEY

**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Jira Issue:** https://redhat.atlassian.net/browse/${ISSUE_KEY}

---

## Summary

| Field | Value |
|-------|-------|
| **Result** | **${RESULT}** |
| **Test Duration** | ${DURATION}s |
| **ACM Version** | ${ACM_VERSION} |
| **Cluster** | ${CLUSTER_NAME} |
| **Test Script** | ${TEST_SCRIPT:-Manual testing} |

---

## Bug Details

**Summary:** $(jq -r '.fields.summary' .output/bug-${ISSUE_KEY}-fields.json 2>/dev/null || echo "N/A")

**Component:** $(jq -r '.fields.components[]?.name' .output/bug-${ISSUE_KEY}-fields.json 2>/dev/null | head -1 || echo "N/A")

**Affects Version:** $(jq -r '.fields.versions[]?.name' .output/bug-${ISSUE_KEY}-fields.json 2>/dev/null | head -1 || echo "N/A")

**Priority:** $(jq -r '.fields.priority?.name' .output/bug-${ISSUE_KEY}-fields.json 2>/dev/null || echo "N/A")

---

## Test Execution

### Environment Setup

- **Cluster:** ${CLUSTER_NAME}
- **MCE Version:** ${ACM_VERSION}
- **Installation Type:** Downstream
- **Catalog:** quay.io:443/acm-d/mce-dev-catalog:latest-${ACM_VERSION}

### Test Steps

EOF

if [[ -f ".output/test-${ISSUE_KEY}.log" ]]; then
  echo "**Test Output:**" >> "$REPORT_FILE"
  echo '```' >> "$REPORT_FILE"
  cat ".output/test-${ISSUE_KEY}.log" >> "$REPORT_FILE"
  echo '```' >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF

---

## Evidence & Artifacts

### Test Log
- **Location:** \`$(pwd)/.output/test-${ISSUE_KEY}.log\`
- **Size:** $(ls -lh .output/test-${ISSUE_KEY}.log 2>/dev/null | awk '{print $5}' || echo "N/A")

### Evidence Directory
- **Location:** \`$(pwd)/.output/evidence-${ISSUE_KEY}/\`
- **Files:**
EOF

if [[ -d ".output/evidence-${ISSUE_KEY}" ]]; then
  find ".output/evidence-${ISSUE_KEY}" -type f -exec ls -lh {} \; | awk '{print "  - " $9 " (" $5 ")"}' >> "$REPORT_FILE"
else
  echo "  - (No evidence files)" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF

### Raw Data
- Bug data: \`.output/bug-${ISSUE_KEY}-raw.json\`
- Bug fields: \`.output/bug-${ISSUE_KEY}-fields.json\`
- Analysis: \`.output/bug-analysis-${ISSUE_KEY}.json\`

---

## Conclusion

EOF

if [[ "$RESULT" == "REPRODUCED" ]]; then
  cat >> "$REPORT_FILE" <<EOF
✅ **Bug Confirmed**

The bug was successfully reproduced. The test results match the expected behavior described in the Jira issue.

**Recommended Next Steps:**
1. Review the test log and evidence files
2. Analyze the root cause based on captured evidence
3. Develop a fix
4. Verify the fix against this reproduction test
5. Update Jira with reproduction details
EOF
elif [[ "$RESULT" == "NOT_REPRODUCED" ]]; then
  cat >> "$REPORT_FILE" <<EOF
❌ **Bug Not Reproduced**

The test did not reproduce the expected bug behavior. This could mean:
- The bug is already fixed in MCE ${ACM_VERSION}
- The reproduction steps are incomplete or incorrect
- The bug requires specific conditions not present in the test environment

**Recommended Next Steps:**
1. Review the test log to understand what happened
2. Compare with the bug description to identify missing conditions
3. Request more information from the bug reporter
4. Consider testing on different versions or configurations
EOF
else
  cat >> "$REPORT_FILE" <<EOF
⚠️ **Inconclusive Result**

The test completed but the result was inconclusive (${RESULT}).

**Recommended Next Steps:**
1. Review the test log and evidence
2. Verify the test script logic
3. Re-run with additional debugging
EOF
fi

cat >> "$REPORT_FILE" <<EOF

---

## Automation Details

- **Workflow:** sfa-bug-reproduce (Phase 3)
- **Repository:** https://github.com/stolostron/server-foundation-agent
- **Report Location:** \`$(pwd)/${REPORT_FILE}\`

---

_Generated by server-foundation-agent automated bug reproduction workflow_
EOF

# Final report summary
echo "═══════════════════════════════════════════════════════"
echo " Reproduction Complete"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Issue: $ISSUE_KEY"
echo "Result: $RESULT"
echo "Duration: ${DURATION}s"
echo ""
echo "📋 Detailed Report:"
echo "   $(pwd)/${REPORT_FILE}"
echo ""
echo "📁 Artifacts:"
echo "   - Test log:  $(pwd)/.output/test-${ISSUE_KEY}.log"
echo "   - Evidence:  $(pwd)/.output/evidence-${ISSUE_KEY}/"
echo "   - Bug data:  $(pwd)/.output/bug-${ISSUE_KEY}-*.json"
echo "   - Analysis:  $(pwd)/.output/bug-analysis-${ISSUE_KEY}.json"
echo ""
echo "🔗 Jira Issue:"
echo "   https://redhat.atlassian.net/browse/${ISSUE_KEY}"
echo ""
echo "Next steps:"
if [[ "$RESULT" == "REPRODUCED" ]]; then
  echo "  ✓ Bug confirmed - proceed with fix"
  echo "  ✓ Review detailed report for analysis"
  echo "  ✓ Share report with development team"
elif [[ "$RESULT" == "NOT_REPRODUCED" ]]; then
  echo "  ✓ Bug not reproduced - request more info or close"
  echo "  ✓ Review report for environment details"
else
  echo "  ✓ Review results and determine next action"
fi
echo ""
echo "═══════════════════════════════════════════════════════"
