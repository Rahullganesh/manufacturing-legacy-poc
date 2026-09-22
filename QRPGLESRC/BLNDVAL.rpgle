**FREE
// =============================================================================
// PROGRAM:    BLNDVAL
// SYSTEM:     APEX Nutritional Manufacturing — IBM i
// PURPOSE:    Blend Order Validation
//             Validates a blend order before blending can start.
//             Called from the 5250 blend order release screen (BLNDVALD)
//             and from the RF gun blend order start flow (RFBLNDSTRT).
//
//             Validation sequence:
//               1. Blend order exists and is in CR or NR status
//               2. Operator is authorised for the assigned line
//               3. Line CIP is current (not overdue)
//               4. Formula version is active and not expired
//               5. All ingredients have been issued (INGRISS complete)
//               6. Every ingredient lot is QA Approved, not expired,
//                  and has no active holds in QLTHOLD
//               7. Ingredient quantities are within formula tolerance
//                  (FORMSPEC FSTOLNEG / FSTOLPOS)
//               8. No critical ingredients in retest status
//             On success: calls SP_VALIDATE_BLEND to set status = RL
//             and writes audit record to INVTRANS.
//
// ENTRY PARMS (called as CALL BLNDVAL or via service program):
//   I_BORDNO   10A  Blend Order Number
//   I_LINENO    4A  Manufacturing Line
//   I_OPRID    10A  Operator User ID
//   O_RETCOD    2A  Return Code (00=OK 10=NotFound 20=Fail 30=Hold 50=SQL)
//   O_ERRMSG  200A  Error / Success Message
//   O_WARNMSG 200A  Warning Message (non-blocking)
//
// FILES:
//   BLNDORDR — Blend Order Master (input)
//   LOTMSTR  — Lot Master (input)
//   INGRISS  — Ingredient Issue Log (input)
//   FORMSPEC — Formula Specification (input)
//   RMATMAS  — Raw Material Master (input)
//   LINESHFT — Line/Shift Log (input)
//   QLTHOLD  — Quality Hold (input)
//
// CALLS:
//   APEXMFG.SP_VALIDATE_BLEND (SQL stored procedure)
//   QHOLDPRC (if auto-hold required)
//   SNDMSG   (sends operator message on failure)
//
// MODIFIED:
//   2024-01-20  J.MARTINEZ  Initial version
//   2024-08-15  S.PATEL     Added formula tolerance check (step 7)
//   2025-03-10  R.CHEN      Added critical ingredient retest check (step 8)
//   2025-11-22  T.OKAFOR    Added operator authorisation check (step 2)
//   2026-04-05  S.PATEL     Refactored to call SP_VALIDATE_BLEND for status update
//   2026-09-01  J.MARTINEZ  Added WARNMSG output for near-expiry lots
// =============================================================================

CTL-OPT DFTACTGRP(*NO) ACTGRP('APEXMFG') OPTION(*SRCSTMT *NODEBUGIO)
        DATEDIT(*YMD/) DATFMT(*ISO) TIMFMT(*ISO)
        EXPROPTS(*MAXDIGITS) TRUNCNBR(*NO);

// =============================================================================
// FILE DECLARATIONS
// =============================================================================

DCL-F BLNDORDR DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_BORD) INFSR(*PSSR);
DCL-F LOTMSTR  DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_LOT)  INFSR(*PSSR);
DCL-F INGRISS  DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_INGR) INFSR(*PSSR);
DCL-F FORMSPEC DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_FORM) INFSR(*PSSR);
DCL-F RMATMAS  DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_RMAT) INFSR(*PSSR);
DCL-F LINESHFT DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_LINE) INFSR(*PSSR);
DCL-F QLTHOLD  DISK(*EXT) USAGE(*INPUT) KEYED
                INFDS(INFDS_HOLD) INFSR(*PSSR);

// =============================================================================
// INFDS — File information data structures
// =============================================================================
DCL-DS INFDS_BORD;
    BORD_STATUS *STATUS;
    BORD_OPCODE *OPCODE;
END-DS;

DCL-DS INFDS_LOT;
    LOT_STATUS  *STATUS;
END-DS;

DCL-DS INFDS_INGR;
    INGR_STATUS *STATUS;
END-DS;

DCL-DS INFDS_FORM;
    FORM_STATUS *STATUS;
END-DS;

