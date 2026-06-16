# Installation Requirements for Fetch PRs Skill

Before using this skill, ensure you have:

## 1. Required Tools

```bash
# GitHub CLI (v2.0.0+)
gh --version

# jq (for JSON processing)
jq --version

# jq (for JSON processing)
jq --version

# yq (optional — fetch-prs.sh uses awk fallback when absent)
yq --version

# Bash 4.0+ (macOS users: brew install bash)
bash --version
```

Install missing tools:

```bash
# macOS
brew install gh jq yq bash

# Linux (Debian/Ubuntu)
sudo apt-get install gh jq
# yq: https://github.com/mikefarah/yq#install

# Linux (RHEL/CentOS)
sudo yum install gh jq
```

### 2. GitHub Authentication

```bash
# Login to GitHub
gh auth login

# Verify authentication
gh auth status
```

You should see "Logged in to github.com as <your-username>".

Note: No special scopes (like `project`) are required. The skill uses `gh pr list` which only needs standard repo read access.
