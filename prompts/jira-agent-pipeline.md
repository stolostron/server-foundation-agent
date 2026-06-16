# SF Jira agent pipeline

Query the groomed Server Foundation queue, pick **one** issue, implement the fix,
open a **draft** PR for human review, and mark Jira `agent-processed`.

Designed for **non-interactive** scheduled runs (`instruction_prompt` empty). Optional:
`instruction_prompt` may name a single issue key (`ACM-12345`) to fix that key instead
of the oldest queue item.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

**Jira:** MCP only (`search_issues`, `get_issue`, `add_comment`, `update_issue`,
`transition_issue` or `transitionJiraIssue`). Host `https://redhat.atlassian.net`,
project ACM. No Jira CLI or curl.

**Writable fixes:** `sfa-workspace-clone` worktrees under `workspace/` — never commit
inside `repos/`.

**Session repo required:** add `stolostron/server-foundation-agent` →
`/workspace/server-foundation-agent`. **Prompt Source alone does not clone the repo**
— scripts under `scripts/` and `build/scripts/` exist only when the repo is a session repo.

**GitHub App auth:** when `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, and `GH_APP_PRIVATE_KEY`
are in `swarmer-agent-extra-env`, generate an Installation Access Token (IAT) using
scripts in this repo under `build/scripts/`. Do **not** attach a session GitHub PAT —
Swarmer-injected `GH_TOKEN` overrides App scripts. Run **step 3** before any `gh` command.

**Verification:** in the target worktree, run `make check` then `make test` when those
targets exist (read the repo `Makefile` first). Shell timeout **≥ 900000 ms** for
`make check` — lint can be silent for minutes while downloading tools.

**Branch:** `fix-ACM-<digits>` (autonomous mode auto-prefixes to `sfa/fix-ACM-<digits>`).

**Commits:** Conventional Commits + `Signed-off-by` + Co-authored-by trailer:

```
Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>
```

**PR:** draft only (`gh pr create --draft`); add label `sfa-assisted`; footer:

```
---
*Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
```

**Agent queue JQL:**

```
project = ACM AND resolution = Unresolved AND status in (New, "To Do") AND component = "Server Foundation" AND labels = issue-for-agent AND labels != agent-processed ORDER BY created ASC
```

Grooming reference: `docs/jira-issue-grooming.md`

## Instructions

**This prompt is self-contained.** Execute the phases below directly — do not search
`docs/` for a solve workflow.

| Path | Exists? | Use |
|------|---------|-----|
| `prompts/jira-agent-pipeline.md` | Yes | This file — queue + solve (Phases 1–4) |
| `prompts/jira-solve.md` | Yes | On-demand single key — delegates Phase 2–3 here |
| `docs/jira-issue-grooming.md` | Yes | Grooming criteria only |
| `docs/jira-solve.md` | **No** | **Do not read — file does not exist** |
| `docs/jira/` | Yes | Jira API/JQL reference — not solve steps |

### Phase 1 — Queue

1. **Query queue** — MCP `search_issues`:
   - `jql`: agent queue JQL above (single line)
   - `max_results`: `20`

2. **Present queue table** (even when picking one issue):

   | Key | Summary | Status | Created |

   - Show total count and note ordering: oldest first (`ORDER BY created ASC`)
   - If **no results**: report "SF agent queue empty", remind grooming criteria
     (component **Server Foundation**, label `issue-for-agent`, status New/To Do,
     no `agent-processed`) and stop successfully — do not open PRs or modify Jira

3. **Pick issue** (`MAX_ISSUES = 1` per run):
   - If `instruction_prompt` contains `ACM-<digits>`, use that key
   - Else use the **oldest** issue from step 1 (first row in the table)
   - Record `issue_key` and summary in working notes

### Phase 2 — GitHub authentication

Run in **one shell** — subshells do not keep `GH_TOKEN`. **Never echo or log token
values** — scripts write to chmod-600 temp files and print only the file path.

Verify env (from `swarmer-agent-extra-env` via pod `envFrom` — do not log values):

```bash
for v in GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY; do
  if [ -z "${!v:-}" ]; then echo "MISSING_$v"; fi
done
```

**Tier A** — setup script from session repo (preferred):

```bash
AUTH_SCRIPT=""
for p in /workspace/server-foundation-agent/scripts/setup-github-app-auth.sh \
         /workspace/scripts/setup-github-app-auth.sh; do
  [ -f "$p" ] && AUTH_SCRIPT="$p" && break