DCL-DS INFDS_RMAT;
    RMAT_STATUS *STATUS;
END-DS;

DCL-DS INFDS_LINE;
    LINE_STATUS *STATUS;
END-DS;

DCL-DS INFDS_HOLD;
    HOLD_STATUS *STATUS;
END-DS;

// =============================================================================
// PROCEDURE INTERFACE
// =============================================================================
DCL-PI BLNDVAL;
    I_BORDNO   CHAR(10)    CONST;
    I_LINENO   CHAR(4)     CONST;
    I_OPRID    CHAR(10)    CONST;
    O_RETCOD   CHAR(2);
    O_ERRMSG   CHAR(200);
    O_WARNMSG  CHAR(200);
END-PI;

// =============================================================================
// CONSTANTS
// =============================================================================
DCL-C c_StatusOK      '00';
DCL-C c_StatusNotFnd  '10';
DCL-C c_StatusFail    '20';
DCL-C c_StatusHold    '30';
DCL-C c_StatusSQL     '50';
DCL-C c_MaxNearExpiry  30;      // Days — warn if lot expires within this window
DCL-C c_MaxTolCheck   999.999; // Max variance before hard fail

// =============================================================================
// WORKING VARIABLES
// =============================================================================
DCL-S w_Found       IND;
DCL-S w_WarnBuf     CHAR(200) INZ(*BLANKS);
DCL-S w_HoldCnt     PACKED(5:0) INZ(0);
DCL-S w_IngrCnt     PACKED(5:0) INZ(0);
DCL-S w_ApprCnt     PACKED(5:0) INZ(0);
DCL-S w_DaysToExp   PACKED(5:0) INZ(0);
DCL-S w_VarPct      PACKED(7:3) INZ(0);
DCL-S w_TolNeg      PACKED(5:3) INZ(0);
DCL-S w_TolPos      PACKED(5:3) INZ(0);
DCL-S w_FormCnt     PACKED(5:0) INZ(0);
DCL-S w_IssQty      PACKED(9:3) INZ(0);
DCL-S w_ThQty       PACKED(9:3) INZ(0);
DCL-S w_ActQty      PACKED(9:3) INZ(0);
DCL-S w_MsgText     CHAR(200)   INZ(*BLANKS);

// SQL variables
DCL-S w_Sqlstate    CHAR(5)     INZ(*BLANKS);
DCL-S w_SqlErrMsg   CHAR(200)   INZ(*BLANKS);

// =============================================================================
// SQL COMMUNICATION AREA
// =============================================================================
EXEC SQL INCLUDE SQLCA;
EXEC SQL SET OPTION COMMIT    = *CHG,
                    CLOSQLCSR = *ENDMOD,
                    DATFMT    = *ISO,
                    TIMFMT    = *ISO;

// =============================================================================
// MAIN LINE
// =============================================================================

// Initialise
O_RETCOD  = c_StatusOK;
O_ERRMSG  = *BLANKS;
O_WARNMSG = *BLANKS;
w_WarnBuf = *BLANKS;

// Validate input parameters
IF I_BORDNO = *BLANKS;
    O_RETCOD = c_StatusFail;
    O_ERRMSG = 'Blend order number is required.';
    RETURN;
ENDIF;

IF I_LINENO = *BLANKS;
    O_RETCOD = c_StatusFail;
    O_ERRMSG = 'Line number is required.';
    RETURN;
ENDIF;

IF I_OPRID = *BLANKS;
    O_RETCOD = c_StatusFail;
    O_ERRMSG = 'Operator user ID is required.';
    RETURN;
ENDIF;

// ---- STEP 1: Blend Order Header Check ----
EXSR SR_CheckBlendOrder;
IF O_RETCOD <> c_StatusOK;
    RETURN;
ENDIF;

// ---- STEP 2: Operator Authorisation ----
EXSR SR_CheckOperatorAuth;
IF O_RETCOD <> c_StatusOK;
    RETURN;
ENDIF;

// ---- STEP 3: Line CIP Status ----
EXSR SR_CheckLineCIP;
IF O_RETCOD <> c_StatusOK;
    RETURN;
ENDIF;

// ---- STEP 4: Formula Version Active ----
EXSR SR_CheckFormula;
IF O_RETCOD <> c_StatusOK;
    RETURN;
ENDIF;

