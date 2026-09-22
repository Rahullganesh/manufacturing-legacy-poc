**FREE
// =============================================================================
// PROGRAM:    RFCNTSCAN
// SYSTEM:     APEX Nutritional Manufacturing — IBM i
// PURPOSE:    RF Gun Container Scan — Fill Point
//             Entry point called by the RF handheld terminal when an
//             operator scans a container barcode at the filling line.
//             This is the most frequently executed program in the system —
//             approximately 4,000–6,000 scans per shift across all lines.
//
//             Processing flow:
//               1. Decode and validate the container barcode (GS1-128 format)
//               2. Verify the container is not already filled (no duplicate scan)
//               3. Validate the active blend order on the line
//               4. Read the fill weight from the in-line checkweigher
//                  (IIoT interface via CHKWGH data area)
//               5. Compare net weight to min/max weight spec from FORMSPEC
//               6. Classify weight status (OK / LO / HI / RE=Recheck)
//               7. Write CNTNRFIL record
//               8. Update LINESHFT fill counter
//               9. Trigger label print via LBLPRINT if weight OK
//              10. On underweight: alert operator, do not print label
//              11. On overweight: alert operator, log but allow (over-fill
//                  is product giveaway, not a safety issue)
//              12. Return response to RF terminal (1 = OK, 2 = Warn, 3 = Error)
//
//             KNOWN ISSUES / OPEN CHANGES:
//               CHG-2026-0044: Duplicate scan detection uses CHAIN which
//               takes a record lock. Under high volume (>500 cans/min)
//               this causes contention on CNTNRFIL. Proposed fix: use
//               SQL INSERT with IGNORE DUPLICATE KEY and check SQLCODE +23.
//               Target: Q4 2026. See INC-2025-0389 for the incident history.
//
//               CHG-2026-0051: Checkweigher IIoT data area (CHKWGH) is
//               refreshed every 200ms. If the program reads it before the
//               weigh cycle completes, it gets the previous container's
//               weight. Added 300ms delay (DLYJOB) as workaround.
//               Permanent fix: event-driven read via *DTAARA *CHANGE trigger.
//
// ENTRY PARMS:
//   I_DEVID    10A  RF Device / Scanner ID
//   I_BARCODE  48A  Raw barcode scan (GS1-128)
//   I_LINENO    4A  Manufacturing Line
//   I_OPRID    10A  Operator User ID
//   O_RFRESPC   1A  RF Response Code: 1=OK 2=Warning 3=Error
//   O_DISPMSG  40A  Message to display on RF terminal (40 char max)
//   O_CNTNRID  20A  Decoded Container ID
//   O_WTSTAT    2A  Weight Status: OK LO HI RE
//
// FILES:
//   CNTNRFIL  — Container Fill Records (output)
//   BLNDORDR  — Blend Order Master (input)
//   LINESHFT  — Line/Shift Log (update)
//   FORMSPEC  — Formula Specification (input, for weight limits)
//   LOTMSTR   — Lot Master (input)
//   LBLLOG    — Label Print Log (output via LBLPRINT call)
//
// CALLS:
//   LBLPRINT  — Label Print Driver
//   SNDMSG    — Send operator message
//   QSYSxxxx  — Checkweigher data area read
//
// MODIFIED:
//   2023-09-01  J.MARTINEZ  Initial version
//   2024-02-14  S.PATEL     Added GS1-128 barcode decode (AI parsing)
//   2024-07-20  R.CHEN      Added IIoT checkweigher read (CHKWGH *DTAARA)
//   2025-01-08  T.OKAFOR    Added DLYJOB 0.3s workaround (CHG-2026-0051)
//   2025-06-15  S.PATEL     Added RE (Recheck) weight status for borderline
//   2026-03-22  J.MARTINEZ  Added 5 consecutive underweight alert (shift QA)
//   2026-08-10  R.CHEN      Added checkweigher calibration date check
// =============================================================================

CTL-OPT DFTACTGRP(*NO) ACTGRP('APEXMFG') OPTION(*SRCSTMT *NODEBUGIO)
        DATEDIT(*YMD/) DATFMT(*ISO) TIMFMT(*ISO)
        EXPROPTS(*MAXDIGITS) TRUNCNBR(*NO);

