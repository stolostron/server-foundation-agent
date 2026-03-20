# Development Guide

This guide defines development standards that **MUST** be followed in all contexts — local development, CI/CD, and cloud-hosted agent runs.

## Code Standards

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

### Fork Workflow

- Always use the fork workflow: clone from your fork, push to your fork, create PR from fork to upstream.
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

## GitHub Interaction

- Use `gh` CLI for all GitHub operations (PRs, issues, reviews).
- When assigning PRs or issues, use the comment format `/assign @<username>` to trigger CI automation.
- Check for existing related issues or PRs before creating new ones to avoid duplicates.