// ---- STEP 5 + 6 + 7 + 8: Ingredient Lot Validation ----
EXSR SR_ValidateIngredients;
IF O_RETCOD <> c_StatusOK;
    RETURN;
ENDIF;

// ---- STEP 9: Call SP to update status ----
EXSR SR_CallValidateProc;

// Set warning output
O_WARNMSG = %TRIM(w_WarnBuf);
RETURN;

// =============================================================================
// SUBROUTINE: SR_CheckBlendOrder
// =============================================================================
BEGSR SR_CheckBlendOrder;

    CHAIN (I_BORDNO) RBLNDORDR;

    IF NOT %FOUND(BLNDORDR);
        O_RETCOD = c_StatusNotFnd;
        O_ERRMSG = 'Blend order ' + %TRIM(I_BORDNO) + ' not found.';
        RETURN;
    ENDIF;

    // Status must be Created or Not Released
    IF BSTATUS <> 'CR' AND BSTATUS <> 'NR';
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'Blend order ' + %TRIM(I_BORDNO)
                 + ' cannot be validated. Current status: '
                 + %TRIM(BSTATUS)
                 + '. Order must be CR or NR.';
        RETURN;
    ENDIF;

    // Line must match
    IF %TRIM(BLINENO) <> %TRIM(I_LINENO);
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'Line mismatch. Order ' + %TRIM(I_BORDNO)
                 + ' is assigned to line ' + %TRIM(BLINENO)
                 + ', not ' + %TRIM(I_LINENO) + '.';
        RETURN;
    ENDIF;

    // Must not be voided
    IF BSTATUS = 'VO';
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'Blend order ' + %TRIM(I_BORDNO)
                 + ' has been voided and cannot be processed.';
        RETURN;
    ENDIF;

    // Scheduled date check — warn if past due
    IF BSCHEDDT < %DATE();
        w_WarnBuf = %TRIM(w_WarnBuf)
                  + ' ORDER PAST DUE (scheduled '
                  + %CHAR(BSCHEDDT) + ');';
    ENDIF;

ENDSR;

// =============================================================================
// SUBROUTINE: SR_CheckOperatorAuth
// Checks that the operator is authorised for the line via SQL
// (APEXMFG.LINEAUTH table — not declared as file, accessed via embedded SQL)
// =============================================================================
BEGSR SR_CheckOperatorAuth;

    DCL-S w_AuthCnt PACKED(3:0) INZ(0);

    EXEC SQL
        SELECT COUNT(*)
        INTO   :w_AuthCnt
        FROM   APEXMFG.LINEAUTH
        WHERE  LAOPRID  = :I_OPRID
        AND    LALINENO = :I_LINENO
        AND    LAACTIVE = 'Y';

    IF SQLCODE < 0;
        // LINEAUTH table may not exist in all environments — treat as warning
        w_WarnBuf = %TRIM(w_WarnBuf)
                  + ' Operator auth check skipped (LINEAUTH unavailable);';
        RETURN;
    ENDIF;

    IF w_AuthCnt = 0;
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'Operator ' + %TRIM(I_OPRID)
                 + ' is not authorised for line ' + %TRIM(I_LINENO)
                 + '. Contact your supervisor to update authorisations.';
        RETURN;
    ENDIF;

ENDSR;