// =============================================================================
// FILE DECLARATIONS
// =============================================================================
DCL-F CNTNRFIL DISK(*EXT) USAGE(*OUTPUT) KEYED INFDS(INFDS_CNTR) INFSR(*PSSR);
DCL-F BLNDORDR DISK(*EXT) USAGE(*INPUT)  KEYED INFDS(INFDS_BORD) INFSR(*PSSR);
DCL-F LINESHFT DISK(*EXT) USAGE(*UPDATE) KEYED INFDS(INFDS_LINE) INFSR(*PSSR);
DCL-F FORMSPEC DISK(*EXT) USAGE(*INPUT)  KEYED INFDS(INFDS_FORM) INFSR(*PSSR);
DCL-F LOTMSTR  DISK(*EXT) USAGE(*INPUT)  KEYED INFDS(INFDS_LOT)  INFSR(*PSSR);

// INFDS
DCL-DS INFDS_CNTR; CNTR_STATUS *STATUS; END-DS;
DCL-DS INFDS_BORD; BORD_STATUS *STATUS; END-DS;
DCL-DS INFDS_LINE; LINE_STATUS *STATUS; END-DS;
DCL-DS INFDS_FORM; FORM_STATUS *STATUS; END-DS;
DCL-DS INFDS_LOT;  LOT_STATUS  *STATUS; END-DS;

// =============================================================================
// GS1-128 Barcode Data Structure
// Standard AI codes used in nutritional manufacturing:
//   (00) = SSCC-18 container serial
//   (01) = GTIN-14 item number
//   (10) = Lot/Batch number
//   (17) = Expiry date YYMMDD
//   (310n) = Net weight in KG
// =============================================================================
DCL-DS DS_Barcode QUALIFIED;
    RawBarcode  CHAR(48)  INZ(*BLANKS);
    // Decoded fields
    ContainerID CHAR(20)  INZ(*BLANKS);   // AI 00 SSCC
    GtinItem    CHAR(18)  INZ(*BLANKS);   // AI 01 GTIN-14
    LotNumber   CHAR(16)  INZ(*BLANKS);   // AI 10 Lot
    ExpiryDate  CHAR(6)   INZ(*BLANKS);   // AI 17 YYMMDD
    NetWeightKG PACKED(7:3) INZ(0);       // AI 310n KG
    DecodeOK    IND       INZ(*OFF);
    DecodeErrMsg CHAR(60) INZ(*BLANKS);
END-DS;

// =============================================================================
// Checkweigher IIoT data area structure
// Data area APEXMFG/CHKWGH_Lnnn (e.g. CHKWGH_L001 for line 001)
// Updated every 200ms by the checkweigher PLC via iSeries DTAARA write
// =============================================================================
DCL-DS DS_Checkweigher;
    CW_GrossWt  PACKED(7:3) INZ(0);    // Gross weight KG
    CW_TareWt   PACKED(7:3) INZ(0);    // Tare weight KG
    CW_NetWt    PACKED(7:3) INZ(0);    // Net weight KG
    CW_ReadTime CHAR(6)     INZ(*BLANKS); // HHMMSS of last weigh
    CW_SeqNo    PACKED(7:0) INZ(0);    // Sequential weigh count
    CW_CalibDt  CHAR(8)     INZ(*BLANKS); // Last calibration CCYYMMDD
    CW_Status   CHAR(2)     INZ(*BLANKS); // OK ER=Error FA=Failed
END-DS;

// =============================================================================
// PROCEDURE INTERFACE
// =============================================================================
DCL-PI RFCNTSCAN;
    I_DEVID    CHAR(10)  CONST;
    I_BARCODE  CHAR(48)  CONST;
    I_LINENO   CHAR(4)   CONST;
    I_OPRID    CHAR(10)  CONST;
    O_RFRESPC  CHAR(1);       // 1=OK 2=Warn 3=Error
    O_DISPMSG  CHAR(40);
    O_CNTNRID  CHAR(20);
    O_WTSTAT   CHAR(2);
END-PI;

