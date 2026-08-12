# SF fix CVE (agent-swarm)

Monitor Server Foundation ProsSec vulnerability issues, **classify each CVE as Go
toolchain/stdlib vs module**, generate the CVE **summary/inventory** (repos + issue
table — keep), post findings to Jira **Vulnerability** issues (do **not** create
per-CVE tracking Tasks), open **draft PRs** for module CVEs, trigger **Konflux
rebuilds** for toolchain CVEs, and **close** vulnerability issues classified as Not
Applicable (or after verified rebuild / merged PR).

**Developer guide:** [Automated CVE fix — developer guide](../docs/automated-cve-fix-developer-guide.md)
— human gates, Jira issue types, PR grooming, auto-close rules, and troubleshooting.

Designed for **non-interactive** scheduled or on-demand runs (cron or
`instruction_prompt: CVE-YYYY-NNNNN`). Skill reference:
`.claude/skills/sfa-cve-analysis/SKILL.md` (classify first),
`.claude/skills/sfa-cve-toolchain/SKILL.md` (rebuild),
`.claude/skills/sfa-cve-toolchain-verify/SKILL.md` (verify + close).
PR patterns: `prompts/jira-solve.md`.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (this repo) |

**Jira:** MCP tools only (`search_issues`, `get_issue`, `create_issue`, `add_comment`,
`update_issue`, `transition_issue`). Host `https://redhat.atlassian.net`, project ACM.
Do **not** use Jira CLI. Do **not** use curl for vulnerability issue comments — MCP is
required (REST often returns 404 on ProsSec issues).

**Code access:**

| Location | Use |
|----------|-----|
| `repos/` | Read-only reference (`./repos/sync-repos.sh`) |
| `workspace/` | Writable worktrees for CVE fixes (`sfa-workspace-clone` skill) |

**GitHub:** `gh` for draft PRs. Commits: Conventional Commits + `Signed-off-by` +
`Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>`. Label `sfa-assisted`
after PR create when the label exists (see `prompts/_sfa-conventions.md`).

**Slack:** prefer Slack MCP (`send_payload`); fallback `SLACK_WEBHOOK_URL` +
`workflows/fix-cve/generate_slack_payload.py` +
`.claude/skills/sfa-slack-notify/send_to_slack.sh` (Phase 7 — required when Slack configured).

**Output dir:** `.output/cve-analysis/` (under working directory)

Extended conventions: `prompts/_sfa-conventions.md`

## Scope

**Default:** all active ProsSec vulnerability issues for Server Foundation.

**Active vulnerability JQL:**

```
project = ACM AND issuetype = Vulnerability AND component = "Server Foundation" AND labels = Security AND status NOT IN (Closed, Done)
```

**Optional `instruction_prompt` CVE filter:** if the text contains `CVE-YYYY-NNNNN`,
analyze that CVE only (include Closed/Done vulnerability issues for that CVE).

**Exclude:** bulk container-scan tickets without a single CVE in the summary (e.g.
`[Server Foundation] … - N HIGH CVEs`) unless `INCLUDE_BULK_SCANS` is set.

## CVE summary / inventory (required; no Jira Task)

Always run `format-cve-tracking-task.py` to build the CVE summary (repos, issue
table, counts). Save under `.output/cve-analysis/` and include it in Vulnerability
comments (Phase 5).

**Stop only:** creating a Jira Task from that output
(`CVE-{cve_id} ({issue_count} issues, {repo_count} repos)`).

**Keep:** summary generation, deep analysis, per-issue comments, remediation, Slack.

## Dedup between runs

Skip **re-analysis and re-commenting** (Phases 3–5) for a CVE when **all** are true:

1. Every active vulnerability issue for that CVE has a comment containing **both**
   `Deep CVE Impact Analysis` and `_— server-foundation-agent_`

If new vulnerability issues appeared since last run, re-run analysis for that CVE and
post comments only on issues missing the signature (do not duplicate on already-commented
issues).

**Dedup does NOT skip Phase 6 remediation.** CVEs that already have analysis still need
draft PRs, Not Applicable closes, and merged-PR closes when open vulnerability issues
remain. Put analysis-skipped CVE IDs in `.output/cve-analysis/cve_remediate.json` (see
Phase 2) and still run Phase 6 for them.

Override: `FORCE_REANALYSIS` in `instruction_prompt` ignores dedup (re-runs Phases 3–5).

## Branch mapping (Jira → git)

Derive target branch from vulnerability issue summary bracket or `target_version`:

| Jira bracket / version | Git branch |
|------------------------|------------|
| `[mce-2.8]` / MCE 2.8.x | `backplane-2.8` |
| `[mce-2.9]` | `backplane-2.9` |
| `[mce-2.10]` | `backplane-2.10` |
| `[mce-2.11]` | `backplane-2.11` |
| `[mce-2.17]` | `backplane-2.17` |
| `[acm-2.13]` / ACM 2.13.x | `release-2.13` |
| `[acm-2.14]` | `release-2.14` |
| (no bracket, mainline) | `main` |

Repos using `release-*` instead of `backplane-*`: `klusterlet-addon-controller`,
`cluster-permission`.

