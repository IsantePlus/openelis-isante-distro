# Configuration Instructions

How to define the shared test catalogue for the iSantePlus ↔ OpenELIS lab workflow.

- **iSantePlus side:** [`configs/isanteplus/concepts_update/concepts.csv`](./configs/isanteplus/concepts_update/concepts.csv)
- **OpenELIS side:** [`configs/openelis/configuration/backend/`](./configs/openelis/configuration/backend/)

---

## 1. Why this matters

**LOINC is the only thing that joins the two systems.**

1. iSantePlus sends an order as a FHIR `ServiceRequest` carrying the test concept's **LOINC** code.
2. OpenELIS matches that LOINC to a test in its catalogue. No match, no order.
3. OpenELIS returns the result carrying the test's LOINC and, for coded results, the **answer's LOINC**.
4. iSantePlus matches those back to its concepts to store the Obs.

So a LOINC code in iSantePlus must be **an exact string match** to the LOINC code in OpenELIS. This is true for the **test** and for **every coded answer option**. `718-7` and `718-7 ` (trailing space) are different codes and the flow breaks.

## 2. How the two models map

In iSantePlus **everything is a concept** — the test *and* each of its coded answers. In OpenELIS a test and an answer are two different kinds of object.

| iSantePlus | OpenELIS | Where it is defined for OpenELIS |
| :--- | :--- | :--- |
| Test concept (`Numeric`, `Coded`, `Text`) | **Test** | `tests/` |
| Coded answer option concept (`N/A`) | **Dictionary entry** | `dictionaries/` |
| The concept → answers relationship | Test → dictionary entry mapping | `test-results/` |

Both the test concept and each answer concept must carry a LOINC, and both must match their OpenELIS counterpart.

---

## 3. iSantePlus: `concepts.csv`

### What it does — and does not do

`concepts.csv` **only attaches LOINC codes to concepts that already exist in iSantePlus.**

It **does not**:
- create concepts,
- rename concepts,
- change a concept's data type,
- create answer options or answer sets.

All of that must already exist in iSantePlus (via the metadata bundle or the OpenMRS admin UI). This file is purely a LOINC patch.

### Format

```csv
UUID,NAME,DATA_TYPE,LOINC,NEW_LOINC
908AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,HERPES SIMPLEX VIRUS QUALITATIVE,Coded,51916-5,true
21AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Haemoglobin,Numeric,718-7,false
664AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Negative,N/A,0000-016,true
```

| Column | Used by the loader? | Notes |
| :--- | :--- | :--- |
| `UUID` | **Yes — the key field** | The OpenMRS concept UUID. The concept is looked up by this and nothing else. |
| `NAME` | No | Documentation only, for humans reading the file. |
| `DATA_TYPE` | No | Documentation only. `Numeric` / `Coded` / `Text` / `Boolean` for test concepts, `N/A` for answer options. |
| `LOINC` | **Yes** | The code to attach. Must match OpenELIS exactly. |
| `NEW_LOINC` | **Yes — the switch** | `true` = apply this row. Anything else = row ignored. |

### Rules

- **`NEW_LOINC` must be `true` for the row to do anything.** If a concept has no LOINC in iSantePlus, or has the wrong one, add it here with `NEW_LOINC=true`. Rows set to `false` are historical records of codes already present in iSantePlus; leave them alone.
- **The concept must already exist.** If the UUID is not found, the loader logs `Concept not found for UUID: <uuid>` and moves on.
- **Existing codes are added, never replaced.** The loader adds a `SAME-AS` mapping against the `LOINC` concept source. If the concept already carries that exact code, the row is skipped (safe to re-run). If the concept carries a *different* LOINC, the new code is added **alongside** the old one — the wrong code is not removed. Delete a wrong mapping in the OpenMRS admin UI.
- **⚠️ No commas in `NAME`.** The loader splits each line on `,` and **does not honour quotes**. A quoted name containing a comma shifts the columns, so `LOINC` and `NEW_LOINC` are read from the wrong cells and the row is **silently skipped** with no error. Write `HERPES SIMPLEX VIRUS QUALITATIVE`, not `"HERPES SIMPLEX VIRUS, QUALITATIVE"`.
- **Prerequisites in iSantePlus:** the `LOINC` concept source and the `SAME-AS` concept map type must exist. If either is missing the whole import aborts with a warning and no rows are applied.

