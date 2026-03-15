---
id: FP-03
name: Build Failure
action_on_match: patched
requires_clone: true
---

# FP-03: Build Compilation Failure

The image build or compilation check failed. The agent clones the code, attempts `make build`, diagnoses the error, and tries to fix it.

## Detection

1. Check if any failed check name matches build-related patterns:
   - `ci/prow/images`
   - Any check name containing `build` or `image` (case-insensitive)
2. This pattern is a catch-all for build failures — it should be evaluated AFTER FP-01 (which handles the specific case of Go version mismatch).

**Match condition**: At least one failed check is build-related AND FP-01 did not match.

## Fix Procedure

1. Clone the PR branch using the `clone-worktree` skill:
   ```bash
   WORKTREE=$(.claude/skills/clone-worktree/clone-worktree.sh <org/repo> <pr-number>)
   cd "$WORKTREE"
   ```

2. Attempt to build:
   ```bash
   make build 2>&1
   ```
   **Important**: Use `make build`, NOT `make image` — Docker is not available in the agent container.

3. Analyze the build output:
   - If `make build` **succeeds**: The failure may be Docker-specific or a flaky build. Record as `needs-manual` with details.
   - If `make build` **fails**: Examine the compilation errors.

4. Common fix patterns for compilation errors:
   - **Missing vendor dependencies**: Run `go mod tidy && go mod vendor` and retry.
   - **Import path changes**: Update import paths in affected `.go` files.
   - **API signature changes**: Update function calls to match the new dependency API.
   - **Type incompatibilities**: Adjust type assertions or conversions.

5. If a fix is found and `make build` succeeds after the fix:
   ```bash
   git add -A
   git commit -s -m "fix: resolve build failure from dependency update"
   git push
   ```

6. Clean up the worktree:
   ```bash
   .claude/skills/clone-worktree/clone-worktree.sh --remove <org/repo> <pr-number>
   ```

## Fallback

If `make build` still fails after attempting fixes:
- Record as `needs-manual`.
- Include the specific compilation error in `action_details`.
- Do NOT push partial or broken fixes.

## Verification

- After pushing a fix, confirm `git push` succeeded.
- The pushed commit should trigger a CI re-run automatically.
- If `make build` cannot be fixed, document the error clearly for manual review.

## Scope

- Only modify files within the PR's repository.
- Only attempt fixes that are directly related to the build error.
- Do NOT refactor code, update tests, or make unrelated changes.