## Workflow

```
Collect → Group by CVE → Classify (toolchain vs module) → CVE summary (no Task)
  → Deep analysis → Jira comments (Vulnerability only) → Remediation → Slack → Summary
```

**Critical:** classify remediation path **before** deep module analysis or draft PRs.
Do not open `go.mod` bump PRs for toolchain/stdlib CVEs.
**Stop only** creating per-CVE tracking Tasks; **keep** the CVE summary content,
analysis, Vulnerability comments, remediation, and Slack.

## Phase 1: Collect vulnerability issues

1. `mkdir -p .output/cve-analysis`

2. MCP `search_issues` with active vulnerability JQL (`max_results`: `100`). If
   `instruction_prompt` names a CVE, use:

   ```
   project = ACM AND issuetype = Vulnerability AND component = "Server Foundation" AND labels = Security AND summary ~ "CVE-YYYY-NNNNN"
   ```

3. Write `.output/cve-analysis/vulnerabilities.json` — array of `{key, summary, labels,
   status, priority, created, target_version, url}`.

4. **Early exit:** if zero issues, write `.output/cve-analysis/remediation.json` as
   `[]`, then run Phase 7 Slack ("no active SF CVE issues") when `SLACK_WEBHOOK_URL` is
   set, then stop successfully.

## Phase 2: Group by CVE

1. Extract CVE IDs from each issue summary (`CVE-\d{4}-\d+`) or `CVE-*` labels.

2. Build `.output/cve-analysis/cve_groups.json`:

   ```json
   {
     "CVE-2026-39821": ["ACM-35352", "ACM-35353"],
     "CVE-2026-46595": ["ACM-35339"]
   }
   ```

3. Apply dedup (unless `FORCE_REANALYSIS`). Write **two** lists:

   | File | Contents |
   |------|----------|
   | `.output/cve-analysis/cve_to_process.json` | CVE IDs needing Phases 3–5 this run (new or incomplete analysis) |
   | `.output/cve-analysis/cve_remediate.json` | **All** CVE IDs from `cve_groups.json` that still have active (not Closed/Done) vulnerability issues — including analysis-dedup'd CVEs |

   Example: six CVEs already analyzed go only into `cve_remediate.json`; one new CVE
   goes into both. Never omit a CVE from `cve_remediate.json` solely because analysis
   was skipped.

## Phase 2.5: Classify remediation path (REQUIRED)

For **every** CVE in `cve_to_process.json`, classify **before** Phase 4 module deep
analysis or Phase 6 draft PRs.

Write `.output/cve-analysis/classification-{cve_id}.json`:

```json
{
  "cve_id": "CVE-2026-42504",
  "path": "toolchain",
  "min_go": "1.25.4",
  "module": null,
  "rationale": "stdlib mime; fix is Go >=1.25.4; no go.mod bump"
}
```

or

```json
{
  "cve_id": "CVE-2026-39821",
  "path": "module",
  "min_go": null,
  "module": "golang.org/x/net",
  "fix_version": "v0.56.0",
  "rationale": "advisory fixes only via x/net bump; not a stdlib Go floor"
}
```

### Classification rules (deterministic — evaluate in order)

Stop at the **first** matching rule. Serialize the result in
`classification-{cve_id}.json` (`path`, `min_go`, `module`, `fix_version`, `rationale`).

| # | Evidence | `path` | Notes |
|---|----------|--------|-------|
| 1 | Advisory/GO vuln fixes **only** via a **Go version floor** (stdlib package; no required module bump) | `toolchain` | Record `min_go` |
| 2 | Advisory fixes **only** via `go get <module>@v…` (no Go floor) | `module` | Record `module` + `fix_version` |
| 3a | Dual-fixed (Go ≥ X **or** module ≥ Y) **and** vulnerable module package path is **not** imported | `toolchain` | Confirm with `go mod why` / grep; indirect dep alone ≠ import |
| 3b | Dual-fixed **and** vulnerable module package path **is** imported/used | `module` | Unless docs prove stdlib alone remediates this binary |
| 4 | Incomplete/conflicting signals **but** a Go floor exists | `toolchain` | Record uncertainty in `rationale`; **do not** open a module PR |
| 5 | Else | `module` | Proceed with deep analysis |

Do **not** use “majority of signals” heuristics — follow the table above.

### Routing after classification

| `path` | Phases 3–5 | Phase 6 |
|--------|------------|---------|
| `toolchain` | CVE summary + short analysis comment on each Vulnerability (toolchain, `min_go`, no `go get`) | §6.0 Konflux rebuild (`sfa-cve-toolchain`); skip §6.4 draft PRs |
| `module` | CVE summary + full deep analysis as today | §6.2–§6.5 (Not Applicable / already fixed / draft PR / close on merge) |

## Phase 3: CVE summary (no tracking Task)

For each CVE in `cve_to_process.json`:

### 3.1 Generate summary (required)

Fetch vulnerability issues for the CVE via MCP, save REST-shaped JSON for the script:

