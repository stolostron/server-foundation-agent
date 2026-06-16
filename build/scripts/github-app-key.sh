#!/usr/bin/env bash
# Shared helpers for GitHub App PEM keys from env vars / Kubernetes secrets.
# Source from github-app-iat.sh and setup-github-app-auth.sh — do not execute directly.

# Normalize PEM private key (Swarmer envFrom and single-line secrets often use literal \n).
normalize_github_app_private_key() {
  local key="${1:-${GH_APP_PRIVATE_KEY:-}}"
  if [[ -z "$key" ]]; then
    return 1
  fi

  # Single-line PEM with literal backslash-n sequences
  if [[ "$key" != *$'\n'* ]] && [[ "$key" == *-----BEGIN* ]]; then
    key=$(printf '%b' "$key")
  fi

  # Whole-key base64 wrapper (some secret managers)
  if [[ ! "$key" =~ ^-----BEGIN ]]; then
    local decoded=""
    decoded=$(printf '%s' "$key" | openssl base64 -d -A 2>/dev/null) || decoded=""
    if [[ "$decoded" =~ ^-----BEGIN ]]; then
      key="$decoded"
    fi
  fi

  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  printf '%s' "$key"
}

# True when normalized key looks like PEM.
is_valid_github_app_pem_key() {
  local key=""
  key=$(normalize_github_app_private_key "${1:-}") || return 1
  [[ "$key" =~ ^-----BEGIN.*PRIVATE\ KEY----- ]]
}

# RS256 sign with openssl; prints binary signature to stdout.
sign_rs256_with_pem_key() {
  local data="$1"
  local key="${2:-}"
  local normalized keyfile
  normalized=$(normalize_github_app_private_key "$key") || return 1
  keyfile=$(mktemp)
  printf '%s' "$normalized" > "$keyfile"
  chmod 600 "$keyfile"
  printf '%s' "$data" | openssl dgst -binary -sha256 -sign "$keyfile"
  local rc=$?
  rm -f "$keyfile"
  return $rc
}

# Write GH_TOKEN/GITHUB_TOKEN to a chmod-600 file; print path to stdout (never the token).
github_token_env_file() {
  local token="$1"
  local file
  file=$(mktemp "${TMPDIR:-/tmp}/gh_token_env.XXXXXX") || return 1
  chmod 600 "$file"
  {
    printf 'export GH_TOKEN=%q\n' "$token"
    printf 'export GITHUB_TOKEN=%q\n' "$token"
  } > "$file"
  printf '%s' "$file"
}