// =============================================================================
// CONSTANTS
// =============================================================================
DCL-C c_RF_OK       '1';
DCL-C c_RF_Warn     '2';
DCL-C c_RF_Error    '3';
DCL-C c_WT_OK       'OK';
DCL-C c_WT_Low      'LO';
DCL-C c_WT_High     'HI';
DCL-C c_WT_Recheck  'RE';
DCL-C c_RecheckBand 0.005;   // 0.5% either side of spec = recheck zone
DCL-C c_CW_CalibMax 90;      // Max days since calibration before warning
DCL-C c_UndwtAlert  5;       // Alert shift QA after N consecutive underweights

// =============================================================================
// WORKING VARIABLES
// =============================================================================
DCL-S w_CntnrID     CHAR(20)    INZ(*BLANKS);
DCL-S w_GrossWt     PACKED(7:3) INZ(0);
DCL-S w_TareWt      PACKED(7:3) INZ(0);
DCL-S w_NetWt       PACKED(7:3) INZ(0);
DCL-S w_MinWt       PACKED(7:3) INZ(0);
DCL-S w_MaxWt       PACKED(7:3) INZ(0);
DCL-S w_RecheckLow  PACKED(7:3) INZ(0);
DCL-S w_RecheckHigh PACKED(7:3) INZ(0);
DCL-S w_WtStat      CHAR(2)     INZ(c_WT_OK);
DCL-S w_BordNo      CHAR(10)    INZ(*BLANKS);
DCL-S w_LotNo       CHAR(16)    INZ(*BLANKS);
DCL-S w_ItemNo      CHAR(18)    INZ(*BLANKS);
DCL-S w_ContTyp     CHAR(6)     INZ(*BLANKS);
DCL-S w_ContSze     CHAR(10)    INZ(*BLANKS);
DCL-S w_FillSeq     PACKED(3:0) INZ(1);
DCL-S w_DupFound    IND         INZ(*OFF);
DCL-S w_DtaAraNm    CHAR(20)    INZ(*BLANKS);
DCL-S w_CalibDays   PACKED(5:0) INZ(0);
DCL-S w_UndwtCnt    PACKED(3:0) INZ(0);
DCL-S w_ShiftDt     DATE;
DCL-S w_ShiftNo     CHAR(1)     INZ(*BLANKS);
DCL-S w_PrtRslt     CHAR(2)     INZ(*BLANKS);
DCL-S w_RfMsgBuf    CHAR(40)    INZ(*BLANKS);

// SQL
EXEC SQL INCLUDE SQLCA;
EXEC SQL SET OPTION COMMIT    = *CHG,
                    CLOSQLCSR = *ENDMOD,
                    DATFMT    = *ISO,
                    TIMFMT    = *ISO;

// =============================================================================
// MAIN LINE
// =============================================================================

// Initialise
O_RFRESPC = c_RF_Error;
O_DISPMSG = 'SCAN ERROR';
O_CNTNRID = *BLANKS;
O_WTSTAT  = *BLANKS;

// --- Validate input ---
IF I_BARCODE = *BLANKS;
    O_DISPMSG = 'NO BARCODE — RESCAN';
    RETURN;
ENDIF;

IF I_LINENO = *BLANKS OR I_OPRID = *BLANKS OR I_DEVID = *BLANKS;
    O_DISPMSG = 'DEVICE SETUP ERROR';
    RETURN;
ENDIF;

// --- STEP 1: Decode barcode ---
DS_Barcode.RawBarcode = I_BARCODE;
EXSR SR_DecodeGS1Barcode;

IF NOT DS_Barcode.DecodeOK;
    O_RFRESPC = c_RF_Error;
    O_DISPMSG = %SUBST(DS_Barcode.DecodeErrMsg : 1 : 40);
    RETURN;
ENDIF;

w_CntnrID = DS_Barcode.ContainerID;
O_CNTNRID = w_CntnrID;

// --- STEP 2: Duplicate scan check ---
EXSR SR_CheckDuplicateScan;
IF w_DupFound;
    O_RFRESPC = c_RF_Error;
    O_DISPMSG = 'ALREADY SCANNED — CHECK CONTAINER';
    RETURN;
ENDIF;

