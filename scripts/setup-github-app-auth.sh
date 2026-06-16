#!/usr/bin/env bash
# Export GH_TOKEN / GITHUB_TOKEN from GitHub App credentials.
#
# Usage:
#   source "$(bash scripts/setup-github-app-auth.sh --export)"
#   bash scripts/setup-github-app-auth.sh && gh pr view ...
#
# --export writes token vars to a chmod-600 temp file and prints its path only (no token on stdout).
#
# Credentials: GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY (env or /etc/github-app/)
# Optional: clone server-foundation-agent under /workspace for script-based path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../build/scripts/github-app-key.sh
source "${SCRIPT_DIR}/../build/scripts/github-app-key.sh"

EXPORT_ONLY=0
[[ "${1:-}" == "--export" ]] && EXPORT_ONLY=1

_b64url() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

_generate_iat_inline() {
  local app_id="${GH_APP_ID:?GH_APP_ID required}"
  local install_id="${GH_APP_INSTALLATION_ID:?GH_APP_INSTALLATION_ID required}"
  local private_key
  private_key=$(normalize_github_app_private_key "${GH_APP_PRIVATE_KEY:?GH_APP_PRIVATE_KEY required}")
  local now iat exp header payload unsigned sig jwt body http_code token

  now=$(date +%s)
  iat=$((now - 60))
  exp=$((now + 540))

  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id")
  header=$(printf '%s' "$header" | _b64url)
  payload=$(printf '%s' "$payload" | _b64url)
  unsigned="${header}.${payload}"
  sig=$(sign_rs256_with_pem_key "$unsigned" "$private_key" | _b64url)
  jwt="${unsigned}.${sig}"

  body=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/${install_id}/access_tokens")
  http_code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')

  if [[ "$http_code" != "201" ]]; then
    echo "setup-github-app-auth: IAT request failed (HTTP ${http_code}): $(echo "$body" | jq -r '.message // .' 2>/dev/null || echo "$body")" >&2
    return 1
  fi

  token=$(echo "$body" | jq -r '.token')
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "setup-github-app-auth: failed to parse IAT" >&2
    return 1
  fi
  printf '%s' "$token"
}

_find_token_manager() {
  local candidate found
  for candidate in \
    "/workspace/server-foundation-agent" \
    "/workspace" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"; do
    [[ -f "${candidate}/build/scripts/github-token-manager.sh" ]] || continue
    printf '%s/build/scripts/github-token-manager.sh' "$candidate"
    return 0
  done
  found="$(find /workspace -path '*/build/scripts/github-token-manager.sh' 2>/dev/null | head -1 || true)"
  [[ -n "$found" ]] && printf '%s' "$found" && return 0
  return 1
}

_load_app_creds_from_files() {
  local dir="${GITHUB_APP_DIR:-/etc/github-app}"
  [[ -z "${GH_APP_ID:-}" && -f "${dir}/client_id" ]] && GH_APP_ID=$(cat "${dir}/client_id")
  [[ -z "${GH_APP_INSTALLATION_ID:-}" && -f "${dir}/installation_id" ]] && GH_APP_INSTALLATION_ID=$(cat "${dir}/installation_id")
  [[ -z "${GH_APP_PRIVATE_KEY:-}" && -f "${dir}/private_key" ]] && GH_APP_PRIVATE_KEY=$(cat "${dir}/private_key")
  export GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY
}

if [[ -n "${GH_TOKEN:-}" ]]; then
  if [[ "$EXPORT_ONLY" -eq 1 ]]; then
    github_token_env_file "$GH_TOKEN"
    printf '\n'
  fi
  exit 0
fi

_load_app_creds_from_files

if [[ -z "${GH_APP_ID:-}" || -z "${GH_APP_INSTALLATION_ID:-}" || -z "${GH_APP_PRIVATE_KEY:-}" ]]; then
  echo "setup-github-app-auth: set GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY (or mount /etc/github-app/)" >&2
  exit 1
fi

GH_APP_PRIVATE_KEY=$(normalize_github_app_private_key "$GH_APP_PRIVATE_KEY")
export GH_APP_PRIVATE_KEY
if ! is_valid_github_app_pem_key "$GH_APP_PRIVATE_KEY"; then
  echo "setup-github-app-auth: GH_APP_PRIVATE_KEY is not a valid PEM key (check newlines in swarmer-agent-extra-env)" >&2
  exit 1
fi

if ! command -v openssl >/dev/null || ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
  echo "setup-github-app-auth: requires openssl, jq, and curl in the agent container" >&2
  echo "setup-github-app-auth: rebuild AGENT_IMAGE_CRUSH with openssl, or use build/Dockerfile from server-foundation-agent" >&2
  exit 1
fi

token=""
if mgr="$(_find_token_manager 2>/dev/null)"; then
  token="$(bash "$mgr")" || token=""
fi
if [[ -z "$token" ]]; then
  token="$(_generate_iat_inline)"
fi

export GITHUB_TOKEN="$token"
export GH_TOKEN="$token"
if command -v git >/dev/null; then
  _cred_helper=""
  for _p in "${SCRIPT_DIR}/../build/scripts/git-credential-github-app.sh" \
            "/usr/local/bin/git-credential-github-app.sh"; do
    [[ -x "$_p" ]] && _cred_helper="$_p" && break
  done
  if [[ -n "$_cred_helper" ]]; then
    git config --global credential.helper "$_cred_helper" 2>/dev/null || true
  fi
fi

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  github_token_env_file "$GH_TOKEN"
  printf '\n'
  exit 0
fi

echo "setup-github-app-auth: OK" >&2
