---
name: sfa-jira-feature-create
description: "Create a Server Foundation Feature in the ACM Jira project with all standard SF fields pre-populated. Use when the user wants to create a new SF Feature, says 'create a feature', 'new feature for SF', or describes a piece of work that needs tracking as a Feature in ACM."
---

# SF Jira Feature Create

Create a Feature in the ACM Jira project with Server Foundation defaults pre-applied. Collects the fields that vary, fills in the rest automatically, and confirms before creating.

## Defaults (applied automatically)

| Field | Default |
|-------|---------|
| Issue type | Feature |
| Assignee | Luke Bainbridge (lbainbri@redhat.com) |
| Component | Server Foundation |
| Activity Type | Product / Portfolio Work |
| Priority | Normal |

## Optional: copy from existing issue

If the user provides a `copy-from` issue key (e.g. `copy-from: ACM-35121`), fetch that issue first and prefill all fields from it. Then ask the user what they want to change before proceeding. This is useful for recreating a closed issue, templating a similar Feature, or targeting a new release.

## Fields to collect

Ask the user for the following. Ask all at once unless context already provides them. If the user pastes raw notes or content from another issue, clean it up and format it appropriately — do not ask the user to reformat it themselves.

1. **Summary** — one-line title for the Feature
2. **Description** — problem statement and acceptance criteria (offer to draft if user provides context)
3. **PM** — who is the PM for this feature?
4. **Architect** — who is the architect for this feature?
5. **Contributors** — any additional contributors (optional)
6. **Labels** — e.g. `upstream`, `add-on` (optional)
7. **Fix Version** — committed release (e.g. `ACM 2.15.0`); say "unplanned" if not yet committed
8. **Target Version** — PM intent release (e.g. `ACM 2.15.0`); can differ from Fix Version
9. **Linked issues** — any related Jira issues and the link type (Blocks, Relates to, is blocked by, etc.); do not pre-populate from conversation context
10. **Remote links** — any external URLs to attach (GDocs, specs, upstream GitHub issues, etc.)

## Workflow

### Step 1: Collect fields

Ask for all fields above in a single message. Do not proceed until Summary is provided at minimum. Other fields can be filled in later if the user wants to move fast.

### Step 2: Confirm before creating

Show a summary of all fields that will be set and ask the user to confirm before creating anything in Jira.

### Step 3: Create the Feature

Use the `jira_create_issue` MCP tool:
- project_key: `ACM`
- issue_type: `Feature`
- summary: from user
- description: from user
- assignee: `lbainbri@redhat.com`
- components: `Server Foundation`
- additional_fields: include `customfield_10464` (Activity Type), `customfield_10467` (Architect), `customfield_10469` (PM = reporter account ID), priority, labels

### Step 4: Set remaining fields

After creation, apply in parallel where possible:
- Fix Version and Target Version via `jira_update_issue` — only set if a version was provided; "unplanned" means leave the field unset entirely
- Contributors (`customfield_10466`) via `jira_update_issue` as an array of `{"accountId": "..."}` objects; look up account IDs by searching for an existing issue where each user is a contributor or reporter/assignee, since `jira_get_user_profile` does not return account IDs
- Issue links via `jira_create_issue_link` for each linked issue — use the **link type name** (e.g. `"Blocks"`), not the inward/outward label (e.g. not `"is blocked by"`)
- Remote links via `jira_create_remote_issue_link` for each URL

### Step 5: Confirm result

Show the created issue key and browse URL: `https://redhat.atlassian.net/browse/<KEY>`

List any fields that could not be set and instruct the user to set them manually.

## Custom field reference

| Field | Custom field ID | Notes |
|-------|----------------|-------|
| Activity Type | `customfield_10464` | value: `{"value": "Product / Portfolio Work"}` |
| PM | `customfield_10469` | user picker — `{"accountId": "..."}` |
| Architect | `customfield_10467` | user picker — `{"accountId": "..."}` |
| Contributors | `customfield_10466` | array of user pickers — `[{"accountId": "..."}, ...]` |

## Example invocations

```
/sfa-jira-feature-create
/sfa-jira-feature-create copy-from: ACM-35121
Create an SF Feature for enabling MWRS by default in ACM, blocked by upstream OCM work
New feature: Add Placement webhook validation, architect is Josh Packer, target ACM 2.16
```