// --- STEP 3: Get active blend order for this line ---
EXSR SR_GetActiveBlendOrder;
IF w_BordNo = *BLANKS;
    O_RFRESPC = c_RF_Error;
    O_DISPMSG = 'NO ACTIVE ORDER — CONTACT SUPER';
    RETURN;
ENDIF;

// --- STEP 4: Read checkweigher ---
EXSR SR_ReadCheckweigher;
// Non-fatal if CW fails — use barcode weight as fallback

// --- STEP 5: Get weight spec ---
EXSR SR_GetWeightSpec;

// --- STEP 6: Classify weight ---
EXSR SR_ClassifyWeight;

// --- STEP 7: Write container fill record ---
EXSR SR_WriteContainerFill;

// --- STEP 8: Update line shift counter ---
EXSR SR_UpdateLineShiftCounter;

// --- STEP 9: Print label (if OK or HI) ---
IF w_WtStat = c_WT_OK OR w_WtStat = c_WT_High;
    EXSR SR_TriggerLabelPrint;
ENDIF;

// --- STEP 10/11: Set RF response ---
SELECT;
    WHEN w_WtStat = c_WT_OK;
        O_RFRESPC = c_RF_OK;
        O_DISPMSG = 'OK   WT:' + %TRIM(%CHAR(w_NetWt)) + 'KG SCAN NEXT';
    WHEN w_WtStat = c_WT_Low;
        O_RFRESPC = c_RF_Error;
        O_DISPMSG = 'UNDERWEIGHT ' + %TRIM(%CHAR(w_NetWt))
                  + 'KG MIN:' + %TRIM(%CHAR(w_MinWt));
        EXSR SR_CheckConsecutiveUnderweight;
    WHEN w_WtStat = c_WT_High;
        O_RFRESPC = c_RF_Warn;
        O_DISPMSG = 'OVERWEIGHT ' + %TRIM(%CHAR(w_NetWt))
                  + 'KG MAX:' + %TRIM(%CHAR(w_MaxWt));
    WHEN w_WtStat = c_WT_Recheck;
        O_RFRESPC = c_RF_Warn;
        O_DISPMSG = 'RECHECK WEIGHT — RESCAN WHEN STABLE';
ENDSL;

O_WTSTAT = w_WtStat;
RETURN;

