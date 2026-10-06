#!/usr/bin/env bash
# Creates the Basic Auth credentials shared by the FHIR gateway (nginx) and the OpenHIM channel.
#   ./scripts/gen-fhir-gateway-htpasswd.sh [user] [password]
# Defaults: user "openhim", random password. Writes:
#   configs/openelis/fhir-gateway/.htpasswd   hashed, mounted by the fhir-gateway container
#   configs/openelis/fhir-gateway/gateway.env plain, read by import-openelis-into-openhim.sh
# Both files are git-ignored. Run this BEFORE `docker compose up -d`.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../configs/openelis/fhir-gateway" && pwd)"
USER_NAME="${1:-openhim}"
PASSWORD="${2:-$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24)}"

case "$USER_NAME$PASSWORD" in
  *:*|*\'*|*\"*|*\ *) echo "user/password must not contain ':', quotes or spaces" >&2; exit 1 ;;
esac

# Docker creates a DIRECTORY when a bind-mounted file is missing: clean that up if it happened.
[ -d "$DIR/.htpasswd" ] && rm -rf "$DIR/.htpasswd"

printf '%s:%s\n' "$USER_NAME" "$(openssl passwd -apr1 "$PASSWORD")" > "$DIR/.htpasswd"
chmod 644 "$DIR/.htpasswd"   # read by the nginx worker user inside the container

umask 077
printf 'FHIR_GW_USER=%s\nFHIR_GW_PASSWORD=%s\n' "$USER_NAME" "$PASSWORD" > "$DIR/gateway.env"

echo "FHIR gateway credentials written to $DIR"
echo "  user:     $USER_NAME"
echo "  password: $PASSWORD"
