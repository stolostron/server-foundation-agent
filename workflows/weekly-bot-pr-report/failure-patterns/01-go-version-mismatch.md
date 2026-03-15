---
id: FP-01
name: Go Version Mismatch
action_on_match: patched
requires_clone: true
---

# FP-01: Go Version Mismatch

A bot PR updates `go.mod` with a new Go directive version (e.g., `go 1.22` to `go 1.23`), but CI workflows and Dockerfiles still reference the old version, causing build failures.

## Detection

1. Run `gh pr diff <number> -R <repo> --name-only` and check if `go.mod` is in the changed files.
2. If yes, run `gh pr diff <number> -R <repo>` and look for a changed `go` directive line:
   ```
   -go 1.22
   +go 1.23
   ```
   Ignore dependency-only changes (lines starting with `require`, `replace`, or module paths).
3. If a `go X.Y` directive changed, extract the **old version** and **new version**.

**Match condition**: `go.mod` contains a changed `go X.Y` directive AND at least one failed check is a build or image check (`ci/prow/images`, or any check with `build` or `image` in the name).

## Fix Procedure

1. Clone the PR branch using the `clone-worktree` skill:
   ```bash
   WORKTREE=$(.claude/skills/clone-worktree/clone-worktree.sh <org/repo> <pr-number>)
   cd "$WORKTREE"
   ```

2. Find and update all `.github/workflows/*.yml` files that reference the old Go version:
   - Look for patterns: `go-version: 'X.Y'`, `go-version: "X.Y"`, `go-version: X.Y`, `go-version: X.Y.Z`
   - Replace with the new Go version (major.minor only, e.g., `1.23`)

3. Find and update all `Dockerfile*` files that use `golang:X.Y` as a base image:
   - Look for patterns: `FROM golang:X.Y`, `FROM golang:X.Y.Z`, `FROM golang:X.Y-alpine`, etc.
   - Replace the Go version portion with the new version

4. Run `go mod tidy` if a `go.sum` exists.

5. Commit and push all changes:
   ```bash
   git add -A
   git commit -s -m "fix: update Go version references to match go.mod directive"
   git push
   ```

6. Clean up the worktree:
   ```bash
   .claude/skills/clone-worktree/clone-worktree.sh --remove <org/repo> <pr-number>
   ```

## Verification

- Confirm the commit was pushed successfully (check `git push` exit code).
- The pushed commit should trigger a CI re-run automatically.

## Scope

- Only modify files within the PR's repository.
- Do NOT update files in other repositories or cross-repo references.
- Only update Go version strings — do not modify other workflow settings.
