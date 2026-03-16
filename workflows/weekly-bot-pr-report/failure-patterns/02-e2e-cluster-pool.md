---
id: FP-02
name: E2E Cluster Pool Claim Failure
action_on_match: retest
requires_clone: false
---

# FP-02: E2E Cluster Pool Claim Failure

E2E tests fail because the cluster pool has no available clusters to claim. This is an infrastructure issue, not a code problem — retesting usually resolves it.

## Detection

1. Check if any failed check name contains `e2e` (case-insensitive).
2. If yes, get the check run link from the `all_checks` data for the failed e2e check.
3. Fetch the log page at the check link URL. Look for any of these indicators:
   - `claim provisioning failed`
   - `Claim` with `from ClusterPool` and `failed`
   - `No cluster was checked out`
   - `ClusterClaim` with `failed` or `error`
   - `no available clusters`
   - `claim` with `timeout` or `timed out`
   - `waiting for cluster` with `timeout`
   - `pool` with `exhausted` or `unavailable`

**Match condition**: A failed e2e check exists AND the log contains at least one cluster pool claim failure indicator from the list above.

**Note**: If the e2e check failed but the log does NOT contain cluster pool indicators, this pattern does NOT match — fall through to the next pattern.

## Fix Procedure

No code changes needed. Recommend retest:

1. Record the action as `retest`.
2. In `action_details`, note which e2e check failed and the cluster pool error found.
3. Suggest running `/retest ci/prow/e2e` (or the specific failed e2e check name) as a comment on the PR.

## Verification

No verification step — the retest recommendation is informational.
The CI system will re-run when `/retest` is posted.

## Scope

- Log inspection only — no repository clone or code changes.
- Applies to Prow-based e2e checks that use HyperShift or cluster pool claims.
