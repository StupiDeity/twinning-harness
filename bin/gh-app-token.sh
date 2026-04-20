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

main() {
  printf 'TODO: mint token\n' >&2
  exit 99
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
