# Build

Container image definition for the server-foundation-agent. This Dockerfile is the single source of truth for all runtime dependencies.

## What's Included

| Category | Components | Notes |
|----------|-----------|-------|
| **Runtimes** | Bash 5.x, Python 3.x | Python stdlib only, no pip packages |
| **Go Toolchain** | Go 1.24.x, make, gcc/g++, golangci-lint, gopls | All SF repos are Go — build, test, lint, LSP |
| **Python LSP** | pylsp | SFA skills/workflows use Python scripts |
| **CLI Tools** | curl, jq, git, gh, yq, openssl, skopeo | Core — required for skills; skopeo for CVE image verify |
| **Kubernetes** | kubectl, oc, helm | oc for OpenShift; kubectl for general K8s; helm for charts |
| **Cloud** | aws CLI v2 | For cluster-pools skill (EC2, ELB, S3) |
| **Auth** | GitHub App scripts, git credential helper | Transparent auth in autonomous mode |

## Scripts (build/scripts/)

GitHub App authentication scripts (from kubeopencode/devbox), providing transparent `gh` and `git` auth when running with GitHub App credentials:

| Script | Purpose |
|--------|---------|
| `github-app-iat.sh` | Generate Installation Access Token from GitHub App credentials (JWT/RS256 via openssl) |
| `github-token-manager.sh` | Cache and auto-refresh tokens |
| `gh-wrapper.sh` | Transparent GH_TOKEN injection for `gh` CLI |
| `git-credential-github-app.sh` | Git credential helper for transparent push/pull auth |

When GitHub App credentials are mounted to `/etc/github-app/`, `gh` and `git` commands authenticate automatically — no manual token setup needed.

## What's NOT Included

Unlike the generic devbox image, this image excludes:
- Node.js (no JS/TS code in SF repos)
- typescript-language-server (no JS/TS development)
- Google Cloud CLI, Docker CLI (not used by any SFA skill)

## Build

```bash
# Default build
docker build -t sfa-agent build/

# Pin specific versions
docker build \
  --build-arg GO_VERSION=1.24.4 \
  --build-arg OC_VERSION=4.17.0 \
  -t sfa-agent build/
```

## Relationship to docs/dependencies.md

[docs/dependencies.md](../docs/dependencies.md) is the human-readable dependency reference. This Dockerfile is the executable version — they must stay in sync. When adding a new CLI dependency to a skill, update both.
