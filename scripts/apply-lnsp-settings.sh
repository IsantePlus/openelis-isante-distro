#!/usr/bin/env bash
# Applies the iSantePlus-side LNSP settings (xds-sender, labintegration, reports) listed in
# configs/isanteplus/lnsp/lnsp-settings.tsv to the OpenMRS database (table global_property).
#
# DRY RUN by default: only SELECTs, it shows what would change. Set APPLY=1 to write.
# Only the properties listed in the .tsv are touched; nothing is deleted.
#
# Usage, on the IsantePLUS server:
#   CLIENT_ID=HUP CLIENT_PASSWORD='...' MYSQL_PWD='...' ./scripts/apply-lnsp-settings.sh            # dry run
#   CLIENT_ID=HUP CLIENT_PASSWORD='...' MYSQL_PWD='...' APPLY=1 ./scripts/apply-lnsp-settings.sh    # apply
#
# Environment:
#   CLIENT_ID               required. OpenHIM client of the site = facility acronym (e.g. HUP)
#   CLIENT_PASSWORD         optional. Its password (same in the local and in the central OpenHIM).
#                           The 3 password settings are skipped when unset.
#   OPENMRS_ADMIN_PASSWORD  optional. Password of the OpenMRS "admin" used by xds-sender (skipped when unset)
#   MYSQL_USER (root), MYSQL_DB (openmrs), MYSQL_PWD (MySQL password)
#   MYSQL_CMD               command that reads SQL on stdin and prints tab-separated rows (-N -B).
#                           Default: mysql -u$MYSQL_USER $MYSQL_DB -N -B
#   SETTINGS_FILE           alternative settings table
# Passwords are never printed: they are compared through their SHA-256 and shown as [secret].
# Requires bash >= 4, od, sha256sum (or openssl) and the mysql client.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${SETTINGS_FILE:-$ROOT/configs/isanteplus/lnsp/lnsp-settings.tsv}"

: "${CLIENT_ID:?Set CLIENT_ID (OpenHIM client of the site = facility acronym, e.g. HUP)}"
case "$CLIENT_ID" in *[!A-Za-z0-9_.-]*) echo "CLIENT_ID may only contain letters, digits, '_', '.' and '-'" >&2; exit 1 ;; esac
[ -f "$SETTINGS" ] || { echo "Missing $SETTINGS" >&2; exit 1; }

MYSQL_CMD="${MYSQL_CMD:-mysql -u${MYSQL_USER:-root} ${MYSQL_DB:-openmrs} -N -B}"
run_sql() { eval "$MYSQL_CMD"; }   # reads SQL on stdin

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else openssl dgst -sha256 | awk '{print $NF}'; fi; }
hex()    { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }   # values travel as hex: no quoting issue possible

PROPS=(); VALS=(); SKIPPED=()
while IFS=$'\t' read -r prop val || [ -n "$prop" ]; do
  prop="${prop%$'\r'}"; val="${val%$'\r'}"
  case "$prop" in ''|'#'*) continue ;; esac
  [[ "$prop" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Invalid property name in $SETTINGS: $prop" >&2; exit 1; }
  case "$val" in
    @CLIENT_ID@) val="$CLIENT_ID" ;;
    @CLIENT_PASSWORD@)
      [ -n "${CLIENT_PASSWORD:-}" ] || { SKIPPED+=("$prop (CLIENT_PASSWORD not set)"); continue; }
      val="$CLIENT_PASSWORD" ;;
    @OPENMRS_ADMIN_PASSWORD@)
      [ -n "${OPENMRS_ADMIN_PASSWORD:-}" ] || { SKIPPED+=("$prop (OPENMRS_ADMIN_PASSWORD not set)"); continue; }
      val="$OPENMRS_ADMIN_PASSWORD" ;;
  esac
  PROPS+=("$prop"); VALS+=("$val")
done < "$SETTINGS"