### How it is deployed

The file is read on **iSantePlus module startup** from the absolute path `/openmrs/concepts_update`, on whatever machine is running OpenMRS. Every `.csv` in that directory is processed.

**Standard deployment — iSantePlus in Tomcat on the host.** This is how iSantePlus actually runs in this setup. There is no container involved, so just create the directory on the host and copy the file in:

```bash
sudo mkdir -p /openmrs/concepts_update
sudo cp configs/isanteplus/concepts_update/concepts.csv /openmrs/concepts_update/

# Tomcat must be able to read it — adjust the user to match your install
sudo chown -R tomcat:tomcat /openmrs/concepts_update

sudo systemctl restart tomcat
```

The path is absolute and is **not** relative to the Tomcat or OpenMRS application directory. If the directory is missing, the import is skipped quietly with `Directory /openmrs/concepts_update not found, skipping LOINC import` — no error, so check the log rather than assuming it ran.

**Only if you run iSantePlus in Docker**, mount the directory into the container instead of creating it on the host. [`docker-compose.yml`](./docker-compose.yml) has the line ready under the `isanteplus` service, commented out:

```yaml
- ./configs/isanteplus/concepts_update:/openmrs/concepts_update
```

The `isanteplus` and `isanteplus-db` services in this repo's compose file are commented out on purpose — they exist for local testing only. In a real deployment iSantePlus is not part of this stack, so leave them commented and use the host instructions above.

Either way the import runs on every restart and is idempotent. Confirm in the OpenMRS log:

```
Processed concepts.csv: added=12, skipped=300, notFound=3, errors=0
```

`notFound` above zero means UUIDs in your file are not in this iSantePlus database.

---

## 4. OpenELIS: `configs/openelis/configuration/backend/`

### How loading works

This directory is mounted into OpenELIS at `/var/lib/openelis-global/configuration/backend` and read at **startup**.

- Each folder is one domain, loaded in a fixed order so dependencies exist before they are referenced.
- **Rows are create-or-update.** A row that matches an existing record updates it; a row that doesn't creates a new record. **Nothing is ever deleted** — remove a row from the CSV and the record stays in the database.
- **Each file is checksummed.** A file is only re-read when its content changes; the hashes live in `<domain>-checksums.properties` alongside the folders. To force a reload of an unchanged file, delete its entry from that properties file (or delete the file) and restart.
- Blank lines and lines starting with `#` are ignored.

### Load order

| Order | Folder | Defines |
| :--- | :--- | :--- |
| 100 | `test-sections/` | Lab departments (Hematology, Biochemistry…) |
| 100 | `sample-types/` | Specimen types (Serum, Whole Blood…) |
| 300 | `dictionaries/` | Coded result values (Positive, A NEGATIVE…) |
| 200 | `tests/` | The tests themselves |
| 310 | `test-results/` | Each test's result type, and which dictionary entries are its allowed answers |

Read that as: sections and sample types first, then tests, then dictionaries, then the wiring between tests and dictionary values.

### 4.1 `tests/example-tests.csv` — the tests

```csv
testName,testSection,sampleType,loinc,isActive,isOrderable,sortOrder,unitOfMeasure,localization:en,localization:fr
Hemoglobin,Hematology,Whole Blood,718-7,Y,Y,1,g/dl,Hemoglobin,Hémoglobine
```

| Column | Required | Notes |
| :--- | :--- | :--- |
| `testName` | **Yes** | **Must match the existing OpenELIS test name exactly to update it.** Any other spelling creates a second test. |
| `testSection` | **Yes** | Must already exist. If it doesn't, the **whole row is skipped**. |
| `sampleType` | Recommended | Must already exist, or that sample type is skipped. Several can be given separated by `\|`. |
| `loinc` | **Yes in practice** | Must match the iSantePlus test concept's LOINC exactly. Without it the order will not match. |
| `isActive` | No | `Y`/`N`, defaults to `Y`. |
| `isOrderable` | No | `Y`/`N`, defaults to `Y`. Must be `Y` to be orderable from iSantePlus. |
| `sortOrder` | No | Display order; auto-assigned if blank. |
| `unitOfMeasure` | No | Must already exist in OpenELIS, or it is ignored. |
| `localization:xx` | No | Display name per locale (`en`, `fr`, `es`, `id`). Defaults to `testName`. |

