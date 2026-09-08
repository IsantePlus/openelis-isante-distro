# Configuration Instructions

How to set up the shared test catalogue so lab orders and results flow between IsantePLUS and OpenELIS.

You edit two sets of plain CSV files, then restart the system that reads them:

- **IsantePLUS:** [`configs/isanteplus/concepts_update/concepts.csv`](./configs/isanteplus/concepts_update/concepts.csv)
- **OpenELIS:** [`configs/openelis/configuration/backend/`](./configs/openelis/configuration/backend/)

---

## 1. Why this matters

**The LOINC code is the only thing connecting the two systems.**

1. IsantePLUS sends the order with the test's LOINC code.
2. OpenELIS looks for a test with that same code. No match, no order.
3. OpenELIS sends the result back with the test's code, and for tests with a list of answers, the answer's code.
4. IsantePLUS uses those codes to save the result.

The code must be **exactly the same** on both sides, for the test **and** for every answer option. Even a trailing space breaks it.

## 2. How the two systems name things

In IsantePLUS everything is a concept. In OpenELIS a test and an answer are different things.

| IsantePLUS | OpenELIS | OpenELIS file |
| :--- | :--- | :--- |
| Test concept | **Test** | `tests` |
| Answer option concept | **Dictionary entry** | `dictionaries` |
| Link between test and answers | Test result options | `test-results` |

Both sides need a LOINC code, and they must match.

---

## 3. IsantePLUS: the concepts file

### What it does

It **only adds LOINC codes to concepts that already exist**. It does not create concepts, rename them, change their type, or create answer options. All of that must already be in IsantePLUS.

### The columns

```
UUID,NAME,DATA_TYPE,LOINC,NEW_LOINC
21AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Haemoglobin,Numeric,718-7,true
```

| Column | Used? | What to put |
| :--- | :--- | :--- |
| `UUID` | **Yes** | The concept UUID from IsantePLUS. The concept is found by this alone. |
| `NAME` | No | For reading only. Ignored by the system. |
| `DATA_TYPE` | No | For reference only. |
| `LOINC` | **Yes** | The code to add. Must match OpenELIS exactly. |
| `NEW_LOINC` | **Yes** | `true` applies the row. Anything else ignores it. |

### Rules

- **Set `NEW_LOINC` to `true`** for any row you want applied. Rows set to `false` are a record of codes already in IsantePLUS — leave them alone.
- **The concept must already exist.** If the UUID is not found, the row is skipped and a warning goes to the log.
- **A wrong code is not replaced.** The new code is added beside the old one. Remove the wrong one from the OpenMRS admin screens.
- **Never put a comma inside `NAME`.** Columns are separated by commas, so a comma in a name shifts everything after it and the row is ignored with no error.
- IsantePLUS must already have the `LOINC` concept source and the `SAME-AS` mapping type, or nothing in the file is applied.

### Installing the file

IsantePLUS reads `/openmrs/concepts_update` on startup. Every `.csv` in that folder is read.

**Normal setup — Tomcat on the server:**

```bash
sudo mkdir -p /openmrs/concepts_update
sudo cp configs/isanteplus/concepts_update/concepts.csv /openmrs/concepts_update/

# Tomcat must be able to read it — adjust the user to match your install
sudo chown -R tomcat:tomcat /openmrs/concepts_update

sudo systemctl restart tomcat
```

`/openmrs/concepts_update` is a full path, not a folder inside Tomcat or OpenMRS. If it is missing, IsantePLUS skips the step quietly — always check the log.

**Only if IsantePLUS runs in Docker**, mount the folder instead. The line is in [`docker-compose.yml`](./docker-compose.yml) under the `isanteplus` service, commented out. Those containers are for local testing only.

Re-running is safe. Nothing already correct is changed.

---

## 4. OpenELIS: the configuration files

All in [`configs/openelis/configuration/backend/`](./configs/openelis/configuration/backend/), one folder per file, read when OpenELIS starts.

Three things to know:

- **Rows are added or updated, never deleted.** Removing a row from a file does not remove it from OpenELIS — use the OpenELIS screens for that.
- **A file is only re-read if you change it.** To force a re-read of an unchanged file, delete its line from the matching `...-checksums.properties` file in the same folder, then restart.
- Blank lines and lines starting with `#` are ignored.

### Reading order

Later files depend on earlier ones:

**1.** `test-sections` → **2.** `sample-types` → **3.** `tests` → **4.** `dictionaries` → **5.** `test-results`

A department or specimen must exist before a test uses it. An answer must exist before a test offers it.

### 4.1 `tests`

```
testName,testSection,sampleType,loinc,isActive,isOrderable,sortOrder,unitOfMeasure,localization:en,localization:fr
Hemoglobin,Hematology,Whole Blood,718-7,Y,Y,1,g/dl,Hemoglobin,Hémoglobine
```