done
[ -z "$AUTH_SCRIPT" ] && AUTH_SCRIPT="$(find /workspace -path '*/scripts/setup-github-app-auth.sh' 2>/dev/null | head -1)"
if [ -n "$AUTH_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$(bash "$AUTH_SCRIPT" --export)"
fi
```

**Tier B** — `build/scripts/github-token-manager.sh` from session repo:

```bash
if [ -z "${GH_TOKEN:-}" ]; then
  TM="$(find /workspace -path '*/build/scripts/github-token-manager.sh' 2>/dev/null | head -1)"
  if [ -n "$TM" ]; then
    # shellcheck source=/dev/null
    source "$(bash "$TM" --env-file)"
  fi
fi
```

**Tier C** — inline IAT when `GH_APP_*` env is set but scripts failed:

```bash
if [ -z "${GH_TOKEN:-}" ] && [ -n "${GH_APP_ID:-}" ] && [ -n "${GH_APP_INSTALLATION_ID:-}" ] \
   && [ -n "${GH_APP_PRIVATE_KEY:-}" ]; then
  KEY_FILE=$(mktemp); chmod 600 "$KEY_FILE"
  if [[ "$GH_APP_PRIVATE_KEY" != *$'\n'* ]]; then
    printf '%b' "$GH_APP_PRIVATE_KEY" > "$KEY_FILE"
  else
    printf '%s' "$GH_APP_PRIVATE_KEY" > "$KEY_FILE"
  fi
  NOW=$(date +%s)
  HDR=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
  PL=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW-60))" "$((NOW+540))" "$GH_APP_ID" \
    | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
  UNS="${HDR}.${PL}"
  SIG=$(printf '%s' "$UNS" | openssl dgst -sha256 -sign "$KEY_FILE" \
    | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
  GH_ENV=$(mktemp); chmod 600 "$GH_ENV"
  _token=$(curl -s -X POST \
    -H "Authorization: Bearer ${UNS}.${SIG}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens" \
    | jq -r '.token')
  printf 'export GH_TOKEN=%q\nexport GITHUB_TOKEN=%q\n' "$_token" "$_token" > "$GH_ENV"
  unset _token
  # shellcheck source=/dev/null
  source "$GH_ENV"
  rm -f "$KEY_FILE" "$GH_ENV"
fi
```

**Verify** (same shell as above):

GitHub App installation tokens **cannot** call `GET /user` (403 *Resource not accessible
by integration* is expected). When `GH_APP_ID` is set, verify repo access only; use
`gh api user` only for PAT fallback.

```bash
if [ -n "${GH_APP_ID:-}" ]; then
  if gh api repos/stolostron/server-foundation-agent -q .full_name 2>/dev/null; then
    echo "github-auth: app installation token"
  else
    echo "github-auth: FAILED (app token cannot access stolostron org)" >&2
    exit 1
  fi
elif gh api user -q .login 2>/dev/null; then
  echo "github-auth: user token (PAT)"
else
  echo "github-auth: FAILED" >&2
  exit 1
fi
```

- PAT fallback: use Swarmer-injected `GH_TOKEN` only when `GH_APP_*` are unset
- If auth fails: stop and report which tier was attempted; do not push or open PRs

### Phase 3 — Solve picked issue

4. **Fetch issue** — MCP `get_issue` with `issue_key`
   - Extract: summary, description, labels, status, components, fixVersions, versions
   - From description: Context, Acceptance criteria; repro steps if present
   - If groomed sections are thin, proceed with assumptions and document them in the PR

5. **Eligibility check**
   - Project ACM, unresolved, status New or To Do (or In Progress if already started)
   - Component includes **Server Foundation**
   - Has label `issue-for-agent`, not `agent-processed`
   - If not eligible, explain why and stop (do not open a PR)

6. **Prior PR check** (do not skip fix because of triage comments alone)

   Scan Jira comments (and description) for GitHub PR links
   (`https://github.com/.../pull/<N>`). For each link, check status:

   ```bash
   gh pr view <url> --json state,mergedAt,closed,url
   ```

   Fallback when `gh` fails but `GH_TOKEN` is set:

   ```bash
   curl -s -H "Authorization: Bearer ${GH_TOKEN}" \
     -H "Accept: application/vnd.github+json" \
     "https://api.github.com/repos/<owner>/<repo>/pulls/<N>" \
     | jq '{state, merged_at, draft: .draft}'
   ```

   | Prior PR state | Action |
   |----------------|--------|
   | **Open** (including draft) | Stop — fix already in flight; link the open PR in summary |
   | **Merged** | Stop — work landed; suggest resolving Jira / removing `issue-for-agent` |
   | **Closed** (not merged) | **Proceed** — re-implement and open a **new** draft PR |
   | No PR link found | Proceed normally |

   - Prior **Bug Triage Analysis** or agent comments without a blocking open/merged PR
     do **not** prevent a fix attempt
   - When re-fixing after a closed PR, mention the closed PR number in the new PR body
     and Jira comment
   - If `agent-processed` is present but the linked PR was closed without merge, remove
     `agent-processed` via MCP `update_issue` before continuing

7. **Start work in Jira** — transition status to **In Progress** (MCP only):
   - If status is already **In Progress**, skip
   - **jira-mcp-server:** `transition_issue` with `issue_key` and `transition`: `In Progress`
   - **Atlassian MCP:** `getTransitionsForJiraIssue` → find transition named
     `In Progress` → `transitionJiraIssue` with that transition id
   - If transition fails, `add_comment` with the error and stop (do not open a PR)

8. **Identify target repository**

   Priority order:

   1. **Groomed description** — repo named in Context or Acceptance criteria
   2. **Keywords** in summary/description:

      | Keyword | Likely repo |
      |---------|-------------|
      | MCA, ManagedClusterAddon, addon | multicloud-operators-foundation, addon-framework |
      | import, klusterlet, ManagedCluster import | managedcluster-import-controller |
      | proxy, konnectivity, tunnel | cluster-proxy, cluster-proxy-addon |
      | ServiceAccount, managed-sa | managed-serviceaccount |
      | permission, ClusterPermission, RBAC | cluster-permission |
      | foundation, clusterinfo, ManagedClusterInfo | multicloud-operators-foundation |
      | metrics, state-metrics | clusterlifecycle-state-metrics |
      | klusterlet-addon | klusterlet-addon-controller |
      | OCM, registration, work | ocm |

   3. Jira component / assignee → `team-members/team-members.md`, `docs/repos.md`

   Default org: **`stolostron`** for bug fixes unless the issue explicitly targets upstream
   OCM. If ambiguous, prefer stolostron and note the assumption in the PR.

   **Do not** run `./repos/sync-repos.sh` — clone only the target repo.

9. **Clone worktree**

   Determine base branch: `main` unless fixVersions/versions indicate a release branch
   (`release-*`, `backplane-*`). See `docs/build-release/branch-tables.md` when unsure.

   ```bash
   cd /workspace/server-foundation-agent
   WORKTREE=$(bash .claude/skills/sfa-workspace-clone/clone-worktree.sh \
     --new stolostron/<repo> fix-<KEY> --base <base-branch>)
   cd "$WORKTREE"
   ```

10. **Plan** — write `/workspace/server-foundation-agent/.work/jira/solve/spec-<KEY>.md`
    - Problem, target repo, approach, files to change, test plan
    - Implement immediately (no user prompt)

11. **Implement**
    - Search the worktree — `pkg/`, `cmd/`, `internal/`, tests
    - Follow existing patterns; add unit tests for new behavior
    - Run verification **sequentially** (never parallel):
      ```bash
      cd "$WORKTREE"
      make check    # skip only if Makefile has no check target — document in PR
      make test
      ```
    - Fix failures from your changes

12. **Commit**
    - Conventional commit + sign-off + Co-authored-by trailer (see conventions above)

13. **Push and draft PR**

    Re-run Phase 2 (GitHub auth) in the **same shell** if `GITHUB_TOKEN` is unset or push
    fails with 401. Use `--draft` — a human marks the PR ready for review after review.

    ```bash
    cd "$WORKTREE"
    git push -u origin HEAD
    PR_URL=$(GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}" gh pr create --draft --repo stolostron/<repo> --base <base-branch> \
      --title "ACM-<KEY>: <short summary>" \
      --body "$(cat <<'EOF'
    ## Jira
    https://redhat.atlassian.net/browse/ACM-<KEY>

    ## Summary
    <what changed and why>

    ## Test plan
    - [x] make check
    - [x] make test

    ---
    *Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
    EOF
    )")
    PR_NUM="${PR_URL##*/}"
    bash /workspace/server-foundation-agent/scripts/ensure-sfa-assisted-label.sh \
      "stolostron/<repo>" "$PR_NUM"
    ```

    **Label requirement:** `sfa-assisted` is **not** pre-created on most SF repos.
    Run `scripts/ensure-sfa-assisted-label.sh` after `gh pr create`. Label create/add
    is **non-fatal** — the script exits 0 even when the App lacks label permission; warn
    in the Jira comment if labeling failed. Do not fail the run or revert the PR.

14. **Jira follow-up** (MCP only)
    - `add_comment` — link the draft PR URL; end with:
      ```
      ----
      _— server-foundation-agent_
      ```
    - `update_issue` — add label `agent-processed`

### Phase 4 — Wrap-up

15. **Failure handling**
    - If implementation or tests fail after reasonable fixes: do **not** add `agent-processed`
    - `add_comment` on the issue with failure summary and any branch name (no PR if none created)
    - Report failure in final summary for operators

16. **Final summary**
    - Queue count and table from step 2
    - Issue key picked, target repo, outcome (PR URL or failure reason)
    - `make check` / `make test` status, auth mode (app or pat)

## Do not

- Read `docs/jira-solve.md` or search `docs/` for solve workflow steps (does not exist)
- Ask the user for confirmation (automated mode)
- Use Jira CLI or curl for Jira (GitHub API curl is OK when `GH_TOKEN` is set)
- Process more than one issue per run
- Commit inside `repos/` or run `./repos/sync-repos.sh`
- Skip `make test` when the target exists
- Mark PR ready for review (draft only — human promotes after review)
- Fix bugs spanning multiple repos in one PR — stop and comment on Jira if multi-repo work is required
- Attach a session GitHub PAT when `GH_APP_*` creds are configured
- Echo, print, or log `GH_TOKEN`, `GITHUB_TOKEN`, or `ghs_*` values
