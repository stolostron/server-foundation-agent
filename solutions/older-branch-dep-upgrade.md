---
title: CVE-driven dependency upgrades on older release branches
symptom: "go build fails after upgrading a CVE-affected dependency — cascade into k8s.io and OCM deps"
keywords: [CVE, dependency upgrade, go mod, replace directive, k8s.io, addon-framework, api, sdk-go, cel-go, helm, older branch, backplane, release, cascade, go build]
affected_versions: "ACM 2.12+ (backplane-2.7 through current)"
last_verified: 2026-03-19
status: active
---

# SOP: CVE-Driven Dependency Upgrades on Older Release Branches

## Purpose

This document provides a standard operating procedure for handling CVE fixes that require dependency upgrades on older release branches (backplane-2.7 ~ 2.9, release-2.12 ~ 2.14, etc.). The core principle is **minimal change** — fix the CVE without cascading into unnecessary major dependency bumps.

## Background

### The Cascade Problem

When a CVE fix requires upgrading a direct dependency (e.g., helm, golang.org/x/net), Go's MVS (Minimum Version Selection) can trigger a chain reaction:

```
CVE fix in dep X (e.g., helm v3.15 → v3.18)
  └→ dep X requires newer k8s.io (v0.30 → v0.33)
      └→ newer k8s.io requires newer controller-runtime (v0.18 → v0.20)
          └→ OCM deps (api/sdk-go/addon-framework) incompatible with new k8s
              └→ forced to upgrade OCM deps to v1.x (breaking changes)
                  └→ extensive source code modifications required
```

### OCM Dependency Compatibility Tiers

| Tier | addon-framework | api | sdk-go | Go | k8s.io | controller-runtime |
|------|----------------|-----|--------|-----|--------|-------------------|
| A | v0.9.0 | v0.8.0, v0.13.0 | v0.13.0 | 1.18~1.21 | v0.23~v0.29 | v0.11~v0.16 |
| B | v0.11.0, v0.12.0 | v0.15.0, v0.16.x | v0.15.0, v0.16.0 | 1.22 | v0.30 | v0.18 |
| C | v1.1.x | v1.1.0 | v1.1.0 | 1.24 | v0.33 | v0.20 |
| D | v1.2.0 | v1.2.0 | v1.2.0 | 1.25 | v0.34 | v0.22 |

**Rule**: Upgrading across tiers introduces breaking changes. Within a tier, versions are compatible.

### Vendor directory policy (hard rule)

Before running any `go mod vendor`:

```bash
test -d vendor   # on the checkout of the *base* branch / start of the fix worktree
```

| Result | Action |
|--------|--------|
| `vendor/` **exists** | After `go get` / `go mod tidy`, run `go mod vendor` and include `vendor/` in the PR |
| `vendor/` **missing** | **Do not** run `go mod vendor`. Commit **only** `go.mod` and `go.sum` |

