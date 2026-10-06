# openelis-isante-distro

OpenELIS (LIS) set up to work with IsantePLUS. On an IsantePLUS server the **OpenHIM is the one installed by the LNSP procedure** (`isanteplus-local`, Docker Swarm). This repo runs OpenELIS only and **adds** OpenELIS to that OpenHIM as extra channels, without touching the LNSP channels or configuration.

## How the pieces are connected

```
IsantePLUS (Tomcat)
  ├─ labonfhir  ──► OpenHIM :5001  /fhir/          ──► fhir-gateway (172.20.1.1:8445) ──mTLS──► OpenELIS FHIR server
  └─ xds-sender ──► OpenHIM :5001  /xdsrepository  ──► SEDISH (LNSP workflow, unchanged)
OpenELIS webapp  ──► OpenHIM :5001  /fhir/  (via host.docker.internal)
```

* The OpenELIS FHIR server only accepts **mutual TLS**. The `fhir-gateway` container (nginx, defined in [`docker-compose.yml`](./docker-compose.yml)) exposes it as HTTP + Basic Auth to the OpenHIM and presents the client certificate itself, so **no certificate has to be installed in the LNSP OpenHIM**.
* The gateway is published on `172.20.1.1:8445` (the gateway address of `openelis-network`): reachable from the host and from local containers (the OpenHIM Swarm tasks), **not from the LAN**.

## Quick summary for installers

Adding OpenELIS to a site that already has a working LNSP install is **5 commands**:

1. `./scripts/preflight-check.sh`
2. `./scripts/gen-fhir-gateway-htpasswd.sh`
3. `docker compose up -d`
4. `./scripts/import-openelis-into-openhim.sh`
5. the 3 verification `curl`/`docker exec` commands in step 4 below

That's it for OpenELIS itself. The **"LNSP workflow settings"** section further down (`apply-lnsp-settings.sh`, `set_isante_id.sh`) is a **separate, optional** part: only needed if this particular site's `xds-sender`/`labintegration` configuration is missing or wrong (that was the case on the DEMO5 test server, not something every site has). A site where LNSP was installed and configured correctly from the start does not need it — skip straight to "Instructions for Running this OpenELIS Setup" below.

## Before you start: preflight check

```
./scripts/preflight-check.sh
```

Run this on the server before doing anything else. It only reads the system (nothing is changed) and checks everything in the Prerequisites section below automatically: Docker/Compose version, that the LNSP OpenHIM is really running, the 3 required IsantePLUS modules, free ports, RAM/disk, and Docker network conflicts. It prints `[FAIL]`/`[WARN]`/`[OK]` for each item with the exact fix, and exits non-zero if anything blocks the install — safe to run again after fixing an item, and safe to run again after OpenELIS is already installed (a re-run is recognized and does not report false failures).

## Prerequisites

1. The **LNSP stack is installed** (`Install_LNSP`, `isanteplus-local`): the OpenHIM console (80), its API (8090) and the router (5001) are published on the server.
   * **Skip step 1 of the LNSP procedure**: it deletes *all* `.omod` files and installs its own set, which would remove modules that must stay (for example `labonfhir`, required by OpenELIS). Only **add the LNSP modules that are missing** and keep everything else: compare the versions of the LNSP module set with the installed ones (modules folder: `/usr/share/tomcat7/.OpenMRS/modules/` on DEMO5). The modules configured by the LNSP procedure are `xds-sender`, `outgoing-message-exceptions`, `labintegration` and `isanteplusreports` (module version `1.1-SNAPSHOT`), plus `fhir2`; on a server that is already prepared they are usually all present.
2. Docker Engine with Compose v2 (needed for `host-gateway` and profiles), plus `jq`, `curl` and `openssl` on the host.
3. This machine **must not still run the OpenHIM containers of the previous version of this repo** (`openhim-core`, `openhim-console`, `openhim-mongo`, `openhim-config`): they hold ports 5001/9000 and would clash with the LNSP OpenHIM. Remove them first: `docker rm -f openhim-core openhim-console openhim-mongo openhim-config`.

## Instructions for Running this OpenELIS Setup

Clone the repo

    git clone https://github.com/IsantePlus/openelis-isante-distro.git
    cd openelis-isante-distro

**1. Create the credentials shared by the FHIR gateway and the OpenHIM channel** (must be done *before* `docker compose up`):

```
./scripts/gen-fhir-gateway-htpasswd.sh            # random password, or: ... <user> <password>
```

**2. Start OpenELIS** (the OpenHIM is *not* started here: it comes from the LNSP stack):

```
docker compose up -d
```

