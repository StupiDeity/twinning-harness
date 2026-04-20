#!/usr/bin/env bash
# Mint a GitHub App installation token from a private key.
# Usage: export GITHUB_TOKEN=$(bash .pipeline/bin/gh-app-token.sh)
#
# Reads:
#   GH_APP_ID                 — numeric App ID (github.com/settings/apps/<app>/permissions)
#   GH_APP_INSTALLATION_ID    — numeric installation ID
#   GH_APP_PRIVATE_KEY_PATH   — path to the .pem private key (chmod 600)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_env GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY_PATH
require_bin openssl curl jq

# Expand ~ in the key path since env vars don't expand tildes.
KEY_PATH="${GH_APP_PRIVATE_KEY_PATH/#\~/$HOME}"
[[ -r "$KEY_PATH" ]] || die "private key not readable: $KEY_PATH"

b64url() {
  # Base64url: standard base64, then replace +/= → -_(stripped).
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

mint_jwt() {
  local now iat exp header payload signing_input signature
  now="$(date +%s)"
  # iat deliberately set 60s in the past to absorb client↔GitHub clock skew
  # (per GitHub App JWT guidance).
  iat="$((now - 60))"
  exp="$((now + 540))"  # 9 min; GH allows up to 10.
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GH_APP_ID" | b64url)"
  signing_input="${header}.${payload}"
  signature="$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign "$KEY_PATH" \
    | b64url)"
  printf '%s.%s' "$signing_input" "$signature"
}

main() {
  local jwt response token
  jwt="$(mint_jwt)"
  response="$(curl -sS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens")"

  token="$(jq -r '.token // empty' <<<"$response" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    die "token exchange failed: $(jq -c '{message, documentation_url, status}' <<<"$response" 2>/dev/null || printf '%s' "$response")"
  fi
  printf '%s\n' "$token"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
