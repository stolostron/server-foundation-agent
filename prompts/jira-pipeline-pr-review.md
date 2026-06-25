# SF jira-pipeline PR review feedback (agent-swarm)

Find open PRs created by **`jira-pipeline`** / **`jira-solve`** (`acm-agent[bot]`,
`sfa-assisted`, `ACM-*` title), address **code-fix** review comments from CodeRabbit
and human reviewers, squash to a single commit, and **force-push** the branch.

Designed for **non-interactive** scheduled runs (weekday cron, after pipeline slots).
Processes **exactly one PR** per run. Jira: [ACM-35748](https://redhat.atlassian.net/browse/ACM-35748).

**When this prompt is injected, execute Phases 1–6 immediately** — do not restate
the spec, ask which phase to run, or wait for confirmation. Detailed reference:
`workflows/jira-pipeline-pr-review.md`.

## Why this exists

After `jira-pipeline` opens a fix PR and a human marks it ready, CodeRabbit and
human reviewers leave inline and summary review comments. `agent-pr-action-needed`
only notifies about draft/approval gates — it does not address feedback. This
prompt closes that loop for **pipeline PRs only** (not human-authored PRs or other
bots).

**Scope:** implement feedback that requires **edits to code (or tests) in the PR
diff** only. Skip process, CI-grooming, and other non-code comments — leave those
for humans.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

**GitHub:** `gh` only. Collect SF open PRs via bundled `fetch-prs.sh` (`all` detail).
Filter with `workflows/jira-pipeline-pr-review/` scripts.

**Jira:** MCP only (`get_issue`, `add_comment`). Comment on the linked `ACM-*` key
from the PR title when present.

**Code access:** clone PR worktree via `sfa-workspace-clone` skill (PR mode).

**Verify:** `make check`, `make test` in the PR worktree before push.

Extended conventions: `prompts/_sfa-conventions.md`

## Pipeline PR filter

Include a PR only when **all** of:

| Signal | Requirement |
|--------|-------------|
| Author | `acm-agent` / `app/acm-agent` |
| Label | `sfa-assisted` |
| Title | Contains `ACM-<digits>` (pipeline PR title format) |
| State | Open, **not** draft |
| Feedback | Unresolved **code-fix** review threads, or `CHANGES_REQUESTED` with code-change requests |

Branch name is **not** a gate. Common shapes include `sfa/fix-ACM-<digits>`,
`sfa/fix-ACM-<digits>-v2` (retries), and `sfa/fix/ACM-<digits>` (legacy clone path).
The filter reports `branch_style` for debugging but does not exclude variants.

Exclude:

- Human-authored PRs (author is not `acm-agent`)
- Konflux / dependabot / other bot PRs
- Draft PRs (still in human groom queue)
- PRs missing `sfa-assisted` or `ACM-*` in the title
- PRs with no actionable **code-fix** reviewer feedback

## Code-fix scope

Classify every feedback item **before** editing. Implement only items that require
changes to source or test files in the PR branch.

**Act on** (code changes required):

| Category | Examples |
|----------|----------|
| Inline diff comments | Fix logic, error handling, naming, structure on a changed line |
| Requested tests | Add or update unit/integration tests for the fix |
| CodeRabbit actionable items | Suggested patches, ` ```suggestion ` blocks, concrete refactors |
| Security/quality on diff | Findings tied to a specific line or pattern in the changed files |

**Skip** (note in summary; do **not** implement or reply as if fixed):

| Category | Examples |
|----------|----------|
| Process / grooming | `/ok-to-test`, `/retest`, "mark ready", label/title/description edits, merge/rebase timing |
| CI-only | "tests failed", "please rerun CI" with no specific code fix |
| Questions / discussion | "Is this intentional?", design or product questions with no requested change |
| Acknowledgments | LGTM, looks good, thanks, +1, nit with no change requested |
| Out-of-scope work | New features, unrelated refactors, files outside the bug-fix purpose |
| Non-code process | Jira workflow, release notes, changelog, deployment steps (unless the PR already edits those files for the fix) |
| Informational bot output | CodeRabbit walkthrough/summary with no actionable code items |

If classification yields **zero** code-fix items: report "no code-fix review feedback",
stop successfully, and **do not** force-push.

## Workflow

```text
Collect → Filter pipeline PRs → Pick one → Address feedback → Squash + force-push → Jira comment → Summary
```

## Instructions

Run **all phases in order** every time this prompt is loaded.

### Phase 1: Collect open PRs

```bash
mkdir -p .output/jira-pipeline-pr-review

bash .claude/skills/sfa-github-fetch-prs/fetch-prs.sh all \
  2> .output/jira-pipeline-pr-review/fetch.log \
  > .output/jira-pipeline-pr-review/raw_prs.json

jq -e 'type == "array"' .output/jira-pipeline-pr-review/raw_prs.json >/dev/null
```

Pass `nocache` to `fetch-prs.sh` when `instruction_prompt` contains `nocache`.
**Never** use `2>&1` on this redirect.

### Phase 2: Filter pipeline PRs + pick candidate

```bash
jq -f workflows/jira-pipeline-pr-review/filter_pipeline_prs.jq \
  .output/jira-pipeline-pr-review/raw_prs.json \
  > .output/jira-pipeline-pr-review/pipeline_prs.json

python3 workflows/jira-pipeline-pr-review/collect_review_feedback.py \
  .output/jira-pipeline-pr-review/pipeline_prs.json \
  .output/jira-pipeline-pr-review/review_candidates.json
```

Read `.pick` from `review_candidates.json`. If `pick` is `null`, report
"no pipeline PRs need code-fix review feedback" and stop successfully.

Record: `repo`, `number`, `url`, `jira_key`, `branch`, `feedback_reason`.

### Phase 3: Clone PR worktree

```bash
WORKTREE=$(bash .claude/skills/sfa-workspace-clone/clone-worktree.sh \
  <org/repo> <pr-number>)
cd "$WORKTREE"
```

### Phase 4: Gather and address review feedback

1. **Collect feedback** (read-only first):
   ```bash
   gh pr view <number> --repo <org/repo> --json reviews,reviewDecision,comments
   gh api repos/<org/repo>/pulls/<number>/comments --paginate
   gh api graphql -f query='...'   # unresolved reviewThreads (see workflow doc)
   ```
2. **Classify** each item against [Code-fix scope](#code-fix-scope). Build two lists:
   `code_fix_items` and `skipped_non_code_items`.
3. **Prioritize** `code_fix_items` only:
   - Unresolved inline threads on changed lines with a requested code/test change
   - `CHANGES_REQUESTED` summaries that name concrete code issues
   - CodeRabbit actionable suggestions (not walkthrough-only summaries)
4. **Skip** always (never implement):
   - Bot automation noise: `github-actions`, `openshift-ci-robot`, prow commands,
     author's own comments
   - All items in the **Skip** table under Code-fix scope
5. If `code_fix_items` is empty: stop Phase 4 here — no push (see Code-fix scope).
6. **Implement** minimal fixes for `code_fix_items` only; do not expand scope beyond
   those items
7. **Reply** on the PR when helpful — list addressed code fixes and explicitly note
   skipped non-code items (no reply needed when nothing was implemented):
   ```bash
   gh pr comment <number> --repo <org/repo> --body "Addressed code review: ..."
   ```
8. Run verification **sequentially** in the worktree:
   ```bash
   make check    # allow ≥ 5 min
   make test
   ```
   Fix failures caused by your changes. Do not skip when targets exist.

### Phase 5: Squash commits and force-push

Run Phase 5 **only when Phase 4 implemented at least one code fix**. If every item
was skipped as non-code, do not squash, commit, or push.

Squash **all** commits on the PR branch into **one** commit, then force-push.
Use the PR's merge base (target branch) as the squash parent.

```bash
# Discover PR base branch
BASE=$(gh pr view <number> --repo <org/repo> --json baseRefName -q .baseRefName)
git fetch origin "$BASE"
MERGE_BASE=$(git merge-base HEAD "origin/$BASE")

git reset --soft "$MERGE_BASE"
git commit -s -m "$(cat <<'EOF'
fix: address review feedback for ACM-<KEY>

<one-line summary of review fixes>

Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>
EOF
)"
git push --force-with-lease origin HEAD
```

Use `ACM-<KEY>` from the PR title when present. Preserve `Signed-off-by` via `-s`.
**Force push is required** — the PR branch is owned by `acm-agent` and may have
multiple commits from prior agent runs.

Do **not** change PR title, draft state, labels, or merge the PR.

### Phase 6: Jira follow-up (when `jira_key` present and code fixes were pushed)

MCP `add_comment` on the linked issue:

```text
h3. Review feedback addressed

