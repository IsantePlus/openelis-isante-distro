#!/usr/bin/env bash
# Adds OpenELIS to an already running OpenHIM (typically the LNSP stack) through its REST API.
#
# ADDITIVE: only what is listed in configs/openhim/openelis-openhim-import.json is created/updated:
#   - clients  OpenELIS, IsantePLUS
#   - channel  "central fhir server"  (route -> the mTLS fhir-gateway of this repo)
# No user, passport, mediator or other channel is sent, so the LNSP channels/clients and the
# OpenHIM root password are left untouched. Safe to re-run (records are updated in place).
#
# Usage:
#   OPENHIM_PASSWORD='...' ./scripts/import-openelis-into-openhim.sh
#
# Environment:
#   OPENHIM_API_URL   default https://localhost:8090  (API port published by the LNSP procedure)
#   OPENHIM_USER      default root@openhim.org
#   OPENHIM_PASSWORD  required
#   GATEWAY_HOST      default 172.20.1.1  (address of the fhir-gateway, see docker-compose.yml)
#   GATEWAY_PORT      default 8445
#   DRY_RUN=1         print the payload (secrets masked) and exit
# Requires: curl, jq. Credentials of the gateway come from configs/openelis/fhir-gateway/gateway.env
# (created by scripts/gen-fhir-gateway-htpasswd.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT="$ROOT/configs/openhim/openelis-openhim-import.json"
GW_ENV="$ROOT/configs/openelis/fhir-gateway/gateway.env"

OPENHIM_API_URL="${OPENHIM_API_URL:-https://localhost:8090}"
OPENHIM_USER="${OPENHIM_USER:-root@openhim.org}"
GATEWAY_HOST="${GATEWAY_HOST:-172.20.1.1}"
GATEWAY_PORT="${GATEWAY_PORT:-8445}"

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "'$bin' is required (sudo apt install $bin)" >&2; exit 1; }
done
[ -f "$FRAGMENT" ] || { echo "Missing $FRAGMENT" >&2; exit 1; }
[ -f "$GW_ENV" ] || { echo "Missing $GW_ENV: run ./scripts/gen-fhir-gateway-htpasswd.sh first" >&2; exit 1; }

# Read the file as data (never source it: the password may contain shell metacharacters)
FHIR_GW_USER="$(sed -n 's/^FHIR_GW_USER=//p' "$GW_ENV")"
FHIR_GW_PASSWORD="$(sed -n 's/^FHIR_GW_PASSWORD=//p' "$GW_ENV")"
[ -n "$FHIR_GW_USER" ] && [ -n "$FHIR_GW_PASSWORD" ] || { echo "Empty gateway credentials in $GW_ENV" >&2; exit 1; }

PAYLOAD="$(jq --arg h "$GATEWAY_HOST" --argjson p "$GATEWAY_PORT" \
              --arg u "$FHIR_GW_USER" --arg pw "$FHIR_GW_PASSWORD" \
  '.Channels[].routes[] |= (.host = $h | .port = $p | .username = $u | .password = $pw)' "$FRAGMENT")"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "$PAYLOAD" | jq '.Clients[] |= (.passwordHash = "***" | .passwordSalt = "***") | .Channels[].routes[].password = "***"'
  exit 0
fi

: "${OPENHIM_PASSWORD:?Set OPENHIM_PASSWORD (password of $OPENHIM_USER on the OpenHIM console)}"

# Keep the OpenHIM password out of the process list: give it to curl through stdin (-K -)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
curl_auth() { printf 'user = "%s:%s"\n' "$(esc "$OPENHIM_USER")" "$(esc "$OPENHIM_PASSWORD")" | curl -sk -K - "$@"; }

echo "OpenHIM API: $OPENHIM_API_URL  (user $OPENHIM_USER)"
code="$(curl_auth -o /dev/null -w '%{http_code}' "$OPENHIM_API_URL/channels" || true)"
case "$code" in
  200) ;;
  401) echo "Authentication refused by the OpenHIM API (HTTP 401): check OPENHIM_USER / OPENHIM_PASSWORD" >&2; exit 1 ;;
  *)   echo "OpenHIM API not reachable at $OPENHIM_API_URL (HTTP $code). Is port 8090 published? (see Install_LNSP: docker service update --publish-add 8090:8080 openhim_openhim-core)" >&2; exit 1 ;;
esac

# The payload contains the gateway password: private temp dir, removed on exit
umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s' "$PAYLOAD" > "$TMP/payload.json"
STATUS="$(curl_auth -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/payload.json" \
          -o "$TMP/response.json" -w '%{http_code}' "$OPENHIM_API_URL/metadata" || true)"
BODY="$(cat "$TMP/response.json" 2>/dev/null || true)"

if [ "$STATUS" != "201" ] && [ "$STATUS" != "200" ]; then
  echo "Import failed (HTTP $STATUS):" >&2; echo "$BODY" >&2; exit 1
fi
echo "$BODY" | jq -r '.[] | "  \(.model): \(.record.name // .record.clientID // "?") -> \(.status)\(if (.message // "") != "" then " (" + .message + ")" else "" end)"'
if echo "$BODY" | jq -e 'any(.[]; .status == "Error")' >/dev/null; then
  echo "At least one record could not be imported." >&2; exit 1
fi
echo "Done. Verify in the OpenHIM console: Channels > central fhir server; Clients > OpenELIS, IsantePLUS."
