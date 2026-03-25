#!/usr/bin/env python3
"""
Analyze Jira inbox and identify action items.

Processes assigned, reported, and mentioned issues to determine which ones
require user action.
"""

import argparse
import json
import sys
from datetime import datetime
from typing import Dict, List, Set


def parse_args():
    parser = argparse.ArgumentParser(description="Analyze Jira inbox for action items")
    parser.add_argument("--user", required=True, help="User email address")
    parser.add_argument("--assigned", required=True, help="Assigned issues JSON file")
    parser.add_argument("--reported", required=True, help="Reported issues JSON file")
    parser.add_argument("--mentioned", required=True, help="Mentioned issues JSON file")
    parser.add_argument("--output", required=True, help="Output JSON file")
    return parser.parse_args()


def load_issues(filepath: str) -> List[Dict]:
    """Load issues from JSON file."""
    try:
        with open(filepath, 'r') as f:
            data = json.load(f)
            return data.get('issues', [])
    except FileNotFoundError:
        print(f"Warning: File not found: {filepath}", file=sys.stderr)
        return []
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON from {filepath}: {e}", file=sys.stderr)
        return []


def extract_email(account_obj: Dict) -> str:
    """Extract email from Jira account object."""
    if not account_obj:
        return ""
    return account_obj.get("emailAddress", "")


def check_assigned_action_needed(issue: Dict) -> tuple[bool, str]:
    """Check if assigned issue needs action."""
    status = issue['fields']['status']['name']

    # Map status to action needs
    if status in ["New", "Backlog"]:
        return True, "Assigned, no progress"
    elif status == "In Progress":
        return False, "In progress"
    elif status in ["Review", "Testing"]:
        return True, "Awaiting your input"
    else:
        return False, f"Status: {status}"


def check_reported_action_needed(issue: Dict, user_email: str) -> tuple[bool, str]:
    """Check if reported issue needs action."""
    comments = issue['fields'].get('comment', {}).get('comments', [])

    if not comments:
        return False, "No comments"

    # Get latest comment
    latest_comment = comments[-1]
    author_email = extract_email(latest_comment.get('author'))

    # If latest comment is not from reporter, may need response
    if author_email != user_email:
        author_name = latest_comment.get('author', {}).get('displayName', 'someone')
        return True, f"Reporter follow-up (comment by {author_name})"

    return False, "Latest comment is yours"


def check_mentioned_action_needed(issue: Dict, user_email: str) -> tuple[bool, str]:
    """Check if mentioned issue needs response."""
    comments = issue['fields'].get('comment', {}).get('comments', [])

    if not comments:
        return False, "No comments"

    # Find mentions of user
    mentions = []
    for i, comment in enumerate(comments):
        body = comment.get('body', '')
        author_email = extract_email(comment.get('author'))

        # Check if user is mentioned (by email or @mention)
        # Jira wiki markup uses [~accountid] for mentions, but email might appear in plain text
        if user_email.lower() in body.lower() and author_email != user_email:
            mention_author = comment.get('author', {}).get('displayName', 'someone')
            mention_time = comment.get('created', '')
            mentions.append({
                'index': i,
                'author': mention_author,
                'time': mention_time
            })

    if not mentions:
        return False, "No mentions found"

    # Check if user has responded after the last mention
    last_mention_idx = mentions[-1]['index']
    user_responded = False

    for comment in comments[last_mention_idx + 1:]:
        author_email = extract_email(comment.get('author'))
        if author_email == user_email:
            user_responded = True
            break

    if not user_responded:
        mention_author = mentions[-1]['author']
        return True, f"Mentioned by {mention_author}, no response"

    return False, "Already responded"


def analyze_inbox(user_email: str, assigned: List[Dict], reported: List[Dict], mentioned: List[Dict]) -> Dict:
    """Analyze all inbox items and categorize them."""
    requires_action = []
    watching = []
    seen_keys = set()

    # Process assigned issues
    for issue in assigned:
        key = issue['key']
        if key in seen_keys:
            continue
        seen_keys.add(key)

        needs_action, reason = check_assigned_action_needed(issue)

        item = {
            'key': key,
            'type': issue['fields']['issuetype']['name'],
            'summary': issue['fields']['summary'],
            'status': issue['fields']['status']['name'],
            'priority': issue['fields'].get('priority', {}).get('name', 'None'),
            'updated': issue['fields']['updated'],
            'category': 'assigned',
            'reason': reason,
            'url': f"https://redhat.atlassian.net/browse/{key}"
        }

        if needs_action:
            requires_action.append(item)
        else:
            watching.append(item)

    # Process reported issues
    for issue in reported:
        key = issue['key']
        if key in seen_keys:
            continue
        seen_keys.add(key)

        needs_action, reason = check_reported_action_needed(issue, user_email)

        item = {
            'key': key,
            'type': issue['fields']['issuetype']['name'],
            'summary': issue['fields']['summary'],
            'status': issue['fields']['status']['name'],
            'priority': issue['fields'].get('priority', {}).get('name', 'None'),
            'updated': issue['fields']['updated'],
            'category': 'reported',
            'reason': reason,
            'url': f"https://redhat.atlassian.net/browse/{key}"
        }

        if needs_action:
            requires_action.append(item)
        else:
            watching.append(item)

    # Process mentioned issues
    for issue in mentioned:
        key = issue['key']
        if key in seen_keys:
            continue
        seen_keys.add(key)

        needs_action, reason = check_mentioned_action_needed(issue, user_email)

        item = {
            'key': key,
            'type': issue['fields']['issuetype']['name'],
            'summary': issue['fields']['summary'],
            'status': issue['fields']['status']['name'],
            'priority': issue['fields'].get('priority', {}).get('name', 'None'),
            'updated': issue['fields']['updated'],
            'category': 'mentioned',
            'reason': reason,
            'url': f"https://redhat.atlassian.net/browse/{key}"
        }

        if needs_action:
            requires_action.append(item)
        else:
            watching.append(item)

    return {
        'user': user_email,
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'summary': {
            'requires_action': len(requires_action),
            'watching': len(watching),
            'total': len(requires_action) + len(watching)
        },
        'requires_action': requires_action,
        'watching': watching
    }


def main():
    args = parse_args()

    # Load issues from files
    assigned = load_issues(args.assigned)
    reported = load_issues(args.reported)
    mentioned = load_issues(args.mentioned)

    # Analyze inbox
    inbox = analyze_inbox(args.user, assigned, reported, mentioned)

    # Write output
    with open(args.output, 'w') as f:
        json.dump(inbox, f, indent=2)

    print(f"Analysis complete: {inbox['summary']['requires_action']} require action, "
          f"{inbox['summary']['watching']} watching", file=sys.stderr)


if __name__ == "__main__":
    main()
