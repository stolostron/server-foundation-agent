#!/usr/bin/env bash
#
# Interactive workflow for responding to Jira inbox items
#
# Usage:
#   ./interactive-update.sh [--inbox-file PATH]
#
# This script:
# 1. Displays the inbox with numbered list
# 2. Prompts user to select an issue
# 3. Shows issue context and recent comments
# 4. Prompts for update message
# 5. Posts the comment to Jira

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
JIRA_BASE_URL="${JIRA_BASE_URL:-https://redhat.atlassian.net}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-.output}"
INBOX_FILE="${OUTPUT_DIR}/inbox.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --inbox-file)
            INBOX_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate environment
if [[ -z "${JIRA_EMAIL:-}" ]]; then
    echo -e "${RED}Error: JIRA_EMAIL environment variable is required${NC}"
    exit 1
fi

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    echo -e "${RED}Error: JIRA_API_TOKEN environment variable is required${NC}"
    exit 1
fi

if [[ ! -f "$INBOX_FILE" ]]; then
    echo -e "${RED}Error: Inbox file not found: $INBOX_FILE${NC}"
    echo -e "${YELLOW}Tip: Run check-inbox.sh first to generate the inbox${NC}"
    exit 1
fi

# Function to display inbox
display_inbox() {
    echo -e "${BOLD}${CYAN}=== Your Jira Inbox ===${NC}\n"

    # Requires Action items
    local action_count=$(jq '.summary.requires_action' "$INBOX_FILE")
    echo -e "${BOLD}${RED}🔴 Requires Action (${action_count} issues):${NC}\n"

    jq -r '.requires_action[] |
        "\(.key)|\(.summary)|\(.status)|\(.reason)|\(.comment_to_reply)"' "$INBOX_FILE" | \
    while IFS='|' read -r key summary status reason comment; do
        i=$((${i:-0} + 1))
        printf "  %d. [%s] %s\n" $i "$key" "$summary"
        printf "     Status: %s | %s\n" "$status" "$reason"
        if [[ -n "$comment" ]]; then
            printf "     ${CYAN}Comment to reply: \"${comment}\"${NC}\n"
        fi
        printf "     https://redhat.atlassian.net/browse/%s\n\n" "$key"
    done

    echo -e "${BOLD}---${NC}\n"

    # Watching items (just count)
    local watching_count=$(jq '.summary.watching' "$INBOX_FILE")
    echo -e "${BOLD}${BLUE}📋 Watching (${watching_count} issues)${NC}"
    echo -e "   (Not shown - use check-inbox.sh --action-only to focus on action items)\n"
}

# Function to fetch issue details
fetch_issue_details() {
    local issue_key="$1"

    curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        "$JIRA_BASE_URL/rest/api/3/issue/$issue_key?fields=summary,status,description,comment" | \
        jq -r '
            "Issue: " + .key,
            "Summary: " + .fields.summary,
            "Status: " + .fields.status.name,
            "",
            "=== Recent Comments (last 3) ===",
            "",
            (.fields.comment.comments[-3:] | .[] |
                "---",
                "Author: " + .author.displayName,
                "Date: " + .created,
                "",
                (if (.body | type) == "object" then
                    (.body.content[]?.content[]? | select(.type == "text") | .text)
                else
                    .body
                end),
                ""
            )
        '
}

# Function to draft comment
draft_comment() {
    local user_message="$1"
    local today=$(date +%Y-%m-%d)

    # Format as Jira wiki markup (for API v2) or ADF (for API v3)
    # We'll use simple text format that works with both
    cat <<EOF
$user_message

----
_— server-foundation-agent ($today)_
EOF
}

# Function to post comment
post_comment() {
    local issue_key="$1"
    local comment_body="$2"

    # Use API v2 for comment posting (wiki markup)
    local response=$(curl -s -X POST \
        -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"body\": $(jq -R -s '.' <<< "$comment_body")}" \
        "$JIRA_BASE_URL/rest/api/2/issue/$issue_key/comment")

    if echo "$response" | jq -e '.id' >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Comment posted successfully${NC}"
        local comment_id=$(echo "$response" | jq -r '.id')
        echo -e "${CYAN}View: $JIRA_BASE_URL/browse/$issue_key?focusedCommentId=$comment_id${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to post comment${NC}"
        echo "$response" | jq -r '.errorMessages[]?, .errors | to_entries[] | "\(.key): \(.value)"' 2>/dev/null || echo "$response"
        return 1
    fi
}

# Main workflow
main() {
    display_inbox

    # Get total action items
    local total=$(jq '.summary.requires_action' "$INBOX_FILE")

    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}No action items! You're all caught up.${NC}"
        exit 0
    fi

    # Prompt for selection
    echo -e "${BOLD}Which issue would you like to respond to?${NC}"
    read -p "Enter number (1-$total) or issue key (e.g., ACM-12345), or 'q' to quit: " selection

    if [[ "$selection" == "q" ]] || [[ "$selection" == "Q" ]]; then
        echo "Exiting."
        exit 0
    fi

    # Get issue key
    local issue_key=""
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        # Numeric selection
        issue_key=$(jq -r ".requires_action[$((selection-1))].key" "$INBOX_FILE")
        if [[ "$issue_key" == "null" ]]; then
            echo -e "${RED}Invalid selection: $selection${NC}"
            exit 1
        fi
    else
        # Direct issue key
        issue_key="$selection"
    fi

    echo -e "\n${CYAN}Fetching details for $issue_key...${NC}\n"
    fetch_issue_details "$issue_key"

    # Prompt for message
    echo -e "\n${BOLD}What would you like to say?${NC}"
    echo "(Enter your message, press Ctrl+D when done, or Ctrl+C to cancel)"
    echo "---"
    user_message=$(cat)

    if [[ -z "$user_message" ]]; then
        echo -e "${YELLOW}No message entered. Exiting.${NC}"
        exit 0
    fi

    # Draft comment
    echo -e "\n${BOLD}Drafted comment:${NC}"
    echo "=================="
    drafted=$(draft_comment "$user_message")
    echo "$drafted"
    echo "=================="

    # Confirm
    echo -e "\n${BOLD}Post this comment to $issue_key?${NC}"
    read -p "(yes/no/edit): " confirm

    case "$confirm" in
        yes|y|Y)
            post_comment "$issue_key" "$drafted"
            ;;
        edit|e|E)
            echo -e "${YELLOW}Edit mode not yet implemented. Please re-run the script.${NC}"
            exit 1
            ;;
        *)
            echo -e "${YELLOW}Cancelled.${NC}"
            exit 0
            ;;
    esac
}

main
