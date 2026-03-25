---
name: sfa-jira-inbox
description: "Check your Jira inbox and manage action items. Lists all issues related to you (assigned, reported, or mentioned in comments), identifies which need your response, helps draft updates with your approval. Use when checking inbox, managing action items, or when the user says 'jira inbox', 'what needs my attention', 'jira action items', 'check my jiras', 'inbox', 'what do I need to respond to'."
---

# Jira Inbox

Check your Jira inbox and manage action items across all issues related to you.

## Reference Loading

Before executing, load relevant references as needed:
- **For JQL syntax**: Read `docs/jira/jql-reference.md`
- **For API details**: Read `docs/jira/api-reference.md`
- **For custom fields**: Read `docs/jira/custom-fields.md`
- **For comment formatting**: Read `docs/jira/formatting.md`

## Parameters

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| user | No | current user | Team member name or email to check inbox for |
| action-only | No | `false` | If true, only show issues requiring action |
| days | No | `7` | Look back N days for comment mentions |

## Workflow

### Step 1: Resolve user identity

1. If `user` specified, look up in `team-members/team-members.md` using fuzzy name matching
2. Get their **email** as Jira identifier
3. If unspecified, use current user's email from `$JIRA_EMAIL`

### Step 2: Fetch related issues

Fetch three categories of issues in parallel using `/rest/api/3/search/jql` POST endpoint:

**A. Assigned to user:**
```jql
project = ACM AND assignee = <email> AND status NOT IN (Closed, Done, Resolved)
```

**B. Reported by user:**
```jql
project = ACM AND reporter = <email> AND status NOT IN (Closed, Done, Resolved)
```

**C. Mentioned in recent comments:**
```jql
project = ACM AND status NOT IN (Closed, Done, Resolved) AND comment ~ <email>
```

For all queries, request these fields:
```json
["issuetype", "key", "summary", "status", "priority", "assignee", "reporter", "updated", "comment"]
```

### Step 3: Analyze action items

For each issue, determine if action is needed by checking:

1. **Assigned issues**:
   - Status = "New" or "In Progress" → needs work
   - Status = "Review" → may need response to reviewer feedback
   - Status = "Testing" → may need test confirmation

2. **Reported issues**:
   - Check latest comment (if not from reporter) → may need response
   - Status changed recently → may need acknowledgment

3. **Mentioned issues**:
   - Parse comments to find mentions of user (by name or email)
   - Check if user already responded after the mention
   - If no response yet → needs attention

**Comment Analysis Logic:**

For issues with comments, parse the comment array chronologically:
- Find all comments mentioning the user (search for `@<name>` or `<email>` in comment body)
- For each mention, check if user has commented after that timestamp
- If no subsequent comment from user → flag as "needs response"

### Step 4: Present inbox summary

Display results in sections:

```markdown
## Your Jira Inbox

### 🔴 Requires Action (<count>)

| Type | Key | Summary | Status | Reason |
|------|-----|---------|--------|--------|
| Bug | ACM-123 | ... | New | Assigned, no progress |
| Story | ACM-456 | ... | Review | Mentioned by @alice, no response |

### 📋 Watching (<count>)

| Type | Key | Summary | Status | Last Updated |
|------|-----|---------|--------|--------------|
| Epic | ACM-789 | ... | In Progress | 2 days ago |

**Total**: <X> issues require action, <Y> watching
```

**Reason codes**:
- "Assigned, no progress" - assigned issue in New/Backlog
- "Mentioned by @user, no response" - user mentioned in comment, hasn't replied
- "Awaiting your input" - issue in Review/Testing, may need feedback
- "Reporter follow-up" - user reported, latest comment from someone else

### Step 5: Interactive update workflow

After showing the inbox, ask:
```
Which issue would you like to update? (provide issue key or number from list)
```

When user selects an issue:

1. **Show context**: Display issue summary, latest comments (last 3)
2. **Ask for update overview**: "What would you like to say?"
3. **Draft refined message**: Based on user's input, draft a professional Jira comment following the format in `docs/jira/formatting.md`
4. **Get approval**: Show the drafted comment and ask "Post this comment? [yes/no/edit]"
5. **Post comment**: If approved, use the same API as `sfa-jira-comment`:

```bash
curl -s -X POST \
  -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"body": "<wiki markup text>"}' \
  "https://redhat.atlassian.net/rest/api/2/issue/<KEY>/comment"
```

6. **Update status** (optional): Ask if issue status should change (e.g., New → In Progress)
7. **Confirm**: Show comment URL and updated status

## Comment Refinement

When drafting responses, follow these principles:

1. **Structure**: Use sections for complex updates
2. **Clarity**: Be specific about actions taken or planned
3. **Tone**: Professional but conversational
4. **Wiki markup**: Apply formatting (bold, lists, code blocks) per `docs/jira/formatting.md`
5. **Footer**: Always append:
   ```
   ----
   _— server-foundation-agent_
   ```

## Examples

```bash
/sfa-jira-inbox
/sfa-jira-inbox --action-only
/sfa-jira-inbox --user "zhiwei"
Check my jira inbox
What needs my attention in jira?
Show me qiujian's action items
```

## Integration Notes

- Combines functionality of `sfa-jira-search` (finding issues) and `sfa-jira-comment` (posting updates)
- Can trigger `sfa-jira-update` for status transitions
- Use this skill for proactive inbox management; use `sfa-jira-search` for ad-hoc queries