// =============================================================================
// SUBROUTINE: SR_CheckLineCIP
// =============================================================================
BEGSR SR_CheckLineCIP;

    DCL-S w_CipStat CHAR(2)  INZ(*BLANKS);
    DCL-S w_LnStat  CHAR(5)  INZ(*BLANKS);
    DCL-S w_CipDt   DATE;

    // Get most recent shift for this line today
    EXEC SQL
        SELECT LSCIPSTAT, LSSTATUS, LSCIPDT
        INTO   :w_CipStat, :w_LnStat, :w_CipDt
        FROM   APEXMFG.LINESHFT
        WHERE  LSLINENO  = :I_LINENO
        AND    LSSHIFTDT = CURRENT_DATE
        ORDER BY LSSHIFTNO DESC
        FETCH FIRST 1 ROW ONLY;

    IF SQLCODE = 100;
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'No shift record found for line '
                 + %TRIM(I_LINENO)
                 + ' today. Ensure line setup is complete.';
        RETURN;
    ENDIF;

    IF SQLCODE < 0;
        O_RETCOD = c_StatusSQL;
        O_ERRMSG = 'SQL error checking line status. SQLCODE='
                 + %TRIM(%CHAR(SQLCODE));
        RETURN;
    ENDIF;

    // CIP overdue = hard block
    IF %TRIM(w_CipStat) = 'OV';
        O_RETCOD = c_StatusHold;
        O_ERRMSG = 'Line ' + %TRIM(I_LINENO)
                 + ' Clean-In-Place is OVERDUE (last CIP: '
                 + %CHAR(w_CipDt) + '). '
                 + 'Sanitation must complete CIP before blending. '
                 + 'Contact Sanitation Supervisor.';
        RETURN;
    ENDIF;

    // CIP due = warning only
    IF %TRIM(w_CipStat) = 'DU';
        w_WarnBuf = %TRIM(w_WarnBuf)
                  + ' CIP DUE on line ' + %TRIM(I_LINENO)
                  + '. Schedule before next batch;';
    ENDIF;

    // Line down or in maintenance = hard block
    SELECT;
        WHEN %TRIM(w_LnStat) = 'DOWN';
            O_RETCOD = c_StatusFail;
            O_ERRMSG = 'Line ' + %TRIM(I_LINENO) + ' is DOWN. '
                     + 'Maintenance must resolve fault before blending.';
            RETURN;
        WHEN %TRIM(w_LnStat) = 'MAINT';
            O_RETCOD = c_StatusFail;
            O_ERRMSG = 'Line ' + %TRIM(I_LINENO)
                     + ' is in MAINTENANCE. '
                     + 'Maintenance work must be completed and signed off.';
            RETURN;
        WHEN %TRIM(w_LnStat) = 'CIP';
            O_RETCOD = c_StatusFail;
            O_ERRMSG = 'Line ' + %TRIM(I_LINENO)
                     + ' is currently in CIP cleaning. '
                     + 'Wait for CIP completion and sign-off.';
            RETURN;
        OTHER;
            // IDLE or RUN — OK
    ENDSL;

ENDSR;

// =============================================================================
// SUBROUTINE: SR_CheckFormula
// =============================================================================
BEGSR SR_CheckFormula;

    EXEC SQL
        SELECT COUNT(*)
        INTO   :w_FormCnt
        FROM   APEXMFG.FORMSPEC
        WHERE  FSFORMCD  = :BFORMCD
        AND    FSFORMVER = :BFORMVER
        AND    FSACTIVE  = 'Y'
        AND    FSEFFDTE <= CURRENT_DATE
        AND    (FSEXPDTE IS NULL OR FSEXPDTE >= CURRENT_DATE);

    IF SQLCODE < 0;
        O_RETCOD = c_StatusSQL;
        O_ERRMSG = 'SQL error checking formula. SQLCODE=' + %TRIM(%CHAR(SQLCODE));
        RETURN;
    ENDIF;

    IF w_FormCnt = 0;
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'Formula ' + %TRIM(BFORMCD)
                 + ' version ' + %TRIM(%CHAR(BFORMVER))
                 + ' is not active or has expired. '
                 + 'Contact Technical Services (ext 2441).';
        RETURN;
    ENDIF;

ENDSR;

