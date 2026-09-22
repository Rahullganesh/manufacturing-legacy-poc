# APEX Nutritional Manufacturing — IBM i Source Corpus

> **DEMO CORPUS — ALL CONTENT IS FABRICATED**
> This is a synthetic IBM i manufacturing application created for POC purposes.
> Table names, program names, lot numbers, and company names are entirely fictional.
> Any resemblance to actual production systems is coincidental.

---

## Application Overview

**APEX Nutritional Manufacturing Information & Tracking System**
A fabricated IBM i application representing a nutritional product manufacturing
execution system. Supports blend order management, RF container scanning,
yield reconciliation, QA hold management, and batch close workflows.

Products modelled: high-calorie nutritional drinks, infant formula, meal supplement powders.

---

## Source Member Inventory

### QDDSSRC — DDS Physical File Definitions

| Member       | Description                                      |
|-------------|--------------------------------------------------|
| BLNDORDR    | Blend Order Master — one row per production batch |
| LOTMSTR     | Lot Master — raw material and finished good lots  |
| TABLES      | Combined DDS for: CNTNRFIL, INGRISS, QLTHOLD,    |
|             | YLDVARNC, LINESHFT, RMATMAS, LBLLOG              |

### QSQLSRC — SQL DDL and Stored Procedures

| Member          | Description                                           |
|----------------|-------------------------------------------------------|
| CREATE_TABLES  | Full DB2 for i SQL DDL for 10 tables with:            |
|                | - PK / FK / CHECK constraints                         |
|                | - Generated columns (LDAYS_TO_EXP, IIVARQTY, etc.)   |
|                | - Identity columns, sequences                         |
|                | - 12 performance indexes                              |
| STORED_PROCS   | 5 SQL stored procedures:                              |
|                | SP_VALIDATE_BLEND — 8-step blend validation           |
|                | SP_PLACE_QA_HOLD  — Place / cascade QA holds          |
|                | SP_RELEASE_HOLD   — Release holds, update lot status  |
|                | SP_CLOSE_BATCH    — End-of-batch validation and close |
|                | SP_BLEND_ORDER_STATUS_RPT — 4 result set report       |
|                | SP_SHIFT_SUMMARY  — Shift KPI report                  |

### QRPGLESRC — Free-format RPGLE Programs

| Member       | Description                                           |
|-------------|-------------------------------------------------------|
| BLNDVAL     | Blend Order Validation                                |
|             | - 8-step validation sequence                          |
|             | - Operator authorisation check (SQL LINEAUTH)         |
|             | - Line CIP status check                               |
|             | - Formula version active check                        |
|             | - Ingredient lot loop: QA status, expiry,            |
|             |   active holds, quantity tolerance                    |
|             | - Calls SP_VALIDATE_BLEND to set status = RL          |
| RFCNTSCAN   | RF Container Scan                                     |
|             | - GS1-128 barcode AI parser (AI 00/01/10/17/310n)    |
|             | - Duplicate scan detection                            |
|             | - Checkweigher IIoT data area read (CHKWGH_Lnnn)     |
|             | - DLYJOB 300ms workaround (CHG-2026-0051)             |
|             | - Weight classification OK/LO/HI/RE with recheck band |
|             | - Consecutive underweight alert (shift QA)            |
|             | - Calls LBLPRINT on successful fill                   |
| YLDRECNC    | Yield Reconciliation                                  |
|             | - Theoretical vs actual yield calculation             |
|             | - Per-formula max variance from FORMSPEC              |
|             | - Auto QA hold via SP_PLACE_QA_HOLD if exceeded       |
|             | - P1 incident logging for severe short fill (<-10%)   |
|             | - RE container exclusion warning                      |
| LBLPRINT    | Container Label Print Driver                          |
|             | - GS1-128 ZPL label generation                       |
|             | - FDA 21 CFR Part 101 nutritional label format        |
|             | - HOLD label (watermark), HZRD label (allergen box)  |
|             | - Lot number workaround: CHG-2026-0047 (ZPL firmware) |
|             | - Every print logged to LBLLOG                        |

### QCLSRC — CL Programs

| Member       | Description                                           |
|-------------|-------------------------------------------------------|
| BATCHCLS    | Batch Close Driver                                    |
|             | - Label completeness check (RUNSQL)                   |
|             | - RE container warning                                |
|             | - Calls YLDRECNC, LOTAPPRV, SP_CLOSE_BATCH           |
|             | - QABATCH parameter for direct close bypass          |
|             | - Error handling with SNDMSG notifications            |
|             | - Known issue CHG-2026-0058 (scheduler 5-min lag)    |