| Column | Required | What to put |
| :--- | :--- | :--- |
| `testName` | **Yes** | To change an existing test this must match its OpenELIS name **exactly**, or you create a duplicate. |
| `testSection` | **Yes** | The department. Must already exist or the row is ignored. |
| `sampleType` | Recommended | The specimen. Must already exist. Separate several with `\|`. |
| `loinc` | **Yes** | Must match the IsantePLUS concept exactly. |
| `isActive` | No | `Y` or `N`. Blank means `Y`. |
| `isOrderable` | No | Must be `Y` for IsantePLUS to order it. Blank means `Y`. |
| `sortOrder` | No | A number, for display order. |
| `unitOfMeasure` | No | Must already exist in OpenELIS or it is ignored. |
| `localization:en/fr` | No | Name shown on screen. |

**The specimen becomes part of the test name.** `Hemoglobin` + `Whole Blood` is stored as `Hemoglobin(Whole Blood)`. Using `Plasma|Serum` creates **two** tests. In `test-results` you still write the plain name, `Hemoglobin`.

### 4.2 `test-sections` — departments

```
testSectionName,description,isActive,sortOrder,isExternal,domain,localization:en,localization:fr
Serology,Serology Department,Y,5,N,CLINICAL,Serology,Sérologie
```

`testSectionName` is required. `domain` is `CLINICAL`, `ENVIRONMENTAL` or `VECTOR`; blank means `CLINICAL`.

**Only add a row if the department is not already in OpenELIS.** The shipped file has no rows because the departments in use already exist.

### 4.3 `sample-types` — specimens

```
description,localAbbreviation,domain,isActive,sortOrder,loinc,localization:en,localization:fr
Cerebrospinal fluid,CSF,H,Y,9,,Cerebrospinal fluid,Liquide céphalo-rachidien
```

`description` and `localAbbreviation` are required. `domain` `H` means human; blank means `H`.

**Only add a row if the specimen is not already in OpenELIS.** The shipped file is empty because Serum, Whole Blood, Plasma, Urines, Variable, Fluid, Sputum and Tissue antemortem all already exist.

### 4.4 `dictionaries` — the answers

Every answer a test can give must be listed here. This is the OpenELIS version of an IsantePLUS answer option.

```
category,dictEntry,localAbbreviation,isActive,sortOrder,loincCode,localization:en,localization:fr
HL,Negatif,ISANTE-001-Neg,Y,1,0000-016,Negative,Negative
```

| Column | Required | What to put |
| :--- | :--- | :--- |
| `category` | **Yes** | A grouping name. Created automatically if new. |
| `dictEntry` | **Yes** | The answer. `test-results` must spell it exactly this way. |
| `localAbbreviation` | No | A short code, not used by another entry. |
| `isActive` | No | `Y` or `N`. Blank means `Y`. |
| `sortOrder` | No | A number, for display order. |
| `loincCode` | **Yes** | Must match the answer option concept in IsantePLUS. |
| `localization:en/fr` | No | Wording shown on screen. |

The same word can exist in more than one category, so note which you used.

**Only add a row if the answer is not already in OpenELIS.**

### 4.5 `test-results` — result type and answer list

```
testName,resultType,resultValue,dictionaryCategory,sortOrder,isQuantifiable,isActive,isNormal,significantDigits,flags
Hemoglobin,N,,,1,Y,Y,Y,2,
Urine pregnancy test,D,Negatif,HL,2,N,Y,Y,,
Urine pregnancy test,D,Positif,HL,3,N,Y,N,,
```

| Column | Required | What to put |
| :--- | :--- | :--- |
| `testName` | **Yes** | Plain test name, **without** the `(Specimen)` part. |
| `resultType` | **Yes** | See below. |
| `resultValue` | For `D` | The answer, spelled exactly as in `dictionaries`. |
| `dictionaryCategory` | For `D` | That answer's category. |
| `sortOrder` | No | A number, for display order. |
| `isQuantifiable` | No | `Y` for a measured number, `N` for a list. Blank means `N`. |
| `isActive` | No | `Y` or `N`. Blank means `Y`. |
| `isNormal` | No | `Y` marks the normal or expected answer. |
| `significantDigits` | Numbers only | Decimal places, e.g. `2`. |
| `flags` | No | `H` for high, `L` for low. |

**Result types**

| Code | Means | Rows to write |
| :--- | :--- | :--- |
| `N` | A number | One row. Leave `resultValue` and `dictionaryCategory` empty. |
| `D` | A list of answers | One row per answer. |
| `R` | Free typed text | One row. |
| `A` | Letters and numbers | One row. |
| `T` | A titre, e.g. `1:10` | One row per value. |
| `M` | Several answers at once | One row per answer. |
| `C` | Answers depending on an earlier choice | One row per answer. |

**If an answer is not in `dictionaries`, that row is ignored.** This is the most common mistake: the test loads but has nothing to choose from.

---

## 5. Do I add it, or is it already there?

**If it exists, just refer to it. If not, add it first.**

| You need | Already exists | Does not exist |
| :--- | :--- | :--- |
| A department | Name it in `tests` → `testSection` | Add to `test-sections` **first** |
| A specimen | Name it in `tests` → `sampleType` | Add to `sample-types` **first** |
| An answer | Name it in `test-results` → `resultValue` | Add to `dictionaries` **first** |
| A test | Use its **exact** name in `tests` | Add to `tests` |