```bash
# Build issues payload from MCP results into .output/cve-analysis/issues-{cve_id}.json
# Must be {"issues": [{"key", "fields": {summary, labels, versions, status, priority, created}}]}

python3 .claude/skills/sfa-cve-analysis/format-cve-tracking-task.py \
  .output/cve-analysis/issues-{cve_id}.json \
  {cve_id} \
  > .output/cve-analysis/summary-{cve_id}.txt
```

Parse counts from the summary header (`Total Related Issues`, repo count from
`**Repository:` lines). Keep this file for Phase 5 comments and session output.

### 3.2 Do not create a tracking Task

**Forbidden:** MCP `create_issue` for a Task with summary
`CVE-{cve_id} ({issue_count} issues, {repo_count} repos)` (or any other per-CVE
tracking ticket). Existing Tasks of that form may remain; do not create new ones.

**Keep** posting the summary content as comments on Vulnerability issues (Phase 5).
## Phase 4: Deep impact analysis

Run for **every** CVE in `cve_to_process.json` (non-interactive — do not ask the user).

**Gate:** read `.output/cve-analysis/classification-{cve_id}.json`. If `path` is
`toolchain`, skip the module-oriented branch clone / `go mod why` table below.
Instead write a short report documenting: classification, `min_go`, rebuild-sufficient
vs tag-bump, and “no go.mod changes”. Then continue to Phase 5 with that report.

### 4.1 CVE metadata

WebSearch / pkg.go.dev vuln DB for each CVE:

- Affected package and version range (stdlib vs module)
- Fixed version **and/or** minimum Go version
- Brief description
- Dual-fixed? (Go floor **or** module bump)

Save to `.output/cve-analysis/cve-meta-{cve_id}.json`. If metadata shows a Go floor and
no primary module path, update classification to `toolchain` before continuing.

### 4.2 Clone and analyze branches

**Clone under the sandbox only** — use `.output/cve-analysis/repos/` (create with
`mkdir -p`). OpenCode rejects `external_directory (/tmp/*)`; never `cd /tmp` or
`git clone` into `/tmp`.

For writable CVE *fix* worktrees (draft PRs), use `sfa-workspace-clone` → `workspace/`
instead of this analysis clone tree.

**Repositories** — derive from vulnerability issues for this CVE (via script output
or pscomponent labels). Common SF repos:

| Repository | Branches |
|------------|----------|
| stolostron/ocm | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/clusterlifecycle-state-metrics | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/multicloud-operators-foundation | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/managed-serviceaccount | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/cluster-proxy-addon | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/cluster-proxy | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/managedcluster-import-controller | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/klusterlet-addon-controller | main, release-2.17, release-2.16, release-2.15, release-2.14, release-2.13 |
| stolostron/cluster-permission | main, release-2.17, release-2.16, release-2.15, release-2.14, release-2.13 |

Per repo/branch:

1. `git fetch origin {branch} --depth 1` and checkout
2. Read `go.mod` for `golang.org/x/net`, `golang.org/x/crypto`, Go version
3. `go mod why` for affected package (e.g. `golang.org/x/net/idna`, `golang.org/x/crypto/ssh`)
4. Grep for direct usage (`idna`, `ssh.NewServerConn`, `ssh.ServerConfig`)
5. Classify impact:
   - ❌ Vulnerable / ⚠️ Potentially Vulnerable / ✅ Not Vulnerable / ➖ Not Applicable

**Older-branch upgrades:** follow `solutions/older-branch-dep-upgrade.md` for fix
recommendations (minimal `go get`, avoid OCM dep tier jumps).

Write report: `.output/cve-analysis/deep-analysis-{cve_id}.md`

## Phase 5: Post Jira comments

Use **Jira wiki markup** (see `docs/jira/formatting.md`). Footer on every comment:

```
----
_— server-foundation-agent_
```

Convert markdown reports with `h2.` / `h3.` headings, `*bold*`, `{{monospace}}`,
`||table||` rows.

### 5.1 Individual vulnerability issues

For each issue key in the CVE group, MCP `add_comment` with:

1. **CVE summary** — wiki-markup version of `summary-{cve_id}.txt` (repos, related
   keys, issue table) so the inventory stays visible without a tracking Task
2. **Deep analysis** — full report or a component-specific section that still includes
   the `Deep CVE Impact Analysis` heading for dedup:
   - Issue key, repository, branch (from JIRA target version / summary bracket)
   - Installed dependency version vs fix version **or** required Go floor (`min_go`)
   - Impact assessment (one line) **and** remediation path (`toolchain` | `module`)
   - Remediation command: for module → `go get …`; for toolchain → rebuild with
     `openshift-golang-builder` / `TRIGGER_BUILD` (no `go get`)
   - Sibling Vulnerability keys for the same CVE

Skip issues that already have the dedup signature (unless `FORCE_REANALYSIS`).

Do **not** `create_issue` a per-CVE tracking Task. Do **keep** the summary in comments.
## Phase 6: Remediation actions