**Important — the sample type is baked into the stored test name.** When `sampleType` is filled, the test is stored as `testName(sampleType)`:

- `Hemoglobin,Hematology,Whole Blood` → one test named `Hemoglobin(Whole Blood)`
- `HIV Rapid Test,Serology,Plasma|Serum` → **two** tests, `HIV Rapid Test(Plasma)` and `HIV Rapid Test(Serum)`, each with its own sample type

You still write the **base** name (`Hemoglobin`) in `test-results/`; it resolves to every `Hemoglobin(...)` variant.

### 4.2 `test-sections/example-test-sections.csv` — lab departments

```csv
testSectionName,description,isActive,sortOrder,isExternal,domain,localization:en,localization:fr
Serology,Serology Department,Y,5,N,CLINICAL,Serology,Sérologie
```

`testSectionName` is required. `domain` is `CLINICAL`, `ENVIRONMENTAL` or `VECTOR` (defaults to `CLINICAL`). Existing sections with a matching name are updated.

**Only add a row if the section does not already exist in OpenELIS.** If your test uses `Hematology` and OpenELIS already has it, leave this file empty — the reference file ships with a header and no rows for exactly that reason.

### 4.3 `sample-types/example-sample-types.csv` — specimen types

```csv
description,localAbbreviation,domain,isActive,sortOrder,loinc,localization:en,localization:fr
Cerebrospinal fluid,CSF,H,Y,9,,Cerebrospinal fluid,Liquide céphalo-rachidien
```

`description` and `localAbbreviation` are required. `domain` defaults to `H` (Human). Matching is on `localAbbreviation` + `domain`. `loinc` here is the specimen code and is optional.

**Only add a row if the sample type does not already exist.** The shipped catalogue uses `Serum`, `Whole Blood`, `Plasma`, `Urines`, `Variable`, `Fluid`, `Sputum` and `Tissue antemortem`, which OpenELIS already has — hence the empty file.

### 4.4 `dictionaries/example-dictionary-entries.csv` — coded answer values

Every coded answer that a test can return must exist here as a dictionary entry. **This is the OpenELIS counterpart of an iSantePlus coded answer option concept.**

```csv
category,dictEntry,localAbbreviation,isActive,sortOrder,loincCode,localization:en,localization:fr
HL,Negatif,ISANTE-001-Neg,Y,1,0000-016,Negative,Negative
Test Result,A POSITIVE,ISANTE-005-A P,Y,5,0000-020,A POSITIVE,A POSITIVE
```

| Column | Required | Notes |
| :--- | :--- | :--- |
| `category` | **Yes** | Grouping name. **Auto-created if it does not exist.** |
| `dictEntry` | **Yes** | The stored value. This is the exact string `test-results/` refers to. |
| `localAbbreviation` | No | Short code, must be unique. |
| `isActive` | No | `Y`/`N`, defaults to `Y`. |
| `sortOrder` | No | Order in the result dropdown. |
| `loincCode` | **Yes for the workflow** | **Must match the LOINC of the answer-option concept in iSantePlus.** |
| `localization:xx` | No | Display label per locale. |

Matching is on `dictEntry` + `category`, so the same word can exist in several categories.

**Only add a row if the value does not already exist in OpenELIS.** If it does, just reference it from `test-results/`.

### 4.5 `test-results/example-test-results.csv` — result type and answer wiring

This is where a test gets its result type, and where coded tests get their allowed answers.

```csv
testName,resultType,resultValue,dictionaryCategory,sortOrder,isQuantifiable,isActive,isNormal,significantDigits,flags
Hemoglobin,N,,,1,Y,Y,Y,2,
Urine pregnancy test,D,Negatif,HL,2,N,Y,Y,,
Urine pregnancy test,D,Positif,HL,2,N,Y,Y,,
Culture and sensitivity blood,R,,,80,N,Y,Y,,
```