**3. Add OpenELIS to the LNSP OpenHIM** (clients `OpenELIS` and `IsantePLUS`, channel `central fhir server`). The script only creates/updates those records: LNSP channels, clients, users and the root password are left as they are. It can be re-run safely.

```
OPENHIM_PASSWORD='<password of root@openhim.org on the OpenHIM console>' ./scripts/import-openelis-into-openhim.sh
```

Defaults: API `https://localhost:8090`, user `root@openhim.org`, gateway `172.20.1.1:8445` (override with `OPENHIM_API_URL`, `OPENHIM_USER`, `GATEWAY_HOST`, `GATEWAY_PORT`; `DRY_RUN=1` prints the payload without sending it).

**4. Check the whole chain from the host** (`OpenELIS:admin` is the OpenHIM client of OpenELIS, see [`configs/openhim/openelis-openhim-import.json`](./configs/openhim/openelis-openhim-import.json)):

```
curl -s -o /dev/null -w '%{http_code}\n' -u OpenELIS:admin http://localhost:5001/fhir/metadata    # 200 = host -> OpenHIM -> gateway -> FHIR
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5001/fhir/metadata                       # 401 = authentication required
```

And that the OpenELIS webapp reaches the OpenHIM (`401` = reachable, authentication required):

```
docker exec openelisglobal-webapp curl -s -o /dev/null -w '%{http_code}\n' http://host.docker.internal:5001/fhir/metadata
```

Access the services at

| Instance  |     URL       | credentials (user : password)|
|---------- |:-------------:|------:                       |
| OpenELIS3 | https://localhost/ |    admin : adminADMIN!|
| OpenHIM (LNSP stack) |    http://localhost/ or http://localhost:9000/  |  set during the LNSP installation |

Both are self-signed/plain HTTP on purpose (internal network); your browser will warn about the OpenELIS certificate, that is expected. The LNSP OpenHIM console is published on plain port 80 by the platform package itself; port 9000 only exists if the optional "Forward the following ports" step of the LNSP procedure was done (`docker service update --publish-add 9000:80 openhim_openhim-console`) — do that if this site is missing it and other sites use `:9000` out of habit. **No application traffic uses either port**: orders/results go through the router (5001), and scripts go through the API (8090) — 80/9000 are the human-facing console only, so this never affects xds-sender, labonfhir or OpenELIS.

### Troubleshooting

* `docker compose up` fails on the `fhir-gateway` mount, or the container says `.htpasswd is a directory`: run step 1 first (Docker creates a directory when a bind-mounted file is missing), then `rm -rf configs/openelis/fhir-gateway/.htpasswd` if it exists as a directory and re-run the script.
* The host check in step 4 returns `502`/`504`: the OpenHIM (Swarm task) cannot reach `172.20.1.1:8445`. Check `docker logs openelis-fhir-gateway`, and that a host firewall (`ufw`) is not blocking traffic from the Docker networks to that address.
* OpenELIS cannot reach the OpenHIM (`common.properties` uses `OPENHIM_FHIR_URL`, default `http://host.docker.internal:5001/fhir/`): set `OPENHIM_FHIR_URL` in `.env` (for example to `http://<server ip>:5001/fhir/`) and run `docker compose up -d` again.
* `docker compose up` on a machine that already ran the previous version leaves the old OpenHIM containers running: see prerequisite 3.
* `https://<server>/` briefly returns `502`, or OpenELIS shows a "System Error" / `JSON.parse` error right after a `frontend.openelis.org` or `oe.openelis.org` container restarts: this is expected for a few seconds — `nginx.conf` re-resolves those upstreams per request (`resolver 127.0.0.11`) instead of only at startup, so the proxy itself survives and recovers on its own once the container is back, instead of crash-looping. If it does **not** clear up within ~15s, check `docker ps` for `openelisglobal-front-end` / `openelisglobal-webapp` (should auto-restart, `restart: always`) and `docker logs openelisglobal-proxy`.
* An order sent from IsantePLUS to OpenELIS goes through fine, but the **result never comes back** to the lab form: `OpenELIS Pull Task` on the IsantePLUS side almost certainly stopped — see the warning under "Instructions for Connecting IsantePLUS To OpenELIS Through OpenHIM" step "To Fetch back the Test Results..." above. This is the single most common cause and the first thing to check, before looking at LOINC mapping or OpenHIM channels.

### Standalone mode (laptop / demo without the LNSP stack)

The former all-in-one behaviour is kept behind a Compose profile: it starts OpenELIS **and its own OpenHIM** (Mongo, core, console, config loader).

```
docker compose --profile standalone-openhim up -d
```

> **Note (remote deployments):** If you are running this setup on a remote machine rather than `localhost`, update the OpenELIS IP address in the OpenHIM Console config [`configs/openhim/configs/default.json`](./configs/openhim/configs/default.json) by setting the `host` field to your server's IP address or hostname (e.g. `"host": "10.0.0.5"`). Leave it as `localhost` only when running locally.