Check in OpenELIS under **Administration → Test Management**. Adding something already there is not dangerous, but it can quietly change a name or code other tests rely on.

---

## 6. Adding a new test

### A test that gives a number — Creatinine, `2160-0`

**1.** Concepts file:

```
8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Creatinine,Numeric,2160-0,true
```

**2.** `tests` — same code:

```
Creatinine,Biochemistry,Serum,2160-0,Y,Y,50,mg/dl,Creatinine,Créatinine
```

**3.** `test-results` — one row:

```
Creatinine,N,,,50,Y,Y,Y,2,
```

**4.** Restart both systems.

Nothing goes in `dictionaries` for a numeric test.

### A test with a list of answers — Malaria RDT, Positive or Negative

**1.** Concepts file — the test and each answer are separate concepts:

```
32AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Malaria RDT,Coded,70563-8,true
703AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,POSITIVE,N/A,0000-017,true
664AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,Negative,N/A,0000-016,true
```

**2.** `dictionaries` — the answers, with the answer codes:

```
Test Result,Malaria Positive,ISANTE-200-MP,Y,200,0000-017,Positive,Positif
Test Result,Malaria Negative,ISANTE-201-MN,Y,201,0000-016,Negative,Négatif
```

**3.** `tests` — the test code:

```
Malaria RDT,Hematology,Whole Blood,70563-8,Y,Y,60,,Malaria RDT,TDR Paludisme
```

**4.** `test-results` — one row per answer:

```
Malaria RDT,D,Malaria Positive,Test Result,60,N,Y,N,,
Malaria RDT,D,Malaria Negative,Test Result,61,N,Y,Y,,
```

**5.** Restart both systems.

Codes that must match: `70563-8` for the test, `0000-017` and `0000-016` for the answers.

---

## 7. Checking it worked

### In OpenELIS

**Administration → Test Management.** Confirm the test is there with the right department and specimen, the LOINC code matches the concepts file, all answers appear, and the test is active and orderable.

### In IsantePLUS

Open the OpenMRS **Dictionary**, search the concept, check its mappings show `LOINC` with your code. If two different codes appear, remove the wrong one.

### In the logs

**IsantePLUS** shows a line like:

```
Processed concepts.csv: added=12, skipped=300, notFound=3, errors=0
```

`notFound` above zero means some UUIDs are not in this database.

**OpenELIS** logs to `configs/openelis/logs/oeLogs/openELIS.log`:

| Message | Fix |
| :--- | :--- |
| `Test section '...' not found` | Add it to `test-sections` |
| `Sample type '...' not found` | Add it to `sample-types` |
| `Dictionary entry '...' not found` | Add it to `dictionaries` |
| `... data rows were SKIPPED` | Reason is just above |

### Try a real order

1. IsantePLUS patient dashboard → Laboratory form → choose `OpenELIS` → select the test → send.
2. It should appear in OpenELIS under **Electronic Orders**. If not, the test's LOINC codes do not match.
3. Enter and validate the result in OpenELIS.
4. In IsantePLUS, run the OpenELIS Pull Task. The result should appear. If a list-of-answers test does not come back, the **answer's** code does not match.

Every message between the two systems is recorded in OpenHIM.

---

## 8. Tests with no matching entry in the concepts file

These nine OpenELIS tests have a LOINC code that appears nowhere in the concepts file.

**This is not automatically a fault.** The concepts file only lists concepts whose code had to be added, so a code missing from it usually means IsantePLUS already had the right one. Check each in the OpenMRS **Dictionary** before changing anything.

| LOINC | Test | Department | Specimen |
| :--- | :--- | :--- | :--- |
| `5126-8` | Cytomegalovirus IgM | Hematology | Serum |
| `6355-2` | Chlamydia trachomatis Ag, immunofluorescence | Hematology | Variable |
| `6361-0` | Clostridium difficile toxin A+B, immunoassay | Hematology | Serum |
| `13949-3` | Cytomegalovirus IgG | Hematology | Serum |
| `25338-5` | Dengue virus IgM | Hematology | Serum |
| `25836-8` | HIV VIRAL LOAD | Molecular Biology | Plasma |
| `29676-4` | Dengue virus IgG | Hematology | Serum |
| `32188-5` | Cerebrospinal fluid AFB stain | Hematology | Fluid |
| `45009-8` | Chlamydia trachomatis Ab, immunofluorescence | Hematology | Serum |

For each one:

- **The concept has the code already** — nothing to do.
- **The concept has no code, or a different one** — add a row to the concepts file with the concept's UUID, this code, and `true`.
- **No such concept exists** — create it in IsantePLUS first. The concepts file cannot create concepts.

**Look at `HIV VIRAL LOAD` closely.** OpenELIS gives it `25836-8`, which is the quantitative viral load. The concepts file has a concept called `HIV VIRAL LOAD QUALITATIVE` with `48510-2`, which is the qualitative one. These are genuinely two different codes, so this may be correct — but if the two are meant to be the same test, one side is wrong. It is also the only one of the nine with no row in `test-results`, so unless a result type is already set for it in OpenELIS, results cannot be entered against it.