| Column | Required | Notes |
| :--- | :--- | :--- |
| `testName` | **Yes** | The **base** name from `tests/` — no `(SampleType)` suffix. It applies to every `Base(...)` variant. If no test matches, the row is skipped. |
| `resultType` | **Yes** | See table below. |
| `resultValue` | For `D`/`M`/`C` | Must equal an existing `dictEntry`. |
| `dictionaryCategory` | Recommended for `D`/`M`/`C` | The `category` of that entry. Disambiguates a value used in several categories. |
| `sortOrder` | No | Order of this option. |
| `isQuantifiable` | No | `Y` for numeric measurements, `N` for coded. Defaults to `N`. |
| `isActive` | No | `Y`/`N`, defaults to `Y`. |
| `isNormal` | No | Marks this option as the normal/expected result. |
| `significantDigits` | Numeric only | Decimal places, e.g. `2`. |
| `flags` | No | Result flag, e.g. `H` (high), `L` (low). |

**Result types**

| Code | Meaning | How to write the rows |
| :--- | :--- | :--- |
| `N` | Numeric | **One row per test.** Leave `resultValue` and `dictionaryCategory` empty; set `isQuantifiable=Y` and `significantDigits`. |
| `D` | Dictionary (coded) | **One row per allowed answer.** `resultValue` must be an existing `dictEntry`. |
| `R` | Remark / free text | One row. `resultValue` empty. |
| `A` | Alphanumeric text | One row. |
| `T` | Titer (`1:10`, `1:20`) | One row per titer value. |
| `M` | Multiselect | One row per selectable dictionary entry. |
| `C` | Cascading multiselect | One row per dictionary entry. |

**If a `D` row's dictionary entry does not exist, the row is skipped** and the OpenELIS log records:

```
CONFIGURATION ERROR: Dictionary entry 'Positif' in category 'HL' not found for test '...'. Skipping row.
```

That is the single most common failure: a coded test whose answers were never added to `dictionaries/`. The test loads, but has no selectable results.

---

## 5. Does it exist already? — the decision rule

The same rule applies to all four supporting objects: **reference it if it exists, define it if it doesn't.**

| You need | Already in OpenELIS | Not in OpenELIS |
| :--- | :--- | :--- |
| A test section | Just name it in `tests/` → `testSection` | Add a row to `test-sections/` **first** |
| A sample type | Just name it in `tests/` → `sampleType` | Add a row to `sample-types/` **first** |
| A coded answer value | Just name it in `test-results/` → `resultValue` | Add a row to `dictionaries/` **first** |
| A test | Use the **exact** existing name in `tests/` to update it | Add a row to `tests/` to create it |

Defining something that already exists is not harmful (the row updates it), but it can quietly change a name, sort order or LOINC that other tests rely on. Checking first is cheaper.

---

## 6. Adding a new test end to end

### A numeric test (e.g. Creatinine, LOINC `2160-0`)

1. **iSantePlus** — find the concept UUID for Creatinine and confirm it has no LOINC (or the wrong one).
2. **`concepts.csv`** — add:
   ```csv
   8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Creatinine,Numeric,2160-0,true
   ```
3. **OpenELIS** — confirm the test section and sample type exist; add them to `test-sections/` / `sample-types/` if not.
4. **`tests/`** — add the test with **the same LOINC**:
   ```csv
   Creatinine,Biochemistry,Serum,2160-0,Y,Y,50,mg/dl,Creatinine,Créatinine
   ```
5. **`test-results/`** — one numeric row:
   ```csv
   Creatinine,N,,,50,Y,Y,Y,2,
   ```
6. Restart both systems and verify.

No `dictionaries/` work is needed for numeric tests.

### A coded test (e.g. Malaria RDT with answers Positive / Negative)

1. **iSantePlus** — the test concept **and each answer option** are separate concepts. Collect all their UUIDs.
2. **`concepts.csv`** — one row for the test, one row per answer, each with its own LOINC and `NEW_LOINC=true`:
   ```csv
   32AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Malaria RDT,Coded,70563-8,true
   703AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,POSITIVE,N/A,0000-017,true
   664AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Negative,N/A,0000-016,true
   ```
3. **OpenELIS** — confirm the test section and sample type exist.
4. **`dictionaries/`** — add any answer value that does not already exist, with the answer's LOINC:
   ```csv
   Test Result,Malaria Positive,ISANTE-200-MP,Y,200,0000-017,Positive,Positif
   Test Result,Malaria Negative,ISANTE-201-MN,Y,201,0000-016,Negative,Négatif
   ```