is_secret() { [[ "$1" == *[Pp]assword* ]]; }

NAMES=""; for p in "${PROPS[@]}"; do NAMES+="'$p',"; done; NAMES="${NAMES%,}"

declare -A CUR_HASH CUR_VAL ACTION
TODO=()
evaluate() {   # reads the current values, fills ACTION[] and TODO[]
  CUR_HASH=(); CUR_VAL=(); ACTION=(); TODO=()
  local sql out prop kind disp hash i new_hash
  # The display column is LAST: it is empty for secrets, and consecutive tabs would otherwise be
  # merged by read and shift the hash.
  sql="SELECT property, IF(property LIKE '%assword%','S','V'), IFNULL(SHA2(property_value,256),'<NULL>'), IF(property LIKE '%assword%','',IFNULL(property_value,'<NULL>')) FROM global_property WHERE property IN ($NAMES);"
  out="$(printf '%s\n' "$sql" | run_sql)"
  while IFS=$'\t' read -r prop kind hash disp; do
    [ -n "$prop" ] || continue
    CUR_VAL["$prop"]="$disp"; CUR_HASH["$prop"]="$hash"
  done <<< "$out"
  for i in "${!PROPS[@]}"; do
    prop="${PROPS[$i]}"; new_hash="$(printf '%s' "${VALS[$i]}" | sha256)"
    if [ -z "${CUR_HASH[$prop]+x}" ]; then ACTION["$prop"]=ADD; TODO+=("$i")
    elif [ "${CUR_HASH[$prop]}" = "$new_hash" ]; then ACTION["$prop"]=SAME
    else ACTION["$prop"]=CHANGE; TODO+=("$i"); fi
  done
}

echo "Target: $(printf 'SELECT CONCAT(@@hostname," / database ",DATABASE()," / MySQL ",VERSION());\n' | run_sql)"
echo "Settings: $SETTINGS  (client id: $CLIENT_ID)"
echo
evaluate

same=0
for i in "${!PROPS[@]}"; do
  prop="${PROPS[$i]}"
  case "${ACTION[$prop]}" in
    SAME) same=$((same + 1)) ;;
    ADD)
      if is_secret "$prop"; then echo "  + ADD    $prop = [secret]"; else echo "  + ADD    $prop = ${VALS[$i]}"; fi ;;
    CHANGE)
      if is_secret "$prop"; then echo "  ~ CHANGE $prop: [secret] -> [secret]"
      else echo "  ~ CHANGE $prop: ${CUR_VAL[$prop]} -> ${VALS[$i]}"; fi ;;
  esac
done
if [ "${#SKIPPED[@]}" -gt 0 ]; then for s in "${SKIPPED[@]}"; do echo "  - SKIP   $s"; done; fi
echo
echo "$same already up to date, ${#TODO[@]} to change/add, ${#SKIPPED[@]} skipped."

if [ "${#TODO[@]}" -eq 0 ]; then echo "Nothing to do."; exit 0; fi
if [ "${APPLY:-0}" != "1" ]; then
  echo "Dry run: nothing was written. Re-run with APPLY=1 to apply the changes above."
  exit 0
fi

rows=""
for i in "${TODO[@]}"; do
  rows+="(CONVERT(UNHEX('$(hex "${PROPS[$i]}")') USING utf8),CONVERT(UNHEX('$(hex "${VALS[$i]}")') USING utf8),UUID()),"
done
printf 'INSERT INTO global_property (property, property_value, uuid) VALUES %s ON DUPLICATE KEY UPDATE property_value = VALUES(property_value);\n' "${rows%,}" | run_sql

evaluate
if [ "${#TODO[@]}" -eq 0 ]; then
  echo "Applied and verified: all listed settings now match."
else
  echo "WARNING: ${#TODO[@]} setting(s) still differ after the update." >&2; exit 1
fi
echo "Restart Tomcat so that the modules and the scheduler pick up the new values (sudo service tomcat7 restart)."