// =============================================================================
// SR_DecodeGS1Barcode
// Parses GS1-128 Application Identifiers from the raw barcode string.
// GS1-128 format: each field prefixed by an AI in parentheses e.g. (01)
// This parser handles fixed-length AIs (00, 01, 17) and
// variable-length AIs (10, 310n) delimited by FNC1 character (ASCII 29).
// =============================================================================
BEGSR SR_DecodeGS1Barcode;

    DCL-S w_Pos     PACKED(3:0) INZ(1);
    DCL-S w_AI      CHAR(4)     INZ(*BLANKS);
    DCL-S w_Data    CHAR(48)    INZ(*BLANKS);
    DCL-S w_RawLen  PACKED(3:0) INZ(0);
    DCL-S w_FNC1    CHAR(1)     INZ(X'1D');  // GS1 FNC1 separator

    DS_Barcode.DecodeOK = *OFF;

    w_RawLen = %LEN(%TRIM(I_BARCODE));

    IF w_RawLen < 6;
        DS_Barcode.DecodeErrMsg = 'Barcode too short (' + %TRIM(%CHAR(w_RawLen)) + ' chars)';
        RETURN;
    ENDIF;

    // Scan through the barcode for AI markers
    w_Pos = 1;
    DOW w_Pos <= w_RawLen;

        // Check for AI marker (open paren)
        IF %SUBST(I_BARCODE : w_Pos : 1) = '(';
            // Extract AI (2-4 digits between parens)
            IF %SUBST(I_BARCODE : w_Pos + 3 : 1) = ')';
                w_AI = %SUBST(I_BARCODE : w_Pos + 1 : 2);
                w_Pos += 4;
            ELSEIF %SUBST(I_BARCODE : w_Pos + 4 : 1) = ')';
                w_AI = %SUBST(I_BARCODE : w_Pos + 1 : 3);
                w_Pos += 5;
            ELSE;
                DS_Barcode.DecodeErrMsg = 'Malformed AI at position ' + %TRIM(%CHAR(w_Pos));
                RETURN;
            ENDIF;

            SELECT;
                // AI 00: SSCC-18 Container Serial (18 chars fixed)
                WHEN w_AI = '00';
                    DS_Barcode.ContainerID = %SUBST(I_BARCODE : w_Pos : 18);
                    w_Pos += 18;

                // AI 01: GTIN-14 Item (14 chars fixed)
                WHEN w_AI = '01';
                    DS_Barcode.GtinItem = %SUBST(I_BARCODE : w_Pos : 14);
                    w_Pos += 14;

                // AI 10: Lot/Batch (variable, terminated by FNC1 or end)
                WHEN w_AI = '10';
                    w_Data = *BLANKS;
                    DOW w_Pos <= w_RawLen AND
                        %SUBST(I_BARCODE : w_Pos : 1) <> w_FNC1 AND
                        %SUBST(I_BARCODE : w_Pos : 1) <> '(';
                        w_Data = %TRIM(w_Data) + %SUBST(I_BARCODE : w_Pos : 1);
                        w_Pos += 1;
                    ENDDO;
                    DS_Barcode.LotNumber = %SUBST(w_Data : 1 : 16);

                // AI 17: Expiry date YYMMDD (6 chars fixed)
                WHEN w_AI = '17';
                    DS_Barcode.ExpiryDate = %SUBST(I_BARCODE : w_Pos : 6);
                    w_Pos += 6;

                // AI 310n: Net Weight KG (n decimal places, 6 digit value)
                WHEN %SUBST(w_AI : 1 : 3) = '310';
                    DCL-S w_Decimals PACKED(1:0);
                    DCL-S w_WtStr    CHAR(6);
                    DCL-S w_WtNum    PACKED(7:0);
                    w_Decimals = %DEC(%SUBST(w_AI : 4 : 1) : 1 : 0);
                    w_WtStr    = %SUBST(I_BARCODE : w_Pos : 6);
                    w_WtNum    = %DEC(w_WtStr : 7 : 0);
                    DS_Barcode.NetWeightKG = w_WtNum / (%PARMS() ** w_Decimals);
                    w_Pos += 6;

                OTHER;
                    // Unknown AI — skip to next FNC1 or paren
                    DOW w_Pos <= w_RawLen AND
                        %SUBST(I_BARCODE : w_Pos : 1) <> w_FNC1 AND
                        %SUBST(I_BARCODE : w_Pos : 1) <> '(';
                        w_Pos += 1;
                    ENDDO;
            ENDSL;

        ELSE;
            w_Pos += 1;
        ENDIF;

    ENDDO;

    // Validation: Container ID must be populated
    IF DS_Barcode.ContainerID = *BLANKS;
        DS_Barcode.DecodeErrMsg = 'No container ID (AI 00) in barcode';
        RETURN;
    ENDIF;

    DS_Barcode.DecodeOK = *ON;

ENDSR;

// =============================================================================
// SR_CheckDuplicateScan
// =============================================================================
BEGSR SR_CheckDuplicateScan;

    DCL-S w_DupCnt PACKED(5:0) INZ(0);

    EXEC SQL
        SELECT COUNT(*)
        INTO   :w_DupCnt
        FROM   APEXMFG.CNTNRFIL
        WHERE  CFCNTNRID = :w_CntnrID
        AND    CFSTATUS  <> 'SC';   // Scrapped containers can be rescanned

    w_DupFound = (w_DupCnt > 0);

ENDSR;

// =============================================================================
// SR_GetActiveBlendOrder
// =============================================================================
BEGSR SR_GetActiveBlendOrder;

    EXEC SQL
        SELECT BORDNO, BFINLOT, BITEMNO, BSHIFTNO, CURRENT_DATE
        INTO   :w_BordNo, :w_LotNo, :w_ItemNo, :w_ShiftNo, :w_ShiftDt
        FROM   APEXMFG.BLNDORDR
        WHERE  BLINENO = :I_LINENO
        AND    BSTATUS = 'BL'
        ORDER BY BSTARTDT DESC
        FETCH FIRST 1 ROW ONLY;

    IF SQLCODE = 100;
        w_BordNo = *BLANKS;
    ENDIF;

ENDSR;