The standalone OpenHIM console is at `http://localhost:9000/` (`root@openhim.org` : `openhim`). Do **not** use this mode on a server that runs the LNSP stack (same ports, second OpenHIM).

## Instructions for Connecting IsantePLUS To OpenELIS Through OpenHIM

1. Ensure IsantePLUS is running. 
1. Add/Upgrade the following [modules](./configs/isanteplus/custom_modules/) to the IsantePLUS server

Note: these modules can be built from their corresponding repositories using the commands below. After each build, the resulting `.omod` artifact can be found in the module's `omod/target/` directory and should be copied into the IsantePLUS server's `modules` directory (or uploaded via the Admin UI).

1. **Lab on FHIR**

   ```bash
   git clone https://github.com/openmrs/openmrs-module-labonfhir.git -b platform_2.0.5
   cd openmrs-module-labonfhir
   mvn clean install
   ```

2. **FHIR2 Module**

   ```bash
   git clone https://github.com/openmrs/openmrs-module-fhir2.git -b 1.11.0
   cd openmrs-module-fhir2
   mvn clean install
   ```

3. **iSantePlus**

   ```bash
   git clone https://github.com/charess-org/iSantePlus.git -b main
   cd iSantePlus
   mvn clean install
   ```

4. **Lab Integration**

   ```bash
   git clone https://github.com/IsantePlus/openmrs-module-labintegration.git
   cd openmrs-module-labintegration
   mvn clean install
   ```

1. On the IsantePLUS server (Tomcat runs directly on the host), create the directory `/openmrs/concepts_update` and put this [concepts file](./configs/isanteplus/concepts_update/concepts.csv) there in oder to update the Lab Tests with the missing Concepts

    ```bash
    sudo mkdir -p /openmrs/concepts_update
    sudo cp configs/isanteplus/concepts_update/concepts.csv /openmrs/concepts_update/
    sudo chown -R tomcat:tomcat /openmrs/concepts_update
    sudo systemctl restart tomcat
    ```

    Only mount `./configs/isanteplus/concepts_update:/openmrs/concepts_update` if you are running IsantePLUS from the commented-out containers in [`docker-compose.yml`](./docker-compose.yml).

    See [**Configuration Instructions**](./CONFIG_INSTRUCTIONS.md) for how to add or edit rows in this file.

1. Ensure these Global properties are rightly set in IsatePlus as below

    ### LabOnFHIR Global Properties

    #### Integration / LIS Connectivity

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.lisUrl` | The URL for an LIS system like OpenELIS system to communicate with | `http://localhost:5001/fhir/` |
    | `labonfhir.lisUserUuid` | UUID for the service user that represents a LIS like OpenELIS | `f9badd80-ab76-11e2-9e96-0800200c9a66` |
    | `labonfhir.activateFhirPush` | Switches on/off the FHIR Push Functionality within the module to an external LIS | `true` |
    | `labonfhir.authType` | HTTP Auth Type (Basic / SSL) | `Basic` |
    | `labonfhir.userName` | User name for HTTP Basic Auth with the LIS | `IsantePLUS` |
    | `labonfhir.password` | Password for HTTP Basic Auth with the LIS | `admin` |
   
    

    ---

    #### SSL Configuration (needed In case AuthType is set to SSL)

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.keystorePath` | Path to keystore for HttpClient | `/ssl/lf.keystore` |
    | `labonfhir.keystorePass` | Keystore password | `testtest` |
    | `labonfhir.truststorePath` | Path to truststore for HttpClient | `/ssl/lf.truststore` |
    | `labonfhir.truststorePass` | Truststore password | `testtest` |

    ---

    #### Patient & Identifier Configuration

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.openmrsPatientIdentifier.uuid` | Patient Identifier used to generate the FHIR Identifier System | `05a29f94-c0ed-11e2-94be-8c13b969e334` |
    | `labonfhir.lisIdentifierSystem.url` | LIS Identifier System URL | `http://openelis-global.org/pat_nationalId` |

    ---

    #### Order & Workflow Configuration

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.orderTestUuids` | Concept UUIDs to filter by for Test Orders that get sent to the LIS | `160046AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,165254AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` |
    | `labonfhir.labUpdateTriggerObject` | The OpenMRS object type that should trigger LIS synchronization — Encounter or Order | `Encounter` |
    | `labonfhir.addObsAsTaskInput` | Allows adding Obs as Task Input | `false` |
    | `labonfhir.filterOrderBytestUuids` | Allows filtering Orders by Test UUIDs | `false` |
    | `labonfhir.createObsGroup` | Creates Obs groups to parse results into Lab Form | `true` |

    ---

    #### Compatibility

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.openElisUrl` | OpenELIS URL for iSantePlus Lab Form compatibility | `http://localhost:5001/fhir/` |