**Why:** Introducing a new `vendor/` tree into a non-vendored repo breaks hermetic
Konflux builds. When `vendor/` is present, cachi2/Hermeto skips gomod prefetch
(empty offline module cache). Dockerfiles that then run `rm -fr vendor && go
mod vendor` fail offline (example: ACM-37377 / stolostron/cluster-permission#284).
Mintmaker-style security bumps for non-vendored repos already use go.mod/go.sum
only (e.g. cluster-permission#239).

### Golden Rule for Older Branches

> **Never upgrade OCM dependencies (addon-framework, api, sdk-go) on older branches unless absolutely necessary.** These three libraries have breaking changes between tiers. Use `replace` directives to isolate the CVE fix from the broader dependency graph.

---

## Decision Flowchart

```
CVE requires upgrading package X
    │
    ├─ Q1: Does package X have a patch release in the SAME minor version?
    │   ├─ YES → Strategy A: Same-minor patch (simplest, go to Step 1A)
    │   └─ NO ↓
    │
    ├─ Q2: Does the newer version of X pull in newer k8s.io?
    │   ├─ NO → Just `go get X@version` (no cascade risk)
    │   └─ YES ↓
    │
    ├─ Q3: Can we pin k8s.io to current minor's latest patch via replace?
    │   ├─ YES → Strategy C: Replace directive (go to Step 1C)
    │   └─ NO (compile fails) ↓
    │
    └─ Q4: Last resort
        └─ Strategy D: Full upgrade with OCM dep bump (go to Step 1D)
```

---

## Strategy A: Same-Minor Patch Upgrade

**When**: The CVE-affected package has a patch release within the same minor version.

**Example**: `k8s.io/client-go` v0.30.3 → v0.30.14 (CVE fix backported to 1.30 release branch).

### Step 1A: Identify available patches

```bash
# For k8s.io packages, check kubernetes release tags
gh api repos/kubernetes/kubernetes/tags --paginate --jq '.[].name' | grep '^v1\.30\.' | sort -V

# For other packages, check their tags
gh api repos/<org>/<repo>/tags --jq '.[].name' | grep '<minor>' | sort -V
```

### Step 2A: Apply the patch

```bash
cd <repo-worktree>
go get k8s.io/client-go@v0.30.14
go mod tidy
# Only if vendor/ already existed on the base branch (see Vendor directory policy):
# go mod vendor
go build ./...
```

### Step 3A: Verify

- No source code changes should be needed
- Run tests: `go test ./...`

**Risk**: Minimal. Same minor version guarantees API compatibility.

---

## Strategy C: Replace Directive (Recommended for Cross-Minor Upgrades)

**When**: The CVE fix only exists in a newer minor version that would cascade into k8s.io and OCM dep upgrades.

**Example**: helm v3.15.3 → v3.18.6 (CVE only fixed in v3.18.5+, helm v3.18 requires k8s v0.33).

### Step 1C: Identify current dependency versions

```bash
cd <repo-worktree>

# Record current versions
echo "=== Current state ==="
grep '^go ' go.mod
grep 'k8s.io/' go.mod | grep -v '//'
grep 'open-cluster-management.io/' go.mod | grep -v module
grep 'sigs.k8s.io/controller-runtime' go.mod
grep 'cel-go\|cel.dev\|antlr\|genproto' go.mod
```

Save this output — you will need it to build the replace block.

### Step 2C: Upgrade the CVE-affected package

```bash
go get <package>@<fixed-version>
# Example:
go get helm.sh/helm/v3@v3.18.6
```

This will cascade and pull in newer k8s.io versions. That is expected — we will revert them in the next step.

### Step 3C: Add replace directives

Add a `replace` block to `go.mod` pinning all k8s.io and related packages back to their original minor's latest patch version.

**Template replace block** (adapt versions to your branch):

```go
replace (
    // Pin k8s.io to current minor's latest patch
    k8s.io/api => k8s.io/api v0.30.14
    k8s.io/apiextensions-apiserver => k8s.io/apiextensions-apiserver v0.30.14
    k8s.io/apimachinery => k8s.io/apimachinery v0.30.14
    k8s.io/apiserver => k8s.io/apiserver v0.30.14
    k8s.io/client-go => k8s.io/client-go v0.30.14
    k8s.io/component-base => k8s.io/component-base v0.30.14
    k8s.io/kms => k8s.io/kms v0.30.14
    k8s.io/kube-aggregator => k8s.io/kube-aggregator v0.30.14
    k8s.io/kube-openapi => k8s.io/kube-openapi v0.0.0-20240228011516-70dd3763d340

    // Pin controller-runtime
    sigs.k8s.io/controller-runtime => sigs.k8s.io/controller-runtime v0.18.5

    // Pin k8s ecosystem packages
    sigs.k8s.io/apiserver-network-proxy/konnectivity-client => sigs.k8s.io/apiserver-network-proxy/konnectivity-client v0.29.0
    sigs.k8s.io/json => sigs.k8s.io/json v0.0.0-20221116044647-bc3834ca7abd
    sigs.k8s.io/structured-merge-diff/v4 => sigs.k8s.io/structured-merge-diff/v4 v4.4.1
    sigs.k8s.io/yaml => sigs.k8s.io/yaml v1.4.0

    // Pin CEL-related packages (required when k8s apiserver is pinned to older version)
    github.com/google/cel-go => github.com/google/cel-go v0.17.8
    cel.dev/expr => cel.dev/expr v0.16.1
    github.com/antlr4-go/antlr/v4 => github.com/antlr/antlr4/runtime/Go/antlr/v4 v4.0.0-20230305170008-8188dc5388df
    google.golang.org/genproto/googleapis/api => google.golang.org/genproto/googleapis/api v0.0.0-20240701130421-f6361c86f094
    google.golang.org/genproto/googleapis/rpc => google.golang.org/genproto/googleapis/rpc v0.0.0-20240701130421-f6361c86f094
)
```

**Important**: The exact versions in the replace block must match what the branch was originally using. Use the output from Step 1C.

### Step 4C: Resolve and build

```bash
go mod tidy
# Only if vendor/ already existed on the base branch (see Vendor directory policy):
# go mod vendor
go build ./...
```

### Step 5C: Troubleshoot compilation errors

If `go build` fails, it is usually because:

1. **CEL / genproto mismatch**: The upgraded package pulled in a newer `cel-go` or `genproto` that is incompatible with the pinned `k8s.io/apiserver`. Add the CEL-related packages to the replace block (see template above).

2. **New transitive dependency**: The upgraded package introduced a new dependency that conflicts with pinned versions. Check the error message, identify the conflicting package, and add it to the replace block.

3. **The upgraded package itself uses new k8s APIs**: This means the upgraded package's code directly calls k8s v0.33 APIs that do not exist in v0.30. In this case, Strategy C will not work — fall back to Strategy D.

### Step 6C: Verify no source code changes

```bash
# Should return empty — only go.mod, go.sum, and vendor/ (if already vendored) should change
git diff --name-only | grep -v '^vendor/' | grep -v '^go\.\(mod\|sum\)$'
```

If any `.go` files outside `vendor/` are changed, something is wrong. The replace strategy should require **zero source code changes**.

### Step 7C: Run tests

```bash
go test ./...
# or project-specific test commands
make test
```

---

## Strategy D: Full Upgrade (Last Resort)

**When**: Strategy A and C both fail — the CVE fix genuinely requires newer k8s APIs that cannot be satisfied by pinning.

**Warning**: This involves crossing OCM dependency tiers and will require source code changes to adapt to breaking changes in addon-framework, api, and sdk-go.

### Before proceeding, confirm:

- [ ] Strategy A is not possible (no same-minor patch exists)
- [ ] Strategy C is not possible (replace causes compile failure in the upgraded package itself, not just transitive deps)
- [ ] The CVE is confirmed to affect your deployment (not all CVEs are exploitable in every context)
- [ ] Team lead has approved the scope of changes

### Steps

1. Upgrade all dependencies together to the target tier
2. Adapt source code to OCM breaking changes
3. Update CRD manifests if OCM API types changed
4. Run full test suite
5. Request thorough code review — the blast radius is large

---

## Quick Reference: Version Mapping

### k8s.io Latest Patch Versions (check for updates)

| Minor | Latest Patch | EOL Status |
|-------|-------------|------------|
| v0.29.x | v0.29.15 | Maintained |
| v0.30.x | v0.30.14 | Maintained |
| v0.31.x | v0.31.x | Maintained |
| v0.32.x | v0.32.x | Maintained |
| v0.33.x | v0.33.x | Current |
| v0.34.x | v0.34.x | Current |

To get the latest patch for a k8s minor:
```bash
gh api repos/kubernetes/kubernetes/tags --paginate --jq '.[].name' | grep '^v1\.30\.' | sort -V | tail -1
```

### Branch-to-Tier Mapping

| Branch | Tier | k8s.io | OCM deps |
|--------|------|--------|----------|
| backplane-2.7 / release-2.12 | A~B | v0.29~v0.30 | v0.9~v0.15 |
| backplane-2.8 / release-2.13 | B | v0.30 | v0.11~v0.16 |
| backplane-2.9 / release-2.14 | B | v0.30 | v0.12~v0.16 |
| backplane-2.10 / release-2.15 | B~C | v0.30~v0.33 | v0.11~v1.1 |
| backplane-2.11 / release-2.16 | C~D | v0.33~v0.34 | v1.1~v1.2 |
| main | C | v0.33 | v1.1 |

### Common CVE-Affected Packages and Their Replace Needs

| Package | Likely cascade? | Replace needed for |
|---------|---------------|--------------------|
| `helm.sh/helm/v3` | Yes — each helm minor bumps k8s | k8s.io, cel-go, genproto |
| `golang.org/x/net` | Usually no — independent of k8s | None usually |
| `golang.org/x/crypto` | Usually no | None usually |
| `google.golang.org/grpc` | Sometimes — newer grpc may need newer protobuf | google.golang.org/protobuf |
| `github.com/opencontainers/*` | Rarely | None usually |

---

## Worked Example: helm CVE on backplane-2.7

**Scenario**: GHSA-9h84-qmv7-982p requires helm >= v3.18.5. Branch uses helm v3.15.3.

**Decision path**:
1. helm v3.15.x has no security backport → Strategy A not possible
2. helm v3.18.6 requires k8s v0.33 → cascade risk
3. Try Strategy C (replace)

**Execution**:
```bash
# Step 1: Record current state
grep 'k8s.io/' go.mod | grep -v '//'
# k8s.io/* v0.30.3, cel-go v0.17.8, etc.

# Step 2: Upgrade helm
go get helm.sh/helm/v3@v3.18.6
# k8s.io pulled to v0.33.3 — expected

# Step 3: Add replace block (pin k8s back to v0.30.14)
# See template above

# Step 4: Build (go mod vendor only if vendor/ already existed — see policy)
go mod tidy && go build ./...
# If test -d vendor: also run go mod vendor before build
```

**Result**: Build passes. Zero `.go` source changes. Only `go.mod`, `go.sum`, and (if already vendored) `vendor/` modified.

**Comparison with full upgrade approach**:

| | Replace (Strategy C) | Full Upgrade (Strategy D) |
|---|---|---|
| Source code changes | 0 files | 50+ files |
| k8s.io version | v0.30.14 (same minor) | v0.33.3 (cross-minor) |
| OCM deps | Unchanged | v0.14 → v1.1.0 |
| Breaking change risk | None | High |
| Review effort | Low | High |

---

## Checklist

Before submitting a CVE fix PR on an older branch:

- [ ] Confirmed which strategy (A/C/D) is being used
- [ ] Vendor policy: ran `go mod vendor` only if `vendor/` already existed on the base branch; did **not** introduce a new `vendor/` tree
- [ ] If Strategy C: replace block pins ALL k8s.io and ecosystem packages (including cel-go, genproto)
- [ ] `go build ./...` passes
- [ ] `go test ./...` passes (or CI tests pass)
- [ ] No `.go` source files changed outside `vendor/` (for Strategy A/C)
- [ ] OCM dependencies (addon-framework, api, sdk-go) are NOT upgraded (for Strategy A/C)
- [ ] PR description explains the upgrade strategy and why it was chosen
- [ ] k8s.io patch version used is the latest available for that minor (e.g., v0.30.14 not v0.30.3)