// =============================================================================
// SR_ReadCheckweigher
// Reads the IIoT checkweigher data area for this line.
// Data area name: CHKWGH_Lnnn where nnn = line number left-padded to 3.
// Workaround: DLYJOB 0.3s before read (CHG-2026-0051).
// =============================================================================
BEGSR SR_ReadCheckweigher;

    DCL-S w_CwDtaAra CHAR(10) INZ(*BLANKS);
    DCL-S w_CwRawDat CHAR(50) INZ(*BLANKS);
    DCL-S w_CalibDt  DATE;

    // Build data area name
    w_CwDtaAra = 'CHKWGH_L' + %TRIM(I_LINENO);

    // Delay 300ms to allow weigh cycle completion (CHG-2026-0051 workaround)
    EXEC SQL
        CALL QSYS2.QCMDEXC('DLYJOB DLY(0.3)');

    // Read data area
    EXEC SQL
        SELECT DTAARA_VALUE
        INTO   :w_CwRawDat
        FROM   TABLE(QSYS2.DATA_AREA_INFO(
                    DATA_AREA_NAME   => :w_CwDtaAra,
                    DATA_AREA_LIBRARY => 'APEXMFG'));

    IF SQLCODE <> 0;
        // Checkweigher read failed — fall back to barcode weight
        DS_Checkweigher.CW_Status = 'ER';
        DS_Checkweigher.CW_NetWt  = DS_Barcode.NetWeightKG;
        w_WarnBuf = 'CW READ FAILED-BARCODE WEIGHT USED;';
        RETURN;
    ENDIF;

    // Parse the raw data area (fixed layout, defined by PLC spec v2.3)
    DS_Checkweigher.CW_GrossWt  = %DEC(%SUBST(w_CwRawDat :  1 : 8) : 7 : 3);
    DS_Checkweigher.CW_TareWt   = %DEC(%SUBST(w_CwRawDat :  9 : 8) : 7 : 3);
    DS_Checkweigher.CW_NetWt    = %DEC(%SUBST(w_CwRawDat : 17 : 8) : 7 : 3);
    DS_Checkweigher.CW_ReadTime = %SUBST(w_CwRawDat : 25 : 6);
    DS_Checkweigher.CW_SeqNo    = %DEC(%SUBST(w_CwRawDat : 31 : 7) : 7 : 0);
    DS_Checkweigher.CW_CalibDt  = %SUBST(w_CwRawDat : 38 : 8);
    DS_Checkweigher.CW_Status   = %SUBST(w_CwRawDat : 46 : 2);

    IF DS_Checkweigher.CW_Status = 'FA';
        // Checkweigher failed / needs service
        O_RFRESPC = c_RF_Error;
        O_DISPMSG = 'CHECKWEIGHER FAILURE — CALL MAINTENANCE';
        RETURN;
    ENDIF;

    // Check calibration currency
    w_CalibDays = %DIFF(%DATE() : %DATE(DS_Checkweigher.CW_CalibDt : *ISO) : *DAYS);
    IF w_CalibDays > c_CW_CalibMax;
        // Log warning — don't block production but alert QA
        w_WarnBuf = 'CW CALIB OVERDUE (' + %TRIM(%CHAR(w_CalibDays)) + ' DAYS);';
    ENDIF;

    w_GrossWt = DS_Checkweigher.CW_GrossWt;
    w_TareWt  = DS_Checkweigher.CW_TareWt;
    w_NetWt   = DS_Checkweigher.CW_NetWt;

ENDSR;