Run after Phase 5 (or after Phase 2 when every CVE was analysis-dedup'd) unless
`SKIP_REMEDIATION` is set. Non-interactive — do not ask the user.

**Scope:** remediate **every** CVE in `cve_remediate.json`, not only `cve_to_process.json`.
Do **not** list draft PRs as “human follow-up” when §6.4 can open them this run.
Dedup of analysis is not a reason to skip opening PRs or closing Not Applicable /
merged-PR issues.

**Impact source when this run skipped deep analysis:** for each CVE in
`cve_remediate.json` that has no `deep-analysis-{cve_id}.md` from this run, recover
per-issue ❌ / ⚠️ / ✅ / ➖ classification from an existing vulnerability-issue
comment that contains `Deep CVE Impact Analysis` (and the remediation command /
package fix version). Do not invent a new classification.

**Start each run with an empty** `.output/cve-analysis/remediation.json` (`[]`). Append
rows as actions occur this run — do not carry forward rows from prior runs.

**Exception — durable rebuild state:** keep
`.output/cve-analysis/toolchain_rebuilds.json` across runs (do **not** wipe it). Used by
§6.0 to avoid duplicate `TRIGGER_BUILD` pushes for the same `(cve_id, repo, branch)`.

Write `.output/cve-analysis/remediation.json` — array of action records:

```json
{
  "cve_id": "CVE-2026-46595",
  "issue_key": "ACM-35339",
  "repo": "stolostron/ocm",
  "branch": "backplane-2.8",
  "impact": "Not Applicable",
  "action": "closed",
  "pr_url": null,
  "pr_state": null,
  "is_draft": null,
  "merged_at": null,
  "notes": "go mod why shows ssh package not needed",
  "closed_this_run": true
}
```

**Toolchain action schemas** (required fields):

`toolchain_rebuild` / `skipped_existing_rebuild` (one row per `(repo, branch)` group):

```json
{
  "cve_id": "CVE-2026-39825",
  "action": "toolchain_rebuild",
  "repo": "stolostron/ocm",
  "branch": "backplane-2.11",
  "commit": "6031040741660bca3ae07df68240cae9c26af5c6",
  "commit_url": "https://github.com/stolostron/ocm/commit/6031040741660bca3ae07df68240cae9c26af5c6",
  "images": ["multicluster-engine/work-rhel9", "multicluster-engine/placement-rhel9"],
  "issue_keys": ["ACM-37577", "ACM-37587"],
  "triggered_at": "2026-08-10T16:47:16Z",
  "notes": "TRIGGER_BUILD push",
  "closed_this_run": false
}
```

`toolchain_verify_close` (one row per closed Vulnerability):

```json
{
  "cve_id": "CVE-2026-39825",
  "issue_key": "ACM-37577",
  "action": "toolchain_verify_close",
  "repo": "stolostron/ocm",
  "branch": "backplane-2.11",
  "image": "quay.io/redhat-user-workloads/crt-redhat-acm-tenant/work-mce-211:6031040…",
  "go_ver": "1.25.11",
  "fix_version": "MCE 2.11.5",
  "commit": "6031040741660bca3ae07df68240cae9c26af5c6",
  "commit_url": "https://github.com/stolostron/ocm/commit/6031040741660bca3ae07df68240cae9c26af5c6",
  "notes": "go version -m meets min_go 1.25.10",
  "closed_this_run": true
}
```

Set `"closed_this_run": true` **only** on `closed`, `closed_merged_pr`, and
`toolchain_verify_close` rows when this run successfully transitions the issue to Closed.
Omit or set `false` for all other actions. Slack *Closed this run* sections include
**only** rows with `closed_this_run: true`.

`action` values: `toolchain_rebuild`, `skipped_existing_rebuild`, `toolchain_verify_close`,
`pr_opened`, `pr_merged`, `pr_closed`, `closed`, `closed_merged_pr`,
`skipped_already_fixed`, `skipped_existing_pr`, `failed`.

When a row has `pr_url`, also record live GitHub fields from `gh pr view` (see PR
state helpers below): `pr_state` (`OPEN` / `MERGED` / `CLOSED`), `is_draft`, `merged_at`.
Phase 7 re-fetches these fields before Slack; stale merged PRs must not appear as drafts.

### 6.0 Toolchain CVEs → Konflux rebuild (not draft PRs)

When `classification-{cve_id}.json` has `"path": "toolchain"`:

1. **Do not** open `go.mod` / vendor bump PRs (close any mistaken open draft for this
   CVE with a comment pointing at toolchain remediation).
2. Map images → `(repo, branch)` rebuild groups via `map-image-to-dockerfile.py`.
3. **Idempotency (required before every push):**
   - Load `.output/cve-analysis/toolchain_rebuilds.json` (create `{ "rebuilds": [] }` if
     missing).
   - For each `(cve_id, repo, branch)` group: if an entry already exists **and**
     `FORCE_REBUILD` is not set → **do not** run `trigger-konflux-rebuild.sh`. Record
     `action: skipped_existing_rebuild` with the stored `commit` / `commit_url`, and reuse
     that commit for Jira comments / verify.
   - Secondary check: if any open sibling Jira already has an `sfa-cve-toolchain`
     rebuild comment with a `TRIGGER_BUILD` commit URL for this repo/branch, treat as
     existing (same skip path) and upsert `toolchain_rebuilds.json`.
4. For groups with no prior rebuild (or `FORCE_REBUILD`): follow
   [sfa-cve-toolchain](../.claude/skills/sfa-cve-toolchain/SKILL.md) — push
   `TRIGGER_BUILD` **once per group**, comment on each Vulnerability, transition
   **In Progress**. Record `action: toolchain_rebuild` and **append/update**
   `toolchain_rebuilds.json` with `{cve_id, repo, branch, commit, commit_url,
   triggered_at, issue_keys, images}`.
5. When rebuilds are ready (same run if images exist, or a later run): follow
   [sfa-cve-toolchain-verify](../.claude/skills/sfa-cve-toolchain-verify/SKILL.md) —
   `go version -m`, set Fix Version, Close. Record `action: toolchain_verify_close` with
   `closed_this_run: true` (include `image`, `go_ver`, `fix_version`, `commit_url`).
6. Skip §6.4 for this CVE. §6.2 / §6.3 still apply if a sibling is Not Applicable /
   already fixed.

### 6.1 Build remediation plan

For each CVE in `cve_remediate.json`, map each **active** vulnerability issue to:

- Remediation path (`toolchain` → §6.0; `module` → §6.2–§6.5)
- Repository (pscomponent label or summary image path → repo name)
- Target branch (branch mapping table above)
- Per-issue impact from `deep-analysis-{cve_id}.md` **or** prior analysis comment
  (when analysis was dedup'd this run)

**Group fixes:** toolchain → one `TRIGGER_BUILD` per `(repo, branch)`; module → one
draft PR per `(repo, branch, CVE)`. Link all related vulnerability issue keys in
comments.

Then execute §6.2–§6.5 for those groups. Prefer opening draft PRs (§6.4) over writing
“Draft PRs needed” in the summary.

### 6.2 Not Applicable → close Jira

When deep analysis classifies the issue's repo/branch as **➖ Not Applicable**:

1. MCP `add_comment` on the vulnerability issue (skip if comment already contains
   `CVE Remediation: Not Applicable` and `_— server-foundation-agent_` unless
   `FORCE_REANALYSIS`):
   - Evidence: `go mod why` output, grep results, why the vulnerable API is unused
   - Statement: issue closed as not applicable to this component/branch
2. MCP `transition_issue`:
   - If status is New/To Do → try `In Progress` first when available
   - Then transition to **Closed** (or **Resolve** then **Close** if the workflow
     requires two steps)
   - If transition fails, record `action: failed` with error; do **not** retry blindly
3. **First** record each closed issue in `remediation.json` with `action: closed`,
   `closed_this_run: true`, and a `notes` rationale; mirror in `run_meta.json` →
   `jira_closed_this_run`. **Then** transition.

**Guardrail:** close **only** when classification is Not Applicable with documented
evidence in the comment. Never close ❌ Vulnerable or ⚠️ Potentially Vulnerable issues.

### 6.3 Already fixed → skip PR

When classification is **✅ Not Vulnerable** (installed version ≥ fix version):

- Ensure Phase 5 comment documents the evidence
- Record `action: skipped_already_fixed` in `remediation.json`
- Do **not** close automatically (human/QE may still want scan ticket cleanup)

### 6.4 Vulnerable / Potentially Vulnerable → draft PR (module path only)

**Skip this section when classification is `toolchain`** (use §6.0).

When classification is **`module`** and impact is **❌ Vulnerable** or
**⚠️ Potentially Vulnerable**:

**PR state helpers (required whenever recording `pr_url`):**

```bash
# Dedup — open PRs only (never trust Jira git_pull_requests without verifying)
gh pr list --repo <org/repo> --state open --search "<CVE-ID> in:title" \
  --json number,url,state,isDraft,mergedAt,title

# Verify a specific PR before recording skipped_existing_pr / pr_opened
gh pr view <number> --repo <org/repo> --json state,isDraft,mergedAt,url,title
```

- If `state` is `MERGED` → record `action: pr_merged` (not `skipped_existing_pr`);
  include `merged_at`; do **not** list as needing draft/approval follow-up
- If `state` is `CLOSED` (unmerged) → record `action: pr_closed`; open a new PR if still
  vulnerable
- If `state` is `OPEN` and `isDraft` is `true` → `skipped_existing_pr` or `pr_opened`
- If `state` is `OPEN` and `isDraft` is `false` → same actions; Slack reports as
  *ready for review*, not draft

1. **Dedup PR:** use `gh pr list --state open` on the repo with title containing
   `{cve_id}`; verify with `gh pr view --json state,isDraft,mergedAt`. Do **not** treat
   Jira `git_pull_requests` as authoritative — always verify with `gh`. If an open PR is
   found → record `skipped_existing_pr` with PR state fields, link PR in a comment on
   each linked Vulnerability issue, ensure each linked issue is **In Progress** (see step 2), then skip new PR
2. **Start work in Jira** — for each linked vulnerability issue (MCP `transition_issue`):
   - If status is already **In Progress** → skip
   - If status is New/To Do/Backlog → transition to **In Progress** (transition name
     may be `Start Progress`)
   - If status is **Review** or later → do **not** change status (human owns workflow
     beyond In Progress); still post PR comment in step 8
   - If transition fails: MCP `add_comment` with the error, record `action: failed`,
     skip PR for this `(repo, branch, CVE)` group
3. **Clone worktree:**
   ```bash
   bash .claude/skills/sfa-workspace-clone/clone-worktree.sh \
     --new <org/repo> cve-<CVE-ID>-<branch-suffix> --base <branch>
   ```
   Example: `--base backplane-2.8` → branch `cve-CVE-2026-39821-backplane-2-8`
4. **Apply minimal fix** per `solutions/older-branch-dep-upgrade.md`:
   - Prefer `go get <module>@<fix-version>` (and `go mod tidy`)
   - **Vendor policy (hard rule):** run `go mod vendor` **only if** `vendor/`
     already exists on the base branch (`test -d vendor`). If there is no
     `vendor/` directory, **do not** create one — leave the PR as
     `go.mod`/`go.sum` only (Mintmaker-style). Introducing `vendor/` into a
     non-vendored repo breaks hermetic Konflux builds when
     `Dockerfile.rhtap` does `rm -fr vendor && go mod vendor` (cachi2 skips
     gomod prefetch when `vendor/` is present; see ACM-37377 /
     cluster-permission#284).
   - Avoid OCM dependency tier jumps; use `replace` only when the SOP requires it
5. **Verify** in the worktree (sequential, allow ≥ 5 min):
   ```bash
   make check
   make test
   ```
   Fix failures from your changes; record failure if tests cannot pass after reasonable
   effort
6. **Commit and push:**
   ```bash
   git commit -s -m "$(cat <<'EOF'
   fix(security): bump <module> for <CVE-ID>

   Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>
   EOF
   )"
   git push origin HEAD
   ```
7. **Draft PR:**
   ```bash
   gh pr create --draft --repo <org/repo> \
     --title "<CVE-ID>: bump <module> on <branch>" \
     --body "$(cat <<'EOF'
   ## CVE
   <CVE-ID> — <one-line description>

   ## Jira
   - https://redhat.atlassian.net/browse/ACM-XXXXX
   (list all linked vulnerability keys)

   ## Summary
   <go get command and version change>

   ## Test plan
   - [x] make check
   - [x] make test

   ---
   *Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
   EOF
   )"
   gh pr edit <PR-NUMBER> --repo <org/repo> --add-label "sfa-assisted"
   gh pr view <PR-NUMBER> --repo <org/repo> --json state,isDraft,mergedAt,url,title
   ```
   If the label does not exist on the target repo, note in the run summary; the draft PR
   is still valid.
8. **Jira updates** for each linked vulnerability issue:
   - MCP `add_comment` with PR URL, fix summary, and signature footer
   - MCP `update_issue` — set `git_pull_requests` to the PR URL when the field is
     supported (best effort); re-verify with `gh pr view` on later runs — merged PRs in
     Jira must not block new fixes
   - Leave status at **In Progress** after opening a draft PR — do **not** transition to
     Review (humans move to Review after marking the PR ready for review)
9. Record `action: pr_opened` with `pr_url`, `pr_state`, `is_draft`, and `merged_at` in
    `remediation.json`

**Limit:** at most **one new PR per repo/branch/CVE** per run. Defer extra branches to
the run summary as human follow-ups.

### 6.5 Close vulnerability issues when fix PR is merged

Run after §6.4. Query **In Progress** vulnerability issues only (tickets with an active
fix in flight). Non-interactive — do not ask the user.

**JQL (MCP `search_issues`):**

```jql
project = ACM AND issuetype = Vulnerability AND component = "Server Foundation" AND labels = Security AND status = "In Progress"
```

If `instruction_prompt` names a CVE, append `AND summary ~ "CVE-YYYY-NNNNN"`.

For each **In Progress** issue:

1. **Skip unless still In Progress** — if MCP `get_issue` status is **Closed** or **Done**,
   do not close or record a closure row.

2. **Skip if already closed this run previously** — agent-signed comment contains
   `CVE Remediation: PR merged` and `_— server-foundation-agent_` unless
   `FORCE_REANALYSIS`.

   > **Note:** A `Fix Merged:` comment alone is **not** a skip — that comment may have
   > been posted when the PR merged without a successful Jira transition (or the issue
   > was reopened). If status is still **In Progress** and `gh` confirms `MERGED`,
   > proceed to close and record `closed_this_run: true`.

3. **Discover linked fix PR(s)** (try in order; verify every URL with `gh`):
   - MCP `get_issue` — development / `git_pull_requests` URLs
   - MCP issue comments — `https://github.com/.../pull/N` from agent-signed comments
   - If no URL: map issue → repo + branch (§Branch mapping), extract CVE from summary;
     ```bash
     gh pr list --repo <org/repo> --state merged \
       --search "<CVE-ID> in:title" \
       --json number,url,state,mergedAt,baseRefName
     ```
     Pick the PR whose `baseRefName` matches the issue target branch

4. **Verify merge** — `gh pr view <url> --json state,mergedAt,url` — proceed **only**
   when `state` is `MERGED`

5. **Record then close (order mandatory):**
   - **First** append to `remediation.json` with `closed_this_run: true` (and mirror in
     `run_meta.json` → `jira_closed_this_run` — see §6.6). Slack *Closed this run*
     reports **only** rows with `closed_this_run: true` from this run.
   - MCP `add_comment` (wiki markup):
     - `CVE Remediation: PR merged`
     - Merged PR URL and `mergedAt`
     - One-line fix summary (repo, branch, version bump)
     - Footer `_— server-foundation-agent_`
   - MCP `transition_issue` toward **Closed** (multi-step OK):
     - Shortest path from **In Progress** through Review / Testing / Resolved to **Closed**
     - If a transition fails, record `action: failed` with error; do **not** retry blindly
     - If transition succeeds, ensure the row has `closed_this_run: true`
   - Example `remediation.json` row:
     ```json
     {
       "cve_id": "CVE-2026-39821",
       "issue_key": "ACM-35352",
       "repo": "stolostron/ocm",
       "branch": "backplane-2.8",
       "action": "closed_merged_pr",
       "closed_this_run": true,
       "pr_url": "https://github.com/stolostron/ocm/pull/767",
       "pr_state": "MERGED",
       "merged_at": "2026-06-22T20:19:32Z",
       "notes": "ocm#767 merged: golang.org/x/net v0.53.0 → v0.56.0 on backplane-2.8"
     }
     ```

When one merged PR covers multiple vulnerability issues (listed in the PR body), **close
and record `closed_merged_pr` with `closed_this_run: true` for every linked issue still
In Progress** — not only the first. Parse `ACM-xxxxx` keys from the merged PR
description. **Do not** record or close issues already **Closed**/**Done**, or already
bearing a `CVE Remediation: PR merged` agent comment.

**Guardrails:**

- Close **only** when `gh` confirms `MERGED` for a PR that fixes this issue's
  repo/branch/CVE
- Do **not** close on open/draft PRs, unmerged closed PRs, or branch version alone
- Do **not** close ✅ Not Vulnerable issues automatically (§6.3) — only ❌/⚠️ with merged
  fix PR, or §6.2 Not Applicable

### 6.6 Remediation report

Write `.output/cve-analysis/remediation-report.md` with:

- PRs opened (URL, repo, branch, linked JIRA keys)
- Issues closed as Not Applicable (keys + one-line rationale)
- Issues closed because fix PR merged (keys + PR URL)
- Skipped (already fixed, existing PR)
- Failures (PR create, transition, tests)

Post the remediation summary (or link to full report) as MCP `add_comment` on each
**Vulnerability** issue remediated this run (skip if the same summary was already posted
with `_— server-foundation-agent_` unless `FORCE_REANALYSIS`).

Write `.output/cve-analysis/run_meta.json` before Phase 7 (counts for Slack):

```json
{
  "issues_found": 15,
  "cves_processed": 2,
  "comments_posted": 17,
  "failures": ["sfa-assisted label not found on target repos"],
  "follow_up": "Optional non-PR notes only (e.g. z-stream backport branches)",
  "jira_closed_this_run": [
    {
      "issue_key": "ACM-35352",
      "action": "closed_merged_pr",
      "closed_this_run": true,
      "pr_url": "https://github.com/stolostron/ocm/pull/767",
      "notes": "ocm#767 merged: golang.org/x/net v0.53.0 → v0.56.0 on backplane-2.8"
    }
  ]
}
```

Append every Jira closure **this run** to `jira_closed_this_run` (same shape as
`remediation.json` closure rows, including `closed_this_run: true`). Used as a backup if
`remediation.json` is incomplete. Do **not** list issues that were already Closed before
this run.

`follow_up` is appended after auto-generated PR follow-up (clickable PR links per open
PR). Use only for **non-PR** notes (e.g. z-stream backport branches). Do **not** list PR
approval steps or bare `repo#number` references — Slack links PRs automatically.

## Phase 7: Slack

**Required** when `SLACK_WEBHOOK_URL` is set unless `SKIP_SLACK`. Do not skip silently.

### 7.1 Verify closure records

Before Slack, confirm every Jira transitioned to Closed **this run** has a matching row in
`remediation.json` (`action`: `closed`, `closed_merged_pr`, or `toolchain_verify_close`,
with `closed_this_run: true`).
If any closure is missing, append the row now. Re-read `remediation.json` after edits.
Do **not** add closure rows for issues that were already Closed before this run.

### 7.2 Refresh PR state

```bash
python3 workflows/fix-cve/enrich_remediation_prs.py \
  .output/cve-analysis/remediation.json
```

Re-queries `gh` for every `pr_url` in `remediation.json`, updates `pr_state` /
`is_draft` / `merged_at`, and reclassifies merged or closed PRs (`pr_merged` /
`pr_closed`). If `gh` is unavailable, Phase 7.2 falls back to stored fields.

### 7.3 Generate payload

```bash
python3 workflows/fix-cve/generate_slack_payload.py \
  .output/cve-analysis/ \
  .output/cve-analysis/slack_payload.json
```

Input: `remediation.json`, optional `run_meta.json`, optional `vulnerabilities.json`.
Buckets open PRs into *Draft*, *Ready for review*, and *Merged* using live GitHub state.
Follow-up lists each open PR as a clickable link with the required human action.
Reports:
- `toolchain_rebuild` / `skipped_existing_rebuild` under *Toolchain rebuilds*
- `toolchain_verify_close` (`closed_this_run: true`) under *Closed this run (toolchain verify)*
- `closed_merged_pr` and `closed` (`closed_this_run: true`) under *Closed this run (merged PR)*
  and *Closed as Not Applicable*
Falls back to `run_meta.jira_closed_this_run` when `remediation.json` is incomplete. Issues
closed on prior runs are **not** re-reported.

### 7.4 Send

**Prefer Slack MCP** `send_payload` with `.output/cve-analysis/slack_payload.json`.

**Fallback:**

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh \
  .output/cve-analysis/slack_payload.json
```

**Required behavior:**
- Always send the JSON produced by `generate_slack_payload.py` via `send_to_slack.sh`
  (or Slack MCP `send_payload` with that same JSON). The payload already includes
  clickable Block Kit PR links (`<https://github.com/.../pull/N|repo #N>`).
- **Do not** invent a hand-crafted plain-text digest (e.g. `ocm#797, ocm#798` without
  URLs). That is what made the previous Slack post unusable.
- If send fails, record `Slack: failed (<reason>)` in the final summary. Do **not**
  curl a custom fallback message. `send_to_slack.sh` already retries after stripping
  `<!subteam^...>` mentions when Slack returns `invalid_blocks`.
- If neither Slack MCP nor `SLACK_WEBHOOK_URL` is available → skip Phase 7 and log
  `Slack: skipped (no webhook)` in the final summary
- Record `Slack: sent` or `Slack: failed (<reason>)` in the session output

## Final summary

Report in session output:

- Vulnerability issues found / CVEs grouped / CVEs analysis-skipped (dedup) vs remediated
- Deep analyses completed (this run)
- Jira comments posted (per Vulnerability issue counts)
- **Remediation:** PRs by state (draft / ready / merged; table: PR URL, repo, branch,
  linked keys) — include PRs opened this run for analysis-dedup'd CVEs
- **Remediation:** vulnerability issues closed as Not Applicable (table: key, rationale)
- **Remediation:** vulnerability issues closed because fix PR merged (table: key, PR URL)
- Remediation skipped / failed counts from `remediation.json`
- **Slack:** sent / skipped / failed (with reason)
- Failures (assignee, MCP, clone, missing branches, PR push, Jira transition)
- Recommended human follow-ups **only** for work the agent cannot do (Go toolchain /
  Dockerfile bumps, mark PRs ready, `/ok-to-test`) — **not** for draft dependency PRs
  that §6.4 should have opened

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `CVE-YYYY-NNNNN` | Analyze only that CVE (all statuses) |
| `FORCE_REANALYSIS` | Ignore analysis dedup; repost all comments (Phase 6 still always runs unless `SKIP_REMEDIATION`) |
| `FORCE_REBUILD` | Ignore `toolchain_rebuilds.json` / prior TRIGGER_BUILD; push again |
| `SKIP_DEEP_ANALYSIS` | Collect + classify + inventory only (Phases 1–3); skip Phases 4–5 |
| `SKIP_REMEDIATION` | Analysis + Jira comments only (skip Phase 6) |
| `SKIP_SLACK` | Skip Phase 7 |
| `INCLUDE_BULK_SCANS` | Include multi-CVE scanner tickets |

## Do not

- Ask the user for confirmation (automated mode)
- Skip Phase 2.5 classification or open module bump PRs for toolchain/stdlib CVEs
- Skip Phase 7 when `SLACK_WEBHOOK_URL` is set (unless `SKIP_SLACK`)
- Create per-CVE summary/tracking Tasks (`CVE-… (N issues, M repos)`)
- Use curl REST for comments on vulnerability issues
- Mark draft PRs ready for review or merge them
- Close vulnerability issues unless: (a) **Not Applicable** with evidence (§6.2),
  (b) linked fix PR is **MERGED** per `gh` (§6.5), or (c) toolchain verify with
  `go version -m` ≥ `min_go` + Fix Version (§6.0 / `sfa-cve-toolchain-verify`)
- Open more than one PR per `(repo, branch, CVE)` per run
- Hand-craft a Slack digest that omits clickable `https://github.com/.../pull/N` URLs
  (always use `generate_slack_payload.py` + `send_to_slack.sh` / MCP `send_payload`)
- Cascade major dependency upgrades on older branches (follow the older-branch SOP)
- Clone or write analysis artifacts under `/tmp` (OpenCode rejects `external_directory (/tmp/*)`);
  use `.output/cve-analysis/` only
- Recommend bumping an indirect module (e.g. `golang.org/x/net`) when the advisory is
  dual-fixed via stdlib and the component does not import the vulnerable package path
- Skip Phase 6 for a CVE because analysis was dedup'd — remediating open ❌ / ⚠️
  issues (draft PRs) and closing ➖ / merged-PR issues is still required
- Report “Draft PRs needed” for dependency bumps as the only outcome when §6.4 was
  not attempted this run