5. **`tests/`** — add the test with the **test** LOINC:
   ```csv
   Malaria RDT,Hematology,Whole Blood,70563-8,Y,Y,60,,Malaria RDT,TDR Paludisme
   ```
6. **`test-results/`** — one `D` row per answer, pointing at those dictionary entries:
   ```csv
   Malaria RDT,D,Malaria Positive,Test Result,60,N,Y,N,,
   Malaria RDT,D,Malaria Negative,Test Result,61,N,Y,Y,,
   ```
7. Restart both systems and verify.

The LOINC pairs that must match: `70563-8` for the test, `0000-017` and `0000-016` for the answers.

---

## 7. Verifying

### Check LOINC parity before you deploy

Run from the repo root:

```bash
python3 - <<'EOF'
import csv
C = 'configs/isanteplus/concepts_update/concepts.csv'
T = 'configs/openelis/configuration/backend/tests/example-tests.csv'
D = 'configs/openelis/configuration/backend/dictionaries/example-dictionary-entries.csv'

concepts = {r['LOINC'].strip() for r in csv.DictReader(open(C)) if r['LOINC'].strip()}
tests    = {r['loinc'].strip() for r in csv.DictReader(open(T)) if r.get('loinc','').strip()}
answers  = {r['loincCode'].strip() for r in csv.DictReader(open(D)) if r.get('loincCode','').strip()}

print('test LOINCs not listed in concepts.csv:', sorted(tests - concepts) or 'none')
print('answer LOINCs not listed in concepts.csv:', sorted(answers - concepts) or 'none')

# rows the iSantePlus loader will silently skip: it splits on ',' without honouring quotes
for n, line in enumerate(open(C), 1):
    if n > 1 and line.count(',') != 4:
        print('BROKEN ROW (comma in NAME), line', n, ':', line.strip())
EOF
```

**A broken row is always a real defect** — its LOINC is never applied in iSantePlus.

**A "not listed in concepts.csv" LOINC is a lead, not a defect.** All four of these files are *patch* files, not a full dump of either catalogue: `concepts.csv` only carries concepts whose LOINC needed adding or fixing, and the OpenELIS files only carry what needed creating or changing. So a LOINC absent from `concepts.csv` means one of two things:

- the iSantePlus concept **already carries** that LOINC, so no patch row was ever needed — nothing to do; or
- **no concept carries it**, and orders for that test will never match.

The CSVs cannot tell those apart. Confirm against the running iSantePlus database:

```sql
SELECT crt.code, c.uuid, cn.name
FROM concept_reference_term crt
JOIN concept_reference_source crs ON crs.concept_source_id = crt.concept_source_id
JOIN concept_reference_map crm    ON crm.concept_reference_term_id = crt.concept_reference_term_id
JOIN concept c                    ON c.concept_id = crm.concept_id
JOIN concept_name cn              ON cn.concept_id = c.concept_id AND cn.locale_preferred = 1
WHERE crs.name = 'LOINC'
  AND crt.code IN ('13949-3','5126-8','32188-5');   -- the codes the script listed
```

A code that returns no row has no concept behind it and needs one. The end-to-end smoke test below answers the same question the slow way.