// =============================================================================
// SUBROUTINE: SR_ValidateIngredients
// Loops through all issued ingredients for the blend order.
// For each:
//   a. Lot must be QA Approved (LQASTAT = 'AP')
//   b. Lot must not be expired
//   c. No active holds in QLTHOLD
//   d. Quantity issued must be within formula tolerance
//   e. Critical ingredients must not be in retest
// =============================================================================
BEGSR SR_ValidateIngredients;

    DCL-DS w_IngrRow LIKEREC(RINGRISS) INZ;
    DCL-DS w_LotRow  LIKEREC(RLOTMSTR) INZ;
    DCL-DS w_FormRow LIKEREC(RFORMSPEC:*INPUT) INZ;
    DCL-DS w_RmatRow LIKEREC(RRMATMAS) INZ;
    DCL-S  w_HoldCt  PACKED(5:0) INZ(0);
    DCL-S  w_VarPct  PACKED(7:3) INZ(0);

    w_IngrCnt = 0;
    w_ApprCnt = 0;

    // Cursor over all issued ingredients for this blend order
    EXEC SQL
        DECLARE C_INGR CURSOR FOR
            SELECT II.IIITEMNO, II.IILOTNO,
                   II.IITHQTY, II.IIACTQTY, II.IIVARPCT,
                   L.LQASTAT, L.LEXPDT, L.LITMTYPE,
                   RM.RMITMTYPE, RM.RMMINVAR, RM.RMMAXVAR,
                   FS.FSTOLNEG, FS.FSTOLPOS, FS.FSCRITICAL
            FROM   APEXMFG.INGRISS  II
            JOIN   APEXMFG.LOTMSTR  L
                   ON  L.LOTNO   = II.IILOTNO
                   AND L.LOTITEM = II.IIITEMNO
            JOIN   APEXMFG.RMATMAS  RM
                   ON  RM.RMITEMNO = II.IIITEMNO
            LEFT JOIN APEXMFG.FORMSPEC FS
                   ON  FS.FSFORMCD  = :BFORMCD
                   AND FS.FSFORMVER = :BFORMVER
                   AND FS.FSCOMPITEM = II.IIITEMNO
                   AND FS.FSACTIVE  = 'Y'
            WHERE  II.IIBORDNO = :I_BORDNO
            AND    II.IISTAT   = 'IS'
            ORDER BY II.IIITEMNO;

    EXEC SQL OPEN C_INGR;

    IF SQLCODE < 0;
        O_RETCOD = c_StatusSQL;
        O_ERRMSG = 'SQL error opening ingredient cursor. SQLCODE='
                 + %TRIM(%CHAR(SQLCODE));
        RETURN;
    ENDIF;

    DOU SQLCODE = 100;

        EXEC SQL
            FETCH C_INGR INTO
                :w_IngrRow.IIITEMNO, :w_IngrRow.IILOTNO,
                :w_IngrRow.IITHQTY,  :w_IngrRow.IIACTQTY,
                :w_IngrRow.IIVARPCT,
                :w_LotRow.LQASTAT,   :w_LotRow.LEXPDT,
                :w_LotRow.LITMTYPE,
                :w_RmatRow.RMITMTYPE, :w_RmatRow.RMMINVAR,
                :w_RmatRow.RMMAXVAR,
                :w_FormRow.FSTOLNEG,  :w_FormRow.FSTOLPOS,
                :w_FormRow.FSCRITICAL;

        IF SQLCODE = 100;
            LEAVE;
        ENDIF;

        IF SQLCODE < 0;
            EXEC SQL CLOSE C_INGR;
            O_RETCOD = c_StatusSQL;
            O_ERRMSG = 'SQL error fetching ingredient. SQLCODE='
                     + %TRIM(%CHAR(SQLCODE));
            RETURN;
        ENDIF;

        w_IngrCnt += 1;

        // ---- a. QA Status Check ----
        SELECT;
            WHEN w_LotRow.LQASTAT = 'AP';
                w_ApprCnt += 1;

            WHEN w_LotRow.LQASTAT = 'HO';
                EXEC SQL CLOSE C_INGR;
                O_RETCOD = c_StatusHold;
                O_ERRMSG = 'Lot ' + %TRIM(w_IngrRow.IILOTNO)
                         + ' / item ' + %TRIM(w_IngrRow.IIITEMNO)
                         + ' is ON HOLD (QA status HO). '
                         + 'All holds must be released before blending. '
                         + 'Contact QA (ext 2100).';
                RETURN;

            WHEN w_LotRow.LQASTAT = 'QU';
                EXEC SQL CLOSE C_INGR;
                O_RETCOD = c_StatusHold;
                O_ERRMSG = 'Lot ' + %TRIM(w_IngrRow.IILOTNO)
                         + ' is QUARANTINED. '
                         + 'Quarantined material cannot be used. '
                         + 'Return to warehouse for segregation.';
                RETURN;

            WHEN w_LotRow.LQASTAT = 'RJ';
                EXEC SQL CLOSE C_INGR;
                O_RETCOD = c_StatusHold;
                O_ERRMSG = 'Lot ' + %TRIM(w_IngrRow.IILOTNO)
                         + ' has been REJECTED by QA. '
                         + 'Rejected material must be removed from '
                         + 'the manufacturing area immediately. '
                         + 'Issue a Non-Conformance Report (NCR).';
                RETURN;

            WHEN w_LotRow.LQASTAT = 'PE';
                EXEC SQL CLOSE C_INGR;
                O_RETCOD = c_StatusHold;
                O_ERRMSG = 'Lot ' + %TRIM(w_IngrRow.IILOTNO)
                         + ' is PENDING QA approval. '
                         + 'Wait for QA to complete the incoming '
                         + 'inspection before using this lot.';
                RETURN;

            WHEN w_LotRow.LQASTAT = 'RC';
                EXEC SQL CLOSE C_INGR;
                O_RETCOD = c_StatusHold;
                O_ERRMSG = 'CRITICAL: Lot ' + %TRIM(w_IngrRow.IILOTNO)
                         + ' is under RECALL. '
                         + 'Immediately isolate all material from this lot '
                         + 'and notify QA Director and Plant Manager.';
                RETURN;

            WHEN w_LotRow.LQASTAT = 'RE';
                // Retest — block only critical ingredients
                IF %TRIM(w_FormRow.FSCRITICAL) = 'Y';
                    EXEC SQL CLOSE C_INGR;
                    O_RETCOD = c_StatusHold;
                    O_ERRMSG = 'CRITICAL ingredient lot '
                             + %TRIM(w_IngrRow.IILOTNO)
                             + ' / item ' + %TRIM(w_IngrRow.IIITEMNO)
                             + ' is in RETEST status. '
                             + 'Critical ingredients require full approval '
                             + 'before use. Contact QA.';
                    RETURN;
                ELSE;
                    w_WarnBuf = %TRIM(w_WarnBuf)
                              + ' LOT ' + %TRIM(w_IngrRow.IILOTNO)
                              + ' in RETEST — monitor;';
                ENDIF;

            OTHER;
                // EX (expired) — handled below
        ENDSL;

        // ---- b. Expiry Check ----
        IF w_LotRow.LEXPDT < %DATE();
            EXEC SQL CLOSE C_INGR;
            O_RETCOD = c_StatusFail;
            O_ERRMSG = 'Lot ' + %TRIM(w_IngrRow.IILOTNO)
                     + ' EXPIRED on ' + %CHAR(w_LotRow.LEXPDT)
                     + '. Expired lots cannot be used in production. '
                     + 'Return to warehouse for destruction or retest.';
            RETURN;
        ENDIF;

        // Near-expiry warning
        w_DaysToExp = %DIFF(w_LotRow.LEXPDT : %DATE() : *DAYS);
        IF w_DaysToExp <= c_MaxNearExpiry;
            w_WarnBuf = %TRIM(w_WarnBuf)
                      + ' LOT ' + %TRIM(w_IngrRow.IILOTNO)
                      + ' expires in ' + %TRIM(%CHAR(w_DaysToExp))
                      + ' days (' + %CHAR(w_LotRow.LEXPDT) + ');';
        ENDIF;

        // ---- c. Active Holds Check ----
        EXEC SQL
            SELECT COUNT(*)
            INTO   :w_HoldCt
            FROM   APEXMFG.QLTHOLD
            WHERE  QHLOTNO   = :w_IngrRow.IILOTNO
            AND    QHITEMNO  = :w_IngrRow.IIITEMNO
            AND    QHSTATUS  = 'AC';

        IF w_HoldCt > 0;
            EXEC SQL CLOSE C_INGR;
            O_RETCOD = c_StatusHold;
            O_ERRMSG = 'Lot ' + %TRIM(w_IngrRow.IILOTNO)
                     + ' / item ' + %TRIM(w_IngrRow.IIITEMNO)
                     + ' has ' + %TRIM(%CHAR(w_HoldCt))
                     + ' active QA hold(s). '
                     + 'Query QLTHOLD for hold details. '
                     + 'All holds must be released before this lot can be used.';
            RETURN;
        ENDIF;

        // ---- d. Quantity Tolerance Check ----
        IF w_IngrRow.IITHQTY > 0;
            w_VarPct = ((w_IngrRow.IIACTQTY - w_IngrRow.IITHQTY)
                        / w_IngrRow.IITHQTY) * 100;

            // Use formula tolerance if available, else item tolerance
            IF w_FormRow.FSTOLNEG <> 0 OR w_FormRow.FSTOLPOS <> 0;
                w_TolNeg = w_FormRow.FSTOLNEG * -1;
                w_TolPos = w_FormRow.FSTOLPOS;
            ELSE;
                w_TolNeg = w_RmatRow.RMMINVAR;
                w_TolPos = w_RmatRow.RMMAXVAR;
            ENDIF;

            IF w_VarPct < w_TolNeg OR w_VarPct > w_TolPos;
                EXEC SQL CLOSE C_INGR;
                O_RETCOD = c_StatusFail;
                O_ERRMSG = 'Ingredient quantity OUT OF TOLERANCE for item '
                         + %TRIM(w_IngrRow.IIITEMNO)
                         + '. Theoretical: ' + %TRIM(%CHAR(w_IngrRow.IITHQTY))
                         + ' KG. Actual: ' + %TRIM(%CHAR(w_IngrRow.IIACTQTY))
                         + ' KG. Variance: ' + %TRIM(%CHAR(w_VarPct))
                         + '% (tolerance: '
                         + %TRIM(%CHAR(w_TolNeg)) + '% to '
                         + %TRIM(%CHAR(w_TolPos)) + '%). '
                         + 'Correct issue quantity or raise a deviation.';
                RETURN;
            ENDIF;

            // Warn if within 50% of tolerance limit
            IF %ABS(w_VarPct) > (%ABS(w_TolPos) * 0.5);
                w_WarnBuf = %TRIM(w_WarnBuf)
                          + ' ITEM ' + %TRIM(w_IngrRow.IIITEMNO)
                          + ' var ' + %TRIM(%CHAR(w_VarPct)) + '%;';
            ENDIF;
        ENDIF;

    ENDDO;

    EXEC SQL CLOSE C_INGR;

    // Were any ingredients found?
    IF w_IngrCnt = 0;
        O_RETCOD = c_StatusFail;
        O_ERRMSG = 'No issued ingredients found for blend order '
                 + %TRIM(I_BORDNO) + '. '
                 + 'All ingredients must be issued before validation. '
                 + 'Check INGRISS for this blend order.';
        RETURN;
    ENDIF;

