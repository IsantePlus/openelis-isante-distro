#!/usr/bin/env bash
# Preflight check for installing OpenELIS on an IsantePLUS server that already has the LNSP stack
# (isanteplus-local / Instant OpenHIE) installed. Run this BEFORE `docker compose up`.
#
# It only reads the system; it changes nothing. Each check prints PASS / FAIL / WARN with the
# exact fix. Exit code 0 = safe to proceed, 1 = blocked (at least one FAIL).
#
# Usage:
#   ./scripts/preflight-check.sh
#   MODULES_DIR=/path/to/.OpenMRS/modules ./scripts/preflight-check.sh   # if not the OpenMRS 2.x default
set -uo pipefail

# Default OpenMRS 2.x modules path. Some servers use "tomcat"/".OpenMRS" instead of "tomcat7"/
# ".OpenMRS" (case matters on Linux) — fall back to the alternate spelling if the first doesn't exist.
MODULES_DIR="${MODULES_DIR:-/usr/share/tomcat7/.OpenMRS/modules}"
[ -d "$MODULES_DIR" ] || MODULES_DIR="${MODULES_DIR:-/usr/share/tomcat/.OpenMRS/modules}"

# Ports docker-compose.yml publishes on the host for OpenELIS (proxy 443, webapp 8443, FHIR
# 8444, Postgres 15432, analyzer bridge 8442/12000). If one of these is already taken by a
# service that is NOT OpenELIS itself, `docker compose up` will fail to bind it.
REQUIRED_PORTS_FREE="443 8443 8444 15432 8442 12000"

# Rough comfort margins, not hard OpenELIS requirements: below these, the dozen-odd containers
# of the stack (webapp, FHIR, Postgres, frontend, proxy, analyzer bridge, gateway...) are likely
# to struggle or the Postgres data volume may run out of room over time.
MIN_FREE_RAM_MB=6000
MIN_FREE_DISK_GB=15

# Fixed by docker-compose.yml's `networks.openelis-network.ipam` block — not something this
# script or the installer chooses, just what the compose file already commits to.
GATEWAY_SUBNET="172.20.1.0/24"

FAIL=0
WARN=0
pass() { printf '  [OK]   %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         -> %s\n' "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  [WARN] %s\n' "$1"; [ $# -gt 1 ] && printf '         -> %s\n' "$2"; WARN=$((WARN+1)); }
section() { printf '\n%s\n' "$1"; }
# Cheap way to test "is something listening on this TCP port" without needing ss/nc installed:
# opening /dev/tcp/host/port is a bash builtin feature, connects if something is listening.
check_port_open() { # $1=port
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then exec 3<&- 3>&-; return 0; else return 1; fi
}

echo "============================================================"
echo " OpenELIS / LNSP preflight check"
echo " Read-only: this script does not install or change anything."
echo " It tells you what is missing before you run docker compose up."
echo "============================================================"

section "1. Docker"
echo "  Checking Docker Engine..."
if command -v docker >/dev/null 2>&1; then
  DV="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if [ -n "$DV" ]; then pass "Docker Engine $DV reachable"
  else fail "Docker is installed but the daemon is not reachable" "check 'sudo systemctl status docker', and that this user can run docker (sudo, or docker group)"; fi
else
  fail "Docker is not installed" "see Install_LNSP: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
fi

echo "  Checking Docker Compose version..."
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  CV="$(docker compose version --short 2>/dev/null)"
  case "$CV" in
    # Must be v2: docker-compose.yml uses "profiles:" (to keep the standalone OpenHIM optional)
    # and extra_hosts "host-gateway" (so the webapp can reach the host's OpenHIM) — both v2-only.
    2.*) pass "Docker Compose v2 ($CV)" ;;
    *) fail "Docker Compose version is '$CV', v2 is required" "this repo's docker-compose.yml uses 'profiles' and extra_hosts 'host-gateway', both v2-only" ;;
  esac
else
  fail "'docker compose' (v2 plugin) not found" "install docker-compose-plugin; the legacy 'docker-compose' (v1) is not enough"
fi

section "2. LNSP / OpenHIM stack (must already be installed — see the official LNSP procedure)"
# OpenELIS does NOT bring its own OpenHIM on this path: it is added as extra channels to the
# OpenHIM that the LNSP install already set up (see README "How the pieces are connected").
# So Swarm + the 3 ports below must already be live before OpenELIS is deployed.
echo "  Checking Docker Swarm..."
if command -v docker >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
  if sudo -n docker info 2>/dev/null | grep -q 'Swarm: active'; then pass "Docker Swarm is active"
  else fail "Docker Swarm is not active" "the LNSP OpenHIM package (isanteplus-local) requires Swarm — run its install procedure first"; fi
else
  warn "Cannot check Swarm state without sudo docker access" "run this script as a user who can 'sudo docker info', or check manually"
fi

echo "  Checking OpenHIM router (port 5001)..."
if check_port_open 5001; then pass "OpenHIM router responds on port 5001"
else fail "Nothing listening on port 5001 (OpenHIM router)" "the LNSP OpenHIM must be running before OpenELIS is added to it"; fi

