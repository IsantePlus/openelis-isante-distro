#!/usr/bin/env bash
# Assigns the "iSante ID" patient identifier (uuid 0e0c7cc2-3491-4675-b705-746e372ff346) to every
# patient of the site who already has a "Code ST" identifier (uuid d059f6d0-9e42-4760-8de1-8316b48bc5f1)
# but not yet an iSante ID at this location. The identifier is <iSanteSiteCode><4><patient_id>.
#
# Adapted from the reference script (iSantePlus2.8.5_LNSP/Install_LNSP, HUP-svr), parameterized so
# it can be reused for any site instead of a hardcoded location_id.
#
# Prerequisite: the site's location must have a location_attribute of type "iSanteSiteCode"
# (attribute_type_id=1). Without it the generated identifier is malformed (e.g. "NULL4123").
#
# Usage (idempotent — only inserts for patients who don't already have the identifier):
#   LOCATION_ID=856 MYSQL_PWD='...' ./set_isante_id.sh
# Cron (run from the server, replace LOCATION_ID/MYSQL_PWD):
#   */10 * * * * LOCATION_ID=856 MYSQL_PWD='...' /path/to/set_isante_id.sh >> /path/to/set_isante_id.log 2>&1
set -euo pipefail

: "${LOCATION_ID:?Set LOCATION_ID (location_id of the site, must have an iSanteSiteCode attribute)}"
[[ "$LOCATION_ID" =~ ^[0-9]+$ ]] || { echo "LOCATION_ID must be numeric" >&2; exit 1; }

MYSQL_CMD="${MYSQL_CMD:-mysql -u${MYSQL_USER:-root} ${MYSQL_DB:-openmrs}}"

CODE="$(printf 'SELECT value_reference FROM location_attribute WHERE attribute_type_id=1 AND location_id=%d AND voided=0 LIMIT 1;\n' "$LOCATION_ID" | eval "$MYSQL_CMD -N -B")"
if [ -z "$CODE" ]; then
  echo "No iSanteSiteCode (attribute_type_id=1) set for location_id=$LOCATION_ID — aborting, would generate malformed identifiers." >&2
  exit 1
fi

eval "$MYSQL_CMD" <<SQL
INSERT INTO patient_identifier(patient_id, identifier, identifier_type, location_id, creator, date_created, uuid)
SELECT patient_id,
    CONCAT('$CODE', 4, patient_id) AS identifier,
    (SELECT patient_identifier_type_id FROM patient_identifier_type WHERE uuid = '0e0c7cc2-3491-4675-b705-746e372ff346') AS identifier_type,
    $LOCATION_ID AS location_id,
    1 AS creator,
    NOW() AS date_created,
    UUID() AS uuid
FROM patient p
WHERE p.patient_id NOT IN (
        SELECT patient_id FROM patient_identifier
        WHERE identifier_type = (SELECT patient_identifier_type_id FROM patient_identifier_type WHERE uuid = '0e0c7cc2-3491-4675-b705-746e372ff346')
          AND location_id = $LOCATION_ID
    )
    AND p.patient_id IN (
        SELECT patient_id FROM patient_identifier
        WHERE identifier_type = (SELECT patient_identifier_type_id FROM patient_identifier_type WHERE uuid = 'd059f6d0-9e42-4760-8de1-8316b48bc5f1')
    );
SQL
echo "Done (site code $CODE, location_id $LOCATION_ID)."