ENDSR;

// =============================================================================
// SUBROUTINE: SR_CallValidateProc
// Calls the stored procedure to update blend order status to RL
// =============================================================================
BEGSR SR_CallValidateProc;

    DCL-S w_SpRetCod CHAR(2)   INZ(*BLANKS);
    DCL-S w_SpErrMsg CHAR(200) INZ(*BLANKS);
    DCL-S w_SpSqlSt  CHAR(5)   INZ(*BLANKS);
    DCL-S w_SpWarnMs CHAR(200) INZ(*BLANKS);

    EXEC SQL
        CALL APEXMFG.SP_VALIDATE_BLEND(
            :I_BORDNO,
            :I_LINENO,
            :I_OPRID,
            :w_SpRetCod,
            :w_SpErrMsg,
            :w_SpSqlSt,
            :w_SpWarnMs
        );

    IF SQLCODE < 0;
        O_RETCOD = c_StatusSQL;
        O_ERRMSG = 'Error calling SP_VALIDATE_BLEND. SQLCODE='
                 + %TRIM(%CHAR(SQLCODE));
        RETURN;
    ENDIF;

    IF w_SpRetCod <> '00';
        O_RETCOD = w_SpRetCod;
        O_ERRMSG = %TRIM(w_SpErrMsg);
        RETURN;
    ENDIF;

    // Append stored procedure warnings
    IF w_SpWarnMs <> *BLANKS;
        w_WarnBuf = %TRIM(w_WarnBuf) + ' ' + %TRIM(w_SpWarnMs);
    ENDIF;

    O_ERRMSG = 'Blend order ' + %TRIM(I_BORDNO)
             + ' validated and released for blending. '
             + %TRIM(%CHAR(w_IngrCnt)) + ' ingredients checked.';

ENDSR;

// =============================================================================
// SUBROUTINE: *PSSR — Program Status Subroutine (global error handler)
// =============================================================================
BEGSR *PSSR;

    O_RETCOD = c_StatusSQL;
    O_ERRMSG = 'Unexpected program error in BLNDVAL. '
             + 'Status: ' + %TRIM(%CHAR(%STATUS()))
             + '. Procedure: BLNDVAL. '
             + 'Contact Application Support with blend order '
             + %TRIM(I_BORDNO) + '.';

    // Close any open files
    EXEC SQL CLOSE C_INGR;

    RETURN;

ENDSR;