1. Ensure to Add the Right Test Catalogue to OpenELIS ( Tests with `Loinc Codes`) .
This can be done via the [test config](./configs/openelis/configuration/backend/tests/example-tests.csv) files for Innitialization at Startup or Manually via the UI

    The LOINC code of a test in OpenELIS must match the LOINC code of its concept in IsantePLUS exactly, and so must the LOINC code of every coded answer option. See [**Configuration Instructions**](./CONFIG_INSTRUCTIONS.md) for the tests, test results, test sections, sample types and dictionaries config files and how they fit together.

1. To send an Order from IsantePlus to OpenELIS , Go to the Patient Dashboard , Open the Laboratory form , select `OpenELIS` as the destination , select tests and send.

1. The Electronic Orders should be accesed in OpenELIS via Electronic Orders

1. Ensure Results entry and Results Validation in OpenELIS

1. To Fetch back the Test Results from OpenELIS , Start the OpenELIS Pull Task in Isanteplus to pull back the results.

   **⚠️ This task does not restart itself.** `OpenELIS Pull Task` (`org.openmrs.module.labonfhir.api.scheduler.FetchTaskUpdates`, runs every 30s) ships with `start_on_startup=0` — every time Tomcat restarts (a module deploy, a server reboot, applying settings from the section below...), this task stops and results silently stop arriving until someone starts it again by hand. The database still shows `started=1` from before the restart, which is misleading — it does **not** mean the task is currently running. After any Tomcat restart, go to **Administration système → Administration avancée → Scheduler → "OpenELIS Pull Task" → Démarrer la tâche**, or check from the database:
   ```sql
   SELECT name, started, last_execution_time FROM scheduler_task_config WHERE name='OpenELIS Pull Task';
   ```
   If `last_execution_time` is more than a couple of minutes old, the task is stopped in practice regardless of what `started` says — restart it. Seen on DEMO5 (2026-10-02): an order placed and filled in OpenELIS never showed its result back in IsantePLUS until this task was restarted by hand.

Note that All Transactions are Logged through OpenHIM


see [more](https://digi-uw.github.io/healthinformationexchange/lis-workflows/lis-workflows.html#tutorial-lab-order-communication-between-openmrs-and-openelis) for the EMR-LIS communication

## LNSP workflow settings on the IsantePLUS side (optional — only if this site's LNSP config is incomplete)

**This section is not part of installing OpenELIS.** It only applies if `xds-sender`/`labintegration` on this specific site are missing values or point to the wrong place (for example a site still pointing at an old central URL, or never fully finished its LNSP setup) — that was the situation found on the DEMO5 test server, which is why these scripts exist. A site whose LNSP install was completed correctly already has all of this configured and does not need anything below.

The IsantePLUS modules of the LNSP workflow (`xds-sender`, `labintegration`, reports) are configured through global properties. [`configs/isanteplus/lnsp/lnsp-settings.tsv`](./configs/isanteplus/lnsp/lnsp-settings.tsv) lists them, taken from the reference site where the workflow runs (HUP). [`scripts/apply-lnsp-settings.sh`](./scripts/apply-lnsp-settings.sh) applies them to the OpenMRS database: it is a **dry run by default** and only touches the listed properties (nothing is deleted).

1. Create the site's OpenHIM client as described in the LNSP procedure: same client id and password in the local OpenHIM and in the central one (`openhimconsole.sedish.net`, role `emr`).
2. Show what would change (nothing is written; passwords are never printed):

```
CLIENT_ID=<facility acronym> CLIENT_PASSWORD='<client password>' MYSQL_PWD='<mysql root password>' ./scripts/apply-lnsp-settings.sh
```

   `OPENMRS_ADMIN_PASSWORD` may also be set (password used by `xds-sender` to call OpenMRS). A setting whose variable is not set is skipped.
3. Apply, then restart Tomcat so that the modules and the scheduler pick up the values:

```
CLIENT_ID=<facility acronym> CLIENT_PASSWORD='<client password>' MYSQL_PWD='<mysql root password>' APPLY=1 ./scripts/apply-lnsp-settings.sh
sudo service tomcat7 restart
```

4. Steps of the LNSP procedure that are **not** settings and stay manual: the `set_isante_id.sh` script and its cron entry (uses the `location_id` of the site), the automatic resend of failed transactions on the `LNSP Order Passthrough` channel (Data Control, every 5 minutes), and, for OpenELIS, starting the `OpenELIS Pull Task` in the OpenMRS scheduler.
