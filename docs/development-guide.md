# Development Guide

This guide defines development standards that **MUST** be followed in all contexts — local development, CI/CD, and cloud-hosted agent runs.

## Progressive Disclosure Guidelines

When adding or modifying skills and docs, follow these sizing guidelines:

- **SKILL.md** should stay under ~100 lines — extract detailed knowledge (field mappings, syntax references, templates) to `docs/` reference files
- **Docs** over 150 lines likely cover multiple topics — split into sub-files under the appropriate subdirectory
- Duplicated content across multiple skills should be extracted to a shared reference file
- Ask: "Does the agent need this knowledge for every invocation, or only sometimes?" — if sometimes, put it in a reference file

## Code Standards

### Prefer Kubernetes Ecosystem Libraries

This project is entirely within the Kubernetes ecosystem. When implementing features or fixing bugs, **always** check if a suitable library exists in `k8s.io/*` or `sigs.k8s.io/*` before writing custom code. These libraries are battle-tested, handle edge cases (singleflight, striped caching, proper key derivation, etc.), and are maintained by the community.

- Check `go.mod` indirect dependencies — the library may already be available.
- Examples: use `k8s.io/apiserver/pkg/authentication/token/cache` instead of a custom token cache; use `k8s.io/client-go/util/workqueue` instead of a custom work queue.
- Only write custom code when no suitable k8s library exists.

### Comments

- All code comments **MUST** be written in English.

### YAML Validation

- Always validate YAML files before committing:

```bash
yq eval '.' your-file.yaml > /dev/null && echo "Valid YAML" || echo "Invalid YAML"
```

## Git Commit Standards

- Always sign off commits: `git commit -s -m "type(scope): description"`
- Conventional commit types: `fix`, `feat`, `chore`, `docs`, `refactor`, `test`
- Keep commit messages concise and descriptive

## Pull Request Standards

### PR Templates

Before creating a PR, **always** check for PR templates in the target repository:

- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/PULL_REQUEST_TEMPLATE/` directory

If a template exists, use it. Do not skip or ignore template sections.

Similarly, check for issue templates when creating issues:

- `.github/ISSUE_TEMPLATE/`
- `.github/ISSUE_TEMPLATE.md`

### PR Title Convention

- Keep the PR title under 70 characters.
- The PR title **MUST** reflect ALL commits in the branch, not just the latest one. Always run `git log` and `git diff` against the base branch to capture the full scope.
- When targeting a **non-main branch** (e.g., `release-2.14`, `backplane-2.7`), include the branch name in the PR title:

```
fix(placement): handle nil pointer on status sync [release-2.14]
```

This makes it easy to identify backport or release-specific PRs at a glance.

### PR Description

- Use the description/body for details, not the title.
- Explain the **what** and **why** of the change.
- Reference related Jira issues or GitHub issues when applicable.
- When updating a PR (adding commits, rebasing), check if the description also needs updating.

### Push Workflow

The agent supports two push modes, selected automatically based on environment:

**Autonomous mode** — when `GH_APP_ID` and `GH_APP_INSTALLATION_ID` are set (agent running self-sufficiently on a remote machine):

- Push directly to the upstream repo.
- All branches MUST use the `sfa/` prefix (e.g., `sfa/upgrade-anp`) to identify agent-created branches.
- PR creation: `gh pr create --repo <org/repo>` (same-repo PR, no `--head` needed).

**Local mode** (default) — human-collaborative development on a developer's machine:

- Always use the fork workflow: push to your fork, create PR from fork to upstream.
- Use `gh repo fork <upstream> --clone=false` to ensure a fork exists before cloning.
- Never push branches directly to upstream repos.

### PR Target: OCM vs Stolostron

Many SF repos exist in both the `open-cluster-management-io` (OCM community) and `stolostron` (Red Hat downstream) GitHub orgs. Their `main` branches **diverge** — stolostron repos contain extra files (`.tekton/`, `Dockerfile.rhtap`, etc.) that don't exist in OCM.

Choose the correct target org based on the task type:

| Task Type | Target Org | Example |
|-----------|------------|---------|
| **New feature** | `open-cluster-management-io` (OCM) | Adding a new API field, new controller logic |
| **Maintenance** (dependency upgrades, CI fixes) | `stolostron` | Bumping go module versions, fixing Prow configs |
| **Backport** | `stolostron` | Cherry-picking a fix to `release-*` or `backplane-*` branches |

When the target is ambiguous, ask before proceeding — do not assume.

## Maintenance Across Branches

When doing maintenance work (dependency upgrades, CI fixes, etc.) across multiple release branches, the instruction is typically phrased as "from X to main" (e.g., "from backplane-2.7 to main"). This means submitting the change to **every active branch in the range**.

### Fast-forward rule

The `main` branch automatically fast-forwards to the **latest release branch** (see [build-release/branch-tables.md](build-release/branch-tables.md) for the current target). You must **skip that branch** — it receives updates from `main` automatically. Never commit directly to the fast-forward target branch.

### Branch range by repo type

- **MCE repos** have `backplane-*` branches only (no `release-*`)
- **ACM repos** have `release-*` branches only (no `backplane-*`)
- **Special repos** (e.g., cluster-permission) may have both

See [build-release/branch-tables.md](build-release/branch-tables.md) for the full active branch list and concrete examples.

## Dependency Management (CRITICAL)

When adding, removing, or modifying any skill, **always cross-validate** against dependency management artifacts:

1. **`build/Dockerfile`** — does it include all CLI tools and runtimes the skill requires? If not, add them.
2. **`docs/dependencies.md`** — is the dependency documented with correct "Used By" and "Required/Conditional" status? Update the Per-Skill Dependency Matrix.

Both files must stay in sync. A new skill that needs a tool not in the Dockerfile will fail at runtime in container. A removed skill may leave unused dependencies bloating the image.

## SFA Footprint (Traceability)

All actions performed by server-foundation-agent **MUST** leave a traceable footprint for data-driven reporting and builder journey presentations.

### Git Commits — Co-authored-by Trailer

When the agent creates or contributes to a commit, **always** append the `Co-authored-by` trailer:

```bash
git commit -s -m "fix(proxy): handle cert rotation timeout

Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>"
```

- The trailer goes in the commit **body**, separated from the subject by a blank line.
- This is in addition to the `Signed-off-by` line from `-s`.
- GitHub natively renders co-authors in the commit UI and they are searchable.

### Pull Requests — Label + Footer

After creating a PR with `gh pr create`, **always** add the `sfa-assisted` label.
The label is **not** defined on most SF repos by default — `gh pr edit --add-label`
fails with `'sfa-assisted' not found` unless the label exists first.

```bash
PR_URL=$(gh pr create ...)
PR_NUM="${PR_URL##*/}"
bash scripts/ensure-sfa-assisted-label.sh <org/repo> "$PR_NUM"
```

`ensure-sfa-assisted-label.sh` creates the label on the target repo (idempotent), then
applies it to the PR.

Include a footer line at the end of the PR description:

```markdown
---
*Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
```

### Jira — Label + Signature

**Issues created** by the agent must include `sfa-assisted` in the labels array.

**All Jira comments** posted by the agent must end with a signature footer:

```
----
_— server-foundation-agent_
```

### Querying Footprints

| Data | Source | Query |
|------|--------|-------|
| PRs created | GitHub | `label:sfa-assisted is:pr org:stolostron` or `author:app/acm-agent` |
| Commits | Git | `git log --grep="Co-authored-by: server-foundation-agent"` |
| Jira issues | Jira | `project = ACM AND labels = sfa-assisted` |
| Jira comments | Jira | Search comment body for `server-foundation-agent` |

## GitHub Interaction

- Use `gh` CLI for all GitHub operations (PRs, issues, reviews).
- When assigning PRs or issues, use the comment format `/assign @<username>` to trigger CI automation.
- Check for existing related issues or PRs before creating new ones to avoid duplicates.
- CI checks are integrated with OpenShift CI (Prow) and GitHub. To retest flaky or failed checks, comment `/retest` on the PR to re-trigger all failed tests, or `/retest <test-name>` to re-trigger a specific one.