---

## Table Reference

| Table       | Rows (typical) | Key                         | Purpose                      |
|------------|---------------|-----------------------------|------------------------------|
| RMATMAS    | ~2,000        | RMITEMNO                    | Raw material / item master   |
| BLNDORDR   | ~300/day      | BORDNO                      | Blend/batch order header     |
| LOTMSTR    | ~8,000 active | LOTNO + LOTITEM             | Lot master (all types)       |
| INGRISS    | ~3,000/day    | BORDNO + ITEMNO + SEQNO     | Ingredient issue log         |
| CNTNRFIL   | ~4,000–6,000/shift | CNTNRID + SEQNO        | Container fill records       |
| QLTHOLD    | ~50 active    | LOTNO + SEQNO               | QA holds                     |
| YLDVARNC   | 1 per order   | BORDNO                      | Yield variance record        |
| LINESHFT   | 3/line/day    | LINENO + SHIFTNO + SHIFTDT  | Line/shift log               |
| LBLLOG     | ~5,000/shift  | LLLOGID (identity)          | Label print audit log        |
| INVTRANS   | ~15,000/day   | ITTRANSID (identity)        | Inventory transaction log    |
| FORMSPEC   | ~500          | FORMCD + FORMVER + LINESEQ  | Formula bill of materials    |

---

## Open Change Requests

| Change No    | Program(s)    | Description                                        | Status |
|-------------|-------------|-----------------------------------------------------|--------|
| CHG-2026-0044 | RFCNTSCAN | Duplicate scan CHAIN lock contention under high volume. Proposed: SQL INSERT +23 check | Open |
| CHG-2026-0047 | LBLPRINT  | ZPL lot number truncation on firmware v6.7.3 (lines L002, L004). Workaround in place | In Test |
| CHG-2026-0051 | RFCNTSCAN | Checkweigher data area race condition. Workaround: DLYJOB 300ms | Open |
| CHG-2026-0058 | BATCHCLS  | Scheduler submits BATCHCLS before last RF scans written. Fix: add 5-min delay to scheduler | Open |
| CHG-2026-0062 | YLDRECNC  | RE containers not resolved before yield recon causes false QA holds. Fix: add RE check in YLDRECNC | Open |

---

## Known Errors and What They Mean

| Error / Symptom                          | Root Cause                        | Resolution                           |
|------------------------------------------|-----------------------------------|--------------------------------------|
| Duplicate key on CNTNRFIL insert         | CHG-2026-0044 — CHAIN lock        | Retry scan; if persists call IT      |
| Checkweigher reading previous container  | CHG-2026-0051 — CW timing         | DLYJOB workaround auto-applies       |
| Lot number truncated to 14 chars on label | CHG-2026-0047 — ZPL firmware      | Lines L001/L003/L005 OK; others patched |
| QA hold placed on good batch             | CHG-2026-0062 — unresolved RE     | Check CNTNRFIL for RE containers; remove before running YLDRECNC |
| BATCHCLS closes batch with missing cans  | CHG-2026-0058 — scheduler timing  | Always wait 5 minutes after last fill before closing |
| SQLCODE -501 on YLDRECNC                 | Cursor not open / WITH HOLD issue | Check INVTRANS for prior failed recon; run RUNSQL to reset |

---

## Blend Order Status Flow

```
CR (Created)
  → NR (Not Released) — optional step for pre-check
    → RL (Released)    — set by BLNDVAL / SP_VALIDATE_BLEND
      → BL (Blending)  — set by FILLINIT when filling starts
        → YR (Yield Reconciliation) — set by YLDRECNC
          → QA (QA Review) — set if yield variance exceeded
            → CL (Closed)  — set by SP_CLOSE_BATCH
          → CL (Closed)    — set by SP_CLOSE_BATCH (if QA pre-approved)
      → VO (Voided) — can be set from CR/NR/RL
```

---

## QA Lot Status Flow

```
PE (Pending)
  → AP (Approved)   — after incoming inspection passes
  → RJ (Rejected)   — incoming inspection fail / non-conformance
  → HO (Hold)       — QA hold placed (SP_PLACE_QA_HOLD)
    → AP (Approved) — holds released (SP_RELEASE_HOLD), lab pass
    → DS (Destroyed)
  → QU (Quarantine) — awaiting disposition
  → RE (Retest)     — within shelf life, test interval exceeded
  → EX (Expired)    — past expiry date
  → RC (Recalled)   — product recall activated
```