echo "  Checking OpenHIM API (port 8090)..."
if check_port_open 8090; then
  # A real OpenHIM API answers 401 (auth required) or 200 here; anything else is probably some
  # other service that happens to use the same port, not actually OpenHIM.
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' -m 5 https://localhost:8090/channels 2>/dev/null)"
  if [ "$CODE" = "401" ] || [ "$CODE" = "200" ]; then pass "OpenHIM API responds on port 8090 (HTTP $CODE)"
  else warn "Port 8090 is open but did not respond like the OpenHIM API (HTTP $CODE)" "double-check this is really the LNSP OpenHIM and not another service"; fi
else
  fail "Nothing listening on port 8090 (OpenHIM API)" "needed by scripts/import-openelis-into-openhim.sh"
fi

echo "  Checking OpenHIM console (port 80)..."
if check_port_open 80; then pass "OpenHIM console reachable on port 80"
else warn "Nothing listening on port 80 (OpenHIM console)" "not required to run OpenELIS, but you won't be able to check the console at http://<server>"; fi

section "3. iSantePlus modules required by OpenELIS (folder: $MODULES_DIR)"
# These 3 modules are what let iSantePlus talk FHIR to OpenELIS (labonfhir/fhir2) and format
# lab orders for LNSP (labintegration). If the LNSP install procedure's "delete all .omod, copy
# the LNSP set" step was followed literally, these get wiped — see README's note to skip that step.
echo "  Checking for labonfhir, fhir2, labintegration..."
if [ -d "$MODULES_DIR" ]; then
  for m in labonfhir fhir2 labintegration; do
    if ls "$MODULES_DIR/$m"-*.omod >/dev/null 2>&1; then
      pass "$m: $(basename "$(ls "$MODULES_DIR/$m"-*.omod | head -1)")"
    else
      fail "$m module not found in $MODULES_DIR" "copy it from configs/isanteplus/custom_modules/ and restart Tomcat"
    fi
  done
else
  warn "Modules folder not found at $MODULES_DIR" "set MODULES_DIR=<path> and re-run, or check the 3 modules (labonfhir, fhir2, labintegration) by hand"
fi

section "4. Ports OpenELIS needs to publish"
echo "  Checking $REQUIRED_PORTS_FREE ..."
for p in $REQUIRED_PORTS_FREE; do
  # WARN, not FAIL: if OpenELIS is already installed here (a re-run of this check), these ports
  # are legitimately "in use" by OpenELIS's own containers — that's not a real problem.
  if check_port_open "$p"; then warn "Port $p is already in use" "check what's using it (sudo ss -tlnp | grep :$p) — OpenELIS needs it free unless this is a re-run of OpenELIS itself"
  else pass "Port $p is free"; fi
done

section "5. Resources"
echo "  Checking available RAM and disk..."
FREE_RAM_MB="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
if [ -n "${FREE_RAM_MB:-}" ]; then
  if [ "$FREE_RAM_MB" -ge "$MIN_FREE_RAM_MB" ]; then pass "RAM available: ${FREE_RAM_MB} MB"
  else warn "Only ${FREE_RAM_MB} MB RAM available (recommended >= ${MIN_FREE_RAM_MB} MB)" "the OpenELIS stack is about a dozen containers; consider freeing memory first"; fi
else
  warn "Could not read available RAM" ""
fi
FREE_DISK_GB="$(df -Pk / 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')"
if [ -n "${FREE_DISK_GB:-}" ]; then
  if [ "$FREE_DISK_GB" -ge "$MIN_FREE_DISK_GB" ]; then pass "Disk free on /: ${FREE_DISK_GB} GB"
  else warn "Only ${FREE_DISK_GB} GB free on / (recommended >= ${MIN_FREE_DISK_GB} GB)" "OpenELIS images + Postgres data need room to grow"; fi
fi

section "6. Docker network"
echo "  Checking whether $GATEWAY_SUBNET is free..."
if command -v docker >/dev/null 2>&1 && sudo -n docker network ls >/dev/null 2>&1; then
  # Walk existing networks looking for one that already claims this subnet. If it's
  # "openelis-network" itself, this is just a re-run against an existing OpenELIS install — fine.
  # If it's any OTHER network, docker-compose.yml's ipam block will fail to create the subnet.
  OWNER="$(sudo -n docker network ls --format '{{.Name}}' | while read -r n; do
    sudo -n docker network inspect "$n" 2>/dev/null | grep -q "\"Subnet\": \"$GATEWAY_SUBNET\"" && echo "$n" && break
  done)"
  if [ "$OWNER" = "openelis-network" ]; then
    pass "Subnet $GATEWAY_SUBNET already used by openelis-network (this is a re-deployment of OpenELIS itself)"
  elif [ -n "$OWNER" ]; then
    fail "Subnet $GATEWAY_SUBNET is already used by another Docker network ('$OWNER')" "openelis-network needs this subnet (see docker-compose.yml); free it or change the subnet in docker-compose.yml"
  else
    pass "Subnet $GATEWAY_SUBNET is free for openelis-network"
  fi
else
  warn "Cannot check Docker networks without sudo docker access" ""
fi

echo
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  echo "READY: no blocking issue found ($WARN warning(s)). You can run: docker compose up -d"
  exit 0
else
  echo "NOT READY: $FAIL blocking issue(s), $WARN warning(s). Fix the [FAIL] items above before running docker compose up."
  exit 1
fi