// =============================================================================
// SR_GetWeightSpec
// Gets min/max weight spec from FORMSPEC for this item and container size
// =============================================================================
BEGSR SR_GetWeightSpec;

    EXEC SQL
        SELECT FSMINWT, FSMAXWT, FSCONTTYP, FSCONTSZE
        INTO   :w_MinWt, :w_MaxWt, :w_ContTyp, :w_ContSze
        FROM   APEXMFG.FORMSPEC FS
        JOIN   APEXMFG.BLNDORDR B ON B.BFORMCD  = FS.FSFORMCD
                                  AND B.BFORMVER = FS.FSFORMVER
        WHERE  B.BORDNO   = :w_BordNo
        AND    FS.FSACTIVE = 'Y'
        FETCH FIRST 1 ROW ONLY;

    IF SQLCODE <> 0;
        // Default to barcode weight — spec not found
        w_MinWt   = w_NetWt * 0.97;   // -3% default tolerance
        w_MaxWt   = w_NetWt * 1.03;   // +3% default tolerance
        w_WarnBuf = %TRIM(w_WarnBuf) + ' WEIGHT SPEC NOT FOUND — DEFAULT USED;';
    ENDIF;

    // Recheck band: 0.5% either side of min/max
    w_RecheckLow  = w_MinWt  * (1 + c_RecheckBand);
    w_RecheckHigh = w_MaxWt  * (1 - c_RecheckBand);

ENDSR;

// =============================================================================
// SR_ClassifyWeight
// =============================================================================
BEGSR SR_ClassifyWeight;

    SELECT;
        WHEN w_NetWt < w_MinWt AND w_NetWt >= (w_MinWt * (1 - c_RecheckBand));
            // Within recheck band below minimum
            w_WtStat = c_WT_Recheck;
        WHEN w_NetWt < w_MinWt;
            w_WtStat = c_WT_Low;
        WHEN w_NetWt > w_MaxWt AND w_NetWt <= (w_MaxWt * (1 + c_RecheckBand));
            // Within recheck band above maximum
            w_WtStat = c_WT_Recheck;
        WHEN w_NetWt > w_MaxWt;
            w_WtStat = c_WT_High;
        OTHER;
            w_WtStat = c_WT_OK;
    ENDSL;

ENDSR;

// =============================================================================
// SR_WriteContainerFill
// =============================================================================
BEGSR SR_WriteContainerFill;

    EXEC SQL
        INSERT INTO APEXMFG.CNTNRFIL (
            CFCNTNRID, CFSEQNO, CFBORDNO, CFLINENO,
            CFITEMNO,  CFLOTNO, CFCONTTYP, CFCONTSZE,
            CFTARWT,   CFGROSSWT, CFMINWT,  CFMAXWT,
            CFWTSTAT,  CFOPRID, CFSCANDT, CFSCANTM,
            CFDEVICID, CFPRTSTAT, CFSTATUS
        ) VALUES (
            :w_CntnrID, :w_FillSeq, :w_BordNo, :I_LINENO,
            :w_ItemNo,  :w_LotNo,  :w_ContTyp, :w_ContSze,
            :w_TareWt,  :w_GrossWt, :w_MinWt,  :w_MaxWt,
            :w_WtStat,  :I_OPRID,  CURRENT_DATE, CURRENT_TIME,
            :I_DEVID,  'NP',  'AC'
        );

    IF SQLCODE < 0;
        O_RFRESPC = c_RF_Error;
        O_DISPMSG = 'DB WRITE ERROR — RETRY OR CALL IT';
        // NOTE: CHG-2026-0044 — duplicate key SQLCODE +23 will occur here
        // under high volume. Current workaround: retry the scan.
        // When SQLCODE = +23, it is a true duplicate and CNTNRFIL record
        // already exists — do NOT write again.
    ENDIF;

ENDSR;

// =============================================================================
// SR_UpdateLineShiftCounter
// =============================================================================
BEGSR SR_UpdateLineShiftCounter;

    IF w_WtStat = c_WT_OK OR w_WtStat = c_WT_High;
        EXEC SQL
            UPDATE APEXMFG.LINESHFT
            SET    LSTOTFILL = LSTOTFILL + 1
            WHERE  LSLINENO  = :I_LINENO
            AND    LSSHIFTNO = :w_ShiftNo
            AND    LSSHIFTDT = :w_ShiftDt;
    ELSEIF w_WtStat = c_WT_Low;
        EXEC SQL
            UPDATE APEXMFG.LINESHFT
            SET    LSTOTREJ  = LSTOTREJ  + 1
            WHERE  LSLINENO  = :I_LINENO
            AND    LSSHIFTNO = :w_ShiftNo
            AND    LSSHIFTDT = :w_ShiftDt;
    ENDIF;

ENDSR;