See [section 8](#8-known-issues-in-the-current-catalogue) for what is currently outstanding.

### Check the logs after restart

**iSantePlus** — `Processed concepts.csv: added=…, skipped=…, notFound=…, errors=…`. `notFound > 0` means UUIDs in your file are missing from that database.

**OpenELIS** — `configs/openelis/logs/oeLogs/openELIS.log`:

```bash
grep -E "CONFIGURATION ERROR|were SKIPPED|not found" configs/openelis/logs/oeLogs/openELIS.log
```

Look for:
- `Test section 'X' not found … Skipping.` → add it to `test-sections/`
- `Sample type 'X' not found` → add it to `sample-types/`
- `CONFIGURATION ERROR: Dictionary entry 'X' … not found` → add it to `dictionaries/`
- `N of M data rows were SKIPPED` in the `test-results` summary → one of the above

### End-to-end smoke test

1. Order the test from the iSantePlus Laboratory form with `OpenELIS` as the destination.
2. It should appear under **Electronic Orders** in OpenELIS. If it doesn't, the LOINC does not match.
3. Enter and validate the result in OpenELIS.
4. Run the OpenELIS Pull Task in iSantePlus. The result should land as an Obs. If a coded result doesn't, the **answer's** LOINC does not match.

All traffic is logged in OpenHIM, which is the fastest place to see the LOINC actually sent on the wire.

---

## 8. Current state of the shipped files

8.1 is a confirmed defect. 8.2 and 8.3 are leads to check, not known breakage — remember these files are patches over what each system already has.

### 8.1 Seven `concepts.csv` rows are silently skipped

They are set to `NEW_LOINC=true` but have a comma inside a quoted `NAME`, so the loader mis-parses the columns and skips the row with no error — these LOINC codes are never applied in iSantePlus:

| UUID | NAME | LOINC |
| :--- | :--- | :--- |
| `908AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `HERPES SIMPLEX VIRUS, QUALITATIVE` | `51916-5` |
| `1945AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `Serum Pregnancy Test, Qualitative` | `2118-8` |
| `159982AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `results, tuberculosis culture` | `88142-5` |
| `160735AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `Bacteriuria test, urine` | `20408-1` |
| `163426AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `Combined % of monocytes, eosinophils and basophils` | `32155-4` |
| `123501AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `Urinary Cast, Hyaline` | `0000-099` |
| `1305AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `HIV VIRAL LOAD, QUALITATIVE` | `48510-2` |

**Fix:** remove the commas from `NAME` (and the surrounding quotes). `NAME` is documentation only, so rewording it is safe. Nine further rows have the same defect but are set to `NEW_LOINC=false`, so nothing is lost — worth cleaning up all the same.

### 8.2 Nine test LOINCs are not listed in `concepts.csv` — to be confirmed

These nine tests carry a LOINC in `tests/example-tests.csv` that appears in no `concepts.csv` row. As explained in section 7 this is **not by itself a defect** — most are likely concepts that already carried the right LOINC in iSantePlus and so never needed a patch row. Confirm each with the SQL query in section 7 before doing anything.

| LOINC | OpenELIS test | Section | Sample type | Result type |
| :--- | :--- | :--- | :--- | :--- |
| `5126-8` | Cytomegalovirus IgM | Hematology | Serum | D |
| `6355-2` | Chlamydia trachomatis Ag presence in unspecified specimen by immunofluorescence test | Hematology | Variable | D |
| `6361-0` | Clostridium difficile toxin A+B presence in serum by immunoassay test | Hematology | Serum | D |
| `13949-3` | Cytomegalovirus IgG | Hematology | Serum | D |
| `25338-5` | Dengue virus IgM Ab presence in serum | Hematology | Serum | D |
| `25836-8` | HIV VIRAL LOAD | Molecular Biology | Plasma | — none — |
| `29676-4` | Dengue virus IgG Ab presence in serum | Hematology | Serum | D |
| `32188-5` | Cerebrospinal fluid AFB stain | Hematology | Fluid | D |
| `45009-8` | Chlamydia trachomatis Ab presence in serum by immunofluorescence test | Hematology | Serum | D |

**If the query returns no concept for a code:** find the matching iSantePlus concept and add it to `concepts.csv` with that LOINC and `NEW_LOINC=true`. If no concept exists at all, create it in iSantePlus first — `concepts.csv` cannot create concepts.

**One to look at closely — `HIV VIRAL LOAD`.** OpenELIS gives it `25836-8` (quantitative viral load), while `concepts.csv` carries a concept named `HIV VIRAL LOAD, QUALITATIVE` with `48510-2` (qualitative) and `NEW_LOINC=true`. Those are two different LOINC concepts, so this may be correct — but if they are meant to be the same test, one side has the wrong code. It is also the only one of the nine with **no `test-results/` row**, so unless a result type is already defined for it in the OpenELIS database, results cannot be entered against it.

All coded answer LOINCs in `dictionaries/` are listed in `concepts.csv`.

### 8.3 Same caveat for the OpenELIS files

23 tests in `tests/example-tests.csv` have no row in `test-results/example-test-results.csv` — Hemoglobin, Glucose, Creatinine, Hematocrit and similar. These are standard OpenELIS catalogue tests that almost certainly already have their result types defined in the database, which is exactly why no row was written. Check the Test Management UI before adding rows for any of them.
