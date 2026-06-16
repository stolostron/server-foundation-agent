#!/usr/bin/env bash
# GitHub Token Manager
#
# Provides cached GitHub App Installation Access Tokens with automatic refresh.
# This script is designed to be called frequently without performance concerns.
#
# Features:
#   - Caches token in /tmp/gh_token with expiry tracking
#   - Automatically refreshes token when less than 10 minutes remain
#   - Falls back to existing token if refresh fails
#
# Usage:
#   token=$(github-token-manager.sh)
#   # or load without printing token to stdout/logs:
#   source "$(github-token-manager.sh --env-file)"
#   # or
#   export GH_TOKEN=$(github-token-manager.sh)
#
# Dependencies:
#   - github-app-iat.sh (must be in same directory or /usr/local/bin)
#   - Credentials via env vars or /etc/github-app/ files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=github-app-key.sh
source "${SCRIPT_DIR}/github-app-key.sh"

ENV_FILE_ONLY=0
[[ "${1:-}" == "--env-file" ]] && ENV_FILE_ONLY=1

_emit_token() {
    local token="$1"
    if [[ "$ENV_FILE_ONLY" -eq 1 ]]; then
        github_token_env_file "$token"
        printf '\n'
    else
        printf '%s' "$token"
    fi
}

TOKEN_FILE="/tmp/gh_token"
EXPIRY_FILE="/tmp/gh_token_expiry"

# Find github-app-iat.sh script
IAT_SCRIPT=""
for path in "${SCRIPT_DIR}/github-app-iat.sh" "/usr/local/bin/github-app-iat.sh"; do
    if [[ -f "$path" ]]; then
        IAT_SCRIPT="$path"
        break
    fi
done

if [[ -z "$IAT_SCRIPT" ]]; then
    # If no IAT script found, try to return cached token
    if [[ -f "$TOKEN_FILE" ]]; then
        _emit_token "$(cat "$TOKEN_FILE")"
        exit 0
    fi
    echo "Error: github-app-iat.sh not found" >&2
    exit 1
fi

# Check if cached token is still valid (more than 10 minutes remaining)
if [[ -f "$TOKEN_FILE" && -f "$EXPIRY_FILE" ]]; then
    expiry=$(cat "$EXPIRY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ $expiry -gt $((now + 600)) ]]; then
        _emit_token "$(cat "$TOKEN_FILE")"
        exit 0
    fi
fi

# Generate new token
token=$(bash "$IAT_SCRIPT" 2>/dev/null) || true

if [[ -n "$token" ]]; then
    # Save new token and expiry (1 hour from now)
    echo "$token" > "$TOKEN_FILE"
    echo "$(($(date +%s) + 3600))" > "$EXPIRY_FILE"
    chmod 600 "$TOKEN_FILE" "$EXPIRY_FILE" 2>/dev/null || true
    _emit_token "$token"
else
    # Token generation failed, try to return existing token as fallback
    if [[ -f "$TOKEN_FILE" ]]; then
        _emit_token "$(cat "$TOKEN_FILE")"
    else
        echo "Error: Failed to generate token and no cached token available" >&2
        exit 1
    fi
fi