// =============================================================================
// SR_TriggerLabelPrint
// Calls LBLPRINT to print the container label on the assigned printer
// =============================================================================
BEGSR SR_TriggerLabelPrint;

    DCL-S w_PrtRetCod CHAR(2)  INZ(*BLANKS);
    DCL-S w_PrtErrMsg CHAR(80) INZ(*BLANKS);
    DCL-S w_PrtId     CHAR(10) INZ(*BLANKS);

    // Get assigned printer for this line
    EXEC SQL
        SELECT LAPRINTER
        INTO   :w_PrtId
        FROM   APEXMFG.LINEATTR
        WHERE  LALINENO = :I_LINENO;

    IF SQLCODE <> 0;
        w_PrtId = 'LNPRTR' + %TRIM(I_LINENO);  // Default printer name convention
    ENDIF;

    CALLP LBLPRINT(w_CntnrID : w_BordNo : w_LotNo : w_ItemNo :
                   'PROD  ' : '001' : w_PrtId : I_OPRID :
                   w_PrtRetCod : w_PrtErrMsg);

    IF w_PrtRetCod = '00';
        EXEC SQL
            UPDATE APEXMFG.CNTNRFIL
            SET    CFPRTSTAT = 'PR',
                   CFPRTDT   = CURRENT_DATE,
                   CFPRTBY   = :I_OPRID
            WHERE  CFCNTNRID = :w_CntnrID
            AND    CFSEQNO   = :w_FillSeq;
    ELSE;
        EXEC SQL
            UPDATE APEXMFG.CNTNRFIL
            SET    CFPRTSTAT = 'ER'
            WHERE  CFCNTNRID = :w_CntnrID
            AND    CFSEQNO   = :w_FillSeq;
        w_WarnBuf = %TRIM(w_WarnBuf) + ' LABEL PRINT FAILED;';
    ENDIF;

ENDSR;

// =============================================================================
// SR_CheckConsecutiveUnderweight
// After N consecutive underweights on a line, alerts shift QA supervisor.
// Consecutive count is maintained in LINESHFT.LSCONSUW (not in DDS — SQL only).
// =============================================================================
BEGSR SR_CheckConsecutiveUnderweight;

    EXEC SQL
        SELECT LSCONSUW
        INTO   :w_UndwtCnt
        FROM   APEXMFG.LINESHFT
        WHERE  LSLINENO  = :I_LINENO
        AND    LSSHIFTNO = :w_ShiftNo
        AND    LSSHIFTDT = :w_ShiftDt;

    IF SQLCODE <> 0;
        RETURN;
    ENDIF;

    w_UndwtCnt += 1;

    EXEC SQL
        UPDATE APEXMFG.LINESHFT
        SET    LSCONSUW = :w_UndwtCnt
        WHERE  LSLINENO  = :I_LINENO
        AND    LSSHIFTNO = :w_ShiftNo
        AND    LSSHIFTDT = :w_ShiftDt;

    IF w_UndwtCnt >= c_UndwtAlert;
        // Send alert to shift QA supervisor via message queue
        EXEC SQL
            CALL QSYS2.QCMDEXC('SNDMSG MSG(''ALERT: ' || :I_LINENO ||
                ' has ' || TRIM(CHAR(:w_UndwtCnt)) ||
                ' consecutive underweights. QA review required.'') ' ||
                'TOUSR(SHIFTQA)');
    ENDIF;

ENDSR;

// =============================================================================
// *PSSR
// =============================================================================
BEGSR *PSSR;

    O_RFRESPC = c_RF_Error;
    O_DISPMSG = 'SYSTEM ERROR—CALL IT SUPPORT';

    EXEC SQL
        INSERT INTO APEXMFG.INVTRANS (
            ITTRANSTYP, ITITEMNO, ITLOTNO, ITBORDNO, ITQTY, ITUOM, ITREASON, ITCRTBY
        ) VALUES (
            'ADJN', :w_ItemNo, :w_LotNo, :w_BordNo, 0, 'KG',
            'RFCNTSCAN *PSSR: status=' || TRIM(CHAR(%STATUS())) ||
            ' device=' || :I_DEVID || ' barcode=' || SUBSTR(:I_BARCODE,1,20),
            :I_OPRID
        );

    RETURN;

ENDSR;
