# Agent Dependencies

All external dependencies required for the server-foundation-agent to run at full capacity.

## Runtime Environments

| Runtime | Min Version | Used By | Notes |
|---------|-------------|---------|-------|
| **Bash** | 4.0+ | All skills & workflows | Shell scripts throughout |
| **Python 3** | 3.7+ | skills & workflows | stdlib only, no pip packages needed (`from __future__ import annotations`) |
| **Go** | 1.24+ | All SF repos (coding agent) | Build, test, vet, mod tidy |

> **No Node.js / JavaScript runtime is required.** All scripts are Bash or Python.

### Python stdlib modules used

All Python scripts use standard library only. Modules: `json`, `sys`, `os`, `datetime`, `collections`, `subprocess`, `glob`, `urllib.request`, `urllib.error`, `base64`, `time`, `argparse`, `typing`, `re`.

## CLI Binaries

| Binary | Required | Used By (count) | Install |
|--------|----------|-----------------|---------|
| `curl` | Yes | 13 skills | System default or `brew install curl` |
| `jq` | Yes | 19 skills, 3 workflows | `brew install jq` |
| `git` | Yes | 8 skills, all workflows | System default or `brew install git` |
| `gh` | Yes | 4 skills (fetch-prs, workspace-clone, workspace-cleanup, jira-inbox) | `brew install gh` |
| `oc` | Conditional | 4 skills (install-acm, bug-reproduce, cluster-pools, uninstall-acm) | [OpenShift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/) |
| `kubectl` | Conditional | 3 skills (install-acm, bug-reproduce, uninstall-acm) | `brew install kubectl` or bundled with `oc` |
| `helm` | Conditional | SF repos with Helm charts (registration-operator, cluster-manager) | `brew install helm` |
| `aws` | Conditional | 1 skill (cluster-pools) | `brew install awscli` |
| `hiveutil` | Conditional | 1 skill (cluster-pools, AWS cleanup) | `go install github.com/openshift/hive/contrib/cmd/hiveutil@latest` |
| `make` | Yes | All SF repos (Makefiles) | System default or `brew install make` |
| `gcc` | Yes | Go CGO compilation | System default (Xcode CLT on macOS) |
| `openssl` | Yes | GitHub App JWT signing (github-app-iat.sh) | System default or `brew install openssl` |
| `golangci-lint` | Yes | Most SF repos CI linting | `brew install golangci-lint` |
| `base64` | Yes | 1 skill (cluster-pools) | Built-in on macOS/Linux |
| `yq` | Yes | YAML validation (per CLAUDE.md global rules) | `brew install yq` |
| `skopeo` | Conditional | 1 skill (sfa-cve-toolchain-verify — Konflux image inspect/copy) | `brew install skopeo` |

### LSP Servers (coding agent)

| Binary | Purpose | Install |
|--------|---------|---------|
| `gopls` | Go LSP — go-to-definition, find-references, diagnostics | `go install golang.org/x/tools/gopls@latest` |
| `pylsp` | Python LSP — SFA skills and workflows use Python scripts | `pip install python-lsp-server` |

### Conditional vs Required

- **Required**: Needed for core agent functionality (Jira, GitHub, workspace management, Go development).
- **Conditional**: Only needed if using cluster/ACM-related skills. The agent works without them for Jira/GitHub/reporting tasks.

## Credentials & Environment Variables

### Jira (13 skills)

