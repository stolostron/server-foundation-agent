#!/usr/bin/env bash
#
# Check Jira inbox for action items
# Finds issues assigned to you, reported by you, or where you're mentioned
#
# Usage:
#   ./check-inbox.sh [--user EMAIL] [--action-only] [--days N]
#
# Environment Variables:
#   JIRA_EMAIL      - Jira account email (required)
#   JIRA_API_TOKEN  - Jira API token (required)
#   JIRA_BASE_URL   - Jira instance URL (default: https://redhat.atlassian.net)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Configuration
JIRA_BASE_URL="${JIRA_BASE_URL:-https://redhat.atlassian.net}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-.output}"

# Parameters
USER_EMAIL="${JIRA_EMAIL}"
ACTION_ONLY=false
DAYS=7

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            USER_EMAIL="$2"
            shift 2
            ;;
        --action-only)
            ACTION_ONLY=true
            shift
            ;;
        --days)
            DAYS="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate environment
if [[ -z "${JIRA_EMAIL:-}" ]]; then
    log_error "JIRA_EMAIL environment variable is required"
    exit 1
fi

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    log_error "JIRA_API_TOKEN environment variable is required"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

log_info "Checking Jira inbox for: $USER_EMAIL"

# JQL queries (will be properly JSON-encoded)
JQL_ASSIGNED="project = ACM AND assignee = '$USER_EMAIL' AND status NOT IN (Closed, Done, Resolved) ORDER BY status ASC, priority DESC"
JQL_REPORTED="project = ACM AND reporter = '$USER_EMAIL' AND status NOT IN (Closed, Done, Resolved) ORDER BY updated DESC"
JQL_MENTIONED="project = ACM AND status NOT IN (Closed, Done, Resolved) AND comment ~ '$USER_EMAIL' AND updated >= -${DAYS}d ORDER BY updated DESC"

# Function to run JQL query
run_jql_query() {
    local jql="$1"
    local output_file="$2"

    log_info "Running query: ${jql:0:80}..."

    # Use jq to properly construct JSON payload
    local payload=$(jq -n \
        --arg jql "$jql" \
        '{
            jql: $jql,
            maxResults: 100,
            fields: ["issuetype", "key", "summary", "status", "priority", "assignee", "reporter", "updated", "comment"]
        }')

    curl -s -X POST \
        -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$JIRA_BASE_URL/rest/api/3/search/jql" > "$output_file"

    if [[ ! -s "$output_file" ]]; then
        log_error "Query failed or returned no data"
        return 1
    fi

    # Check for errors
    if jq -e '.errorMessages' "$output_file" >/dev/null 2>&1; then
        log_error "Jira API error: $(jq -r '.errorMessages[]' "$output_file")"
        return 1
    fi

    local count=$(jq '.total' "$output_file")
    log_info "Found $count issues"
}

# Fetch all categories
log_info "Fetching assigned issues..."
run_jql_query "$JQL_ASSIGNED" "$OUTPUT_DIR/assigned.json"

log_info "Fetching reported issues..."
run_jql_query "$JQL_REPORTED" "$OUTPUT_DIR/reported.json"

log_info "Fetching mentioned issues..."
run_jql_query "$JQL_MENTIONED" "$OUTPUT_DIR/mentioned.json"

# Analyze and combine results
log_info "Analyzing action items..."
python3 "$SCRIPT_DIR/analyze-inbox.py" \
    --user "$USER_EMAIL" \
    --assigned "$OUTPUT_DIR/assigned.json" \
    --reported "$OUTPUT_DIR/reported.json" \
    --mentioned "$OUTPUT_DIR/mentioned.json" \
    --output "$OUTPUT_DIR/inbox.json"

# Display results
if [[ -f "$OUTPUT_DIR/inbox.json" ]]; then
    log_info "Inbox analysis complete"
    cat "$OUTPUT_DIR/inbox.json"
else
    log_error "Failed to generate inbox report"
    exit 1
fi