*PR:* <pr-url>
*Changes:* <brief summary>
*Verification:* make check ✓, make test ✓

----
_— server-foundation-agent_
```

### Final summary

Report:

- PR repo, number, URL, Jira key
- Code-fix items addressed (count + brief list)
- Non-code items skipped (count + brief list)
- Squash commit message (or "no push — no code-fix feedback")
- Force-push status
- `make check` / `make test` status
- Jira comment posted (yes/no)
- Collect/classify errors from `review_candidates.json.errors`

## Limits

- Process **exactly one** PR per run (`MAX_PRS = 1`)
- Do not start a second PR even if time remains
- Do not merge, approve, close, or mark PRs ready for review

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `nocache` | Pass `nocache` to `fetch-prs.sh` |
| `pr <org/repo>#<number>` | Skip Phase 2 pick; process that PR directly (must match pipeline PR filter) |
| `repo <org/repo>` | Restrict Phase 2 candidates to one repo |

## Failure handling

- If verification fails after reasonable fixes: do **not** force-push; comment on
  the PR with failure summary; report in final summary
- If force-push fails: report error; do not retry more than once
- If no `jira_key` in title: skip Jira comment; continue otherwise

## Do not

- Ask the user for confirmation (automated mode)
- Implement non-code review feedback (process, CI groom, questions, scope creep)
- Force-push when no code-fix items were implemented
- Process human-authored or non-pipeline PRs
- Redirect stderr into JSON artifacts (`2>&1` on Phase 1–2)
- Approve, merge, close, or mark PRs ready
- Use Jira CLI or curl
- Push without squashing to a single commit first