| Variable | Description | Used By |
|----------|-------------|---------|
| `JIRA_EMAIL` | Red Hat Jira Cloud account email | All `sfa-jira-*` skills, bug-analyze, bug-reproduce, cve-analysis, jira-triage |
| `JIRA_API_TOKEN` | Jira Cloud API token ([create here](https://id.atlassian.com/manage-profile/security/api-tokens)) | Same as above |

**Access required**: Read/write to ACM project on `redhat.atlassian.net`, including custom fields (Activity Type `customfield_10464`, Severity `customfield_10840`, Sprint `customfield_10020`).

### GitHub (4 skills)

| Variable | Description | Used By |
|----------|-------------|---------|
| `GITHUB_TOKEN` | GitHub personal access token (implicit via `gh auth`) | sfa-github-fetch-prs, sfa-workspace-clone, sfa-workspace-cleanup |
| `GH_APP_ID` | GitHub App ID (autonomous mode only) | sfa-workspace-clone |
| `GH_APP_INSTALLATION_ID` | GitHub App Installation ID (autonomous mode only) | sfa-workspace-clone |

**Access required**: Read/write to `stolostron` and `open-cluster-management-io` orgs, fork repos, create PRs.

**Autonomous mode**: When both `GH_APP_ID` and `GH_APP_INSTALLATION_ID` are set, the agent runs in autonomous mode — pushes directly to upstream repos with `sfa/` branch prefix instead of using the fork workflow. See [Development Guide](development-guide.md#push-workflow).

### Slack (1 skill)

| Variable | Description | Used By |
|----------|-------------|---------|
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL | sfa-slack-notify |

### AWS (1 skill)

| Variable | Description | Used By |
|----------|-------------|---------|
| `AWS_ACCESS_KEY_ID` | AWS access key | sfa-cluster-pools |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key | sfa-cluster-pools |
| `AWS_REGION` | AWS region (default: `us-east-1`) | sfa-cluster-pools |

**Access required**: EC2 (DescribeInstances, DescribeVPCs, DescribeVolumes), ELB, S3 read access. Optional delete permissions for orphan cleanup.

### Kubernetes / OpenShift (4 skills)

Different skills connect to **different clusters** — there is no single shared KUBECONFIG.

| Skill | Target Cluster | KUBECONFIG Source | Notes |
|-------|---------------|-------------------|-------|
| **sfa-cluster-pools** | Collective cluster (`api.collective.aws.red-chesterfield.com:6443`) | Fixed path: `/tmp/kube/collective.kubeconfig` | Manages cluster pools and claims; login via `oc login --web` with GitHub OIDC |
| **install-acm** | User-specified OCP cluster | `--kubeconfig PATH` flag or `$KUBECONFIG` | Each invocation may target a different cluster |
| **uninstall-acm** | User-specified OCP cluster | `--kubeconfig PATH` flag or `$KUBECONFIG` | Same target as install-acm |
| **sfa-bug-reproduce** | User-specified test cluster | `$KUBECONFIG` or current context | Ephemeral cluster for bug reproduction |

**Access required**: `cluster-admin` role on whichever cluster is targeted.

### Quay.io (1 skill)

| Credential | Description | Used By |
|------------|-------------|---------|
| Pull-secret file | JSON pull-secret for Quay.io private registries | install-acm (downstream builds) |

## Per-Skill Dependency Matrix

| Skill | CLI | Credentials | Runtime |
|-------|-----|-------------|---------|
| install-acm | oc, kubectl, jq, curl | KUBECONFIG (user-specified target cluster), pull-secret | bash |
| uninstall-acm | oc, kubectl, jq | KUBECONFIG (user-specified target cluster) | bash |
| sfa-bug-analyze | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash, python3 |
| sfa-bug-reproduce | curl, jq, oc, kubectl | JIRA_EMAIL, JIRA_API_TOKEN, KUBECONFIG (user-specified test cluster) | bash, python3 |
| sfa-cluster-pools | oc, kubectl, jq, aws, hiveutil | `/tmp/kube/collective.kubeconfig` (collective cluster), AWS_* | bash |
| sfa-cve-analysis | curl, jq, git | JIRA_EMAIL, JIRA_API_TOKEN | bash, python3 |
| sfa-cve-toolchain | git, gh | GITHUB_TOKEN, Jira MCP | bash, python3 |
| sfa-cve-toolchain-verify | skopeo, go, gh | GITHUB_TOKEN, Jira MCP | bash, python3 |
| sfa-github-fetch-prs | gh, jq | GITHUB_TOKEN | bash |
| sfa-jira-comment | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash |
| sfa-jira-create | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash |
| sfa-jira-inbox | curl, jq, gh | JIRA_EMAIL, JIRA_API_TOKEN, GITHUB_TOKEN | bash, python3 |
| sfa-jira-search | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash, python3 |
| sfa-jira-sprint-report | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash, python3 |
| sfa-jira-standup | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash |
| sfa-jira-triage | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash |
| sfa-jira-update | curl, jq | JIRA_EMAIL, JIRA_API_TOKEN | bash |
| sfa-prow-config | — | — | bash |
| sfa-repo-sync | git | — | bash |
| sfa-slack-notify | curl, jq | SLACK_WEBHOOK_URL | bash |
| sfa-solution-add | — | — | bash |
| sfa-update | — | — | bash |
| sfa-workspace-cleanup | gh, jq, git | GITHUB_TOKEN | bash |
| sfa-workspace-clone | git, gh, jq | GITHUB_TOKEN | bash |

## Per-Workflow Dependency Matrix

| Workflow | CLI | Credentials | Runtime |
|----------|-----|-------------|---------|
| daily-bug-triage | curl, jq, gh | JIRA_EMAIL, JIRA_API_TOKEN, SLACK_WEBHOOK_URL | bash, python3 |
| daily-scrum-prep | curl, jq, gh | JIRA_EMAIL, JIRA_API_TOKEN, SLACK_WEBHOOK_URL | bash, python3 |
| weekly-pr-report | gh, jq | GITHUB_TOKEN, SLACK_WEBHOOK_URL | bash, python3 |
| weekly-bot-pr-hygiene | gh, jq | GITHUB_TOKEN, SLACK_WEBHOOK_URL | bash, python3 |

## Quick Setup Checklist

```bash
# 1. Install required CLI tools (macOS)
brew install jq gh yq golangci-lint
# Optional (toolchain CVE verify): brew install skopeo

# 2. Install Go (https://go.dev/dl/)
# Verify: go version  # 1.24+ required

# 3. Install Go LSP and Python LSP
go install golang.org/x/tools/gopls@latest
pip install python-lsp-server

# 4. Install conditional CLI tools (only if using cluster skills)
# Download oc from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/
brew install awscli kubectl helm
go install github.com/openshift/hive/contrib/cmd/hiveutil@latest

# 5. Authenticate GitHub CLI
gh auth login

# 6. Set Jira credentials
export JIRA_EMAIL="your-email@redhat.com"
export JIRA_API_TOKEN="your-api-token"

# 7. (Optional) Set Slack webhook
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."

# 8. (Optional) Set AWS credentials for cluster-pools
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

# 9. Verify runtimes
python3 --version  # 3.7+ required, stdlib only
go version         # 1.24+ required
```

## Container Image

All dependencies are also packaged as a container image in [`build/Dockerfile`](../build/README.md). This is the executable version of this document — they must stay in sync.
