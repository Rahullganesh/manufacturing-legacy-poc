**FREE
// =============================================================================
// PROGRAM:    YLDRECNC
// SYSTEM:     APEX Nutritional Manufacturing — IBM i
// PURPOSE:    Yield Reconciliation
//             Reconciles theoretical vs actual yield at end of blend.
//             Run by the shift supervisor from the blend order close screen
//             or automatically triggered by BATCHCLS after all containers
//             have been filled and labelled.
//
//             Processing:
//               1. Calculate theoretical yield from blend order BTHQTY
//               2. Calculate actual yield: sum of net weights in CNTNRFIL
//                  where CFSTATUS = AC and CFWTSTAT in (OK, HI)
//                  (underweight and scrapped containers excluded)
//               3. Calculate variance qty and variance pct
//               4. Compare to YVMAXVAR (from FORMSPEC or system default 3%)
//               5. If variance within spec: write YLDVARNC OK
//               6. If variance exceeds spec:
//                  a. Write YLDVARNC with YVVARSTAT = EX
//                  b. Auto-place QA hold on finished lot via SP_PLACE_QA_HOLD
//                  c. Update blend order BQASTAT = HO
//                  d. Send alert to QA supervisor
//               7. If variance is negative > -10% (severe short fill):
//                  a. Alert Plant Manager
//                  b. Log as P1 incident in INVTRANS
//
//             RECONCILIATION RULES (per QA SOP-APEX-0088 Rev 4):
//               Acceptable yield variance: +/- 3.0% (can be tightened per formula)
//               Severe short fill: < -10% requires Plant Manager sign-off
//               Severe over-fill: > +5% requires Technical Services review
//                 (over-fill means too much product in cans = cost impact)
//               Rejected containers: not counted in actual yield
//               Recheck containers (RE): counted if subsequent scan = OK
//
//             KNOWN ISSUES:
//               If CNTNRFIL has rows with CFWTSTAT = RE that were never
//               resolved (operator did not rescan after line stoppage),
//               those containers are excluded from actual yield. This can
//               artificially inflate the negative variance and trigger
//               a false QA hold. INC-2026-0198 documents an incident where
//               14 unresolved RE scans on line L003 caused a -4.2% variance
//               and an unnecessary QA hold on lot LT2026-88412.
//               Fix: BATCHCLS now checks for unresolved RE before calling
//               YLDRECNC. But if called directly, this check is bypassed.
//               CHG-2026-0062: Add RE check to YLDRECNC itself. Open.
//
// ENTRY PARMS:
//   I_BORDNO   10A  Blend Order Number
//   I_OPRID    10A  Operator / Supervisor User ID
//   O_RETCOD    2A  Return Code
//   O_ERRMSG  200A  Error / Info Message
//   O_VARPCT    7  3  Calculated Variance Percent
//   O_VARSTAT   2A  Variance Status: OK EX
//
// MODIFIED:
//   2024-05-01  J.MARTINEZ  Initial version
//   2025-02-18  S.PATEL     Added severe short fill alert (Plant Manager)
//   2025-09-10  R.CHEN      Added RE container exclusion warning
//   2026-01-25  T.OKAFOR    Added auto QA hold call via SP_PLACE_QA_HOLD
//   2026-07-14  S.PATEL     Added per-formula max variance from FORMSPEC
// =============================================================================

CTL-OPT DFTACTGRP(*NO) ACTGRP('APEXMFG') OPTION(*SRCSTMT *NODEBUGIO)
        DATEDIT(*YMD/) DATFMT(*ISO) TIMFMT(*ISO)
        EXPROPTS(*MAXDIGITS) TRUNCNBR(*NO);

DCL-PI YLDRECNC;
    I_BORDNO  CHAR(10)     CONST;
    I_OPRID   CHAR(10)     CONST;
    O_RETCOD  CHAR(2);
    O_ERRMSG  CHAR(200);
    O_VARPCT  PACKED(7:3);
    O_VARSTAT CHAR(2);
END-PI;

DCL-C c_StatusOK       '00';
DCL-C c_StatusNotFnd   '10';
DCL-C c_StatusFail     '20';
DCL-C c_StatusHold     '30';
DCL-C c_StatusSQL      '50';
DCL-C c_DefaultMaxVar  3.000;
DCL-C c_SevereNegVar  -10.000;
DCL-C c_SevereOvrVar   5.000;
DCL-C c_DesP1Sev       1;

DCL-S w_ThQty      PACKED(9:3)  INZ(0);
DCL-S w_ActQty     PACKED(9:3)  INZ(0);
DCL-S w_RejQty     PACKED(9:3)  INZ(0);
DCL-S w_ScpQty     PACKED(9:3)  INZ(0);
DCL-S w_VarQty     PACKED(9:3)  INZ(0);
DCL-S w_VarPct     PACKED(7:3)  INZ(0);
DCL-S w_MaxVar     PACKED(5:2)  INZ(c_DefaultMaxVar);
DCL-S w_VarStat    CHAR(2)      INZ('OK');
DCL-S w_FinLot     CHAR(16)     INZ(*BLANKS);
DCL-S w_ItemNo     CHAR(18)     INZ(*BLANKS);
DCL-S w_FormCd     CHAR(10)     INZ(*BLANKS);
DCL-S w_FormVer    PACKED(3:0)  INZ(0);
DCL-S w_ReCheckCnt PACKED(5:0)  INZ(0);
DCL-S w_HoldSeq    PACKED(3:0)  INZ(0);
DCL-S w_HoldRetCod CHAR(2)      INZ(*BLANKS);
DCL-S w_HoldErrMsg CHAR(200)    INZ(*BLANKS);
DCL-S w_HoldSqlSt  CHAR(5)      INZ(*BLANKS);
DCL-S w_HoldCascCt INT(5)       INZ(0);

EXEC SQL INCLUDE SQLCA;
EXEC SQL SET OPTION COMMIT = *CHG, DATFMT = *ISO, TIMFMT = *ISO;

// ============================================================================
// MAIN
// ============================================================================
O_RETCOD  = c_StatusOK;
O_ERRMSG  = *BLANKS;
O_VARPCT  = 0;
O_VARSTAT = 'OK';

// STEP 1: Fetch blend order
EXEC SQL
    SELECT BTHQTY, BFINLOT, BITEMNO, BFORMCD, BFORMVER
    INTO   :w_ThQty, :w_FinLot, :w_ItemNo, :w_FormCd, :w_FormVer
    FROM   APEXMFG.BLNDORDR
    WHERE  BORDNO = :I_BORDNO;

IF SQLCODE = 100;
    O_RETCOD = c_StatusNotFnd;
    O_ERRMSG = 'Blend order ' + %TRIM(I_BORDNO) + ' not found.';
    RETURN;
ENDIF;

// STEP 2: Check for unresolved RE (recheck) containers — CHG-2026-0062 partial
EXEC SQL
    SELECT COUNT(*)
    INTO   :w_ReCheckCnt
    FROM   APEXMFG.CNTNRFIL
    WHERE  CFBORDNO = :I_BORDNO
    AND    CFWTSTAT = 'RE'
    AND    CFSTATUS = 'AC';

IF w_ReCheckCnt > 0;
    O_ERRMSG = 'WARNING: ' + %TRIM(%CHAR(w_ReCheckCnt))
             + ' container(s) have unresolved RECHECK (RE) weight status. '
             + 'These will be excluded from yield calculation. '
             + 'See INC-2026-0198 for the known false-hold risk. '
             + 'Resolve recheck containers before running reconciliation.';
    // Non-fatal — proceed but warn
ENDIF;

// STEP 3: Calculate actual yield from accepted containers
EXEC SQL
    SELECT COALESCE(SUM(CFNETWT), 0)
    INTO   :w_ActQty
    FROM   APEXMFG.CNTNRFIL
    WHERE  CFBORDNO = :I_BORDNO
    AND    CFSTATUS = 'AC'
    AND    CFWTSTAT IN ('OK', 'HI');

// STEP 4: Rejected qty (underweight containers)
EXEC SQL
    SELECT COALESCE(SUM(CFNETWT), 0)
    INTO   :w_RejQty
    FROM   APEXMFG.CNTNRFIL
    WHERE  CFBORDNO = :I_BORDNO
    AND    CFSTATUS = 'RJ';

// STEP 5: Scrap qty
EXEC SQL
    SELECT COALESCE(SUM(CFNETWT), 0)
    INTO   :w_ScpQty
    FROM   APEXMFG.CNTNRFIL
    WHERE  CFBORDNO = :I_BORDNO
    AND    CFSTATUS = 'SC';

// STEP 6: Get per-formula max variance
EXEC SQL
    SELECT COALESCE(MIN(FSMAXVAR), :c_DefaultMaxVar)
    INTO   :w_MaxVar
    FROM   APEXMFG.FORMSPEC
    WHERE  FSFORMCD  = :w_FormCd
    AND    FSFORMVER = :w_FormVer
    AND    FSACTIVE  = 'Y';

IF SQLCODE <> 0;
    w_MaxVar = c_DefaultMaxVar;
ENDIF;

// STEP 7: Calculate variance
w_VarQty = w_ActQty - w_ThQty;
IF w_ThQty > 0;
    w_VarPct = (w_VarQty / w_ThQty) * 100;
ENDIF;

// STEP 8: Classify
IF %ABS(w_VarPct) > w_MaxVar;
    w_VarStat = 'EX';
ELSE;
    w_VarStat = 'OK';
ENDIF;

// STEP 9: Write YLDVARNC
EXEC SQL
    INSERT INTO APEXMFG.YLDVARNC (
        YVBORDNO, YVFORMCD, YVITEMNO,
        YVTHQTY, YVACTQTY, YVREJQTY, YVSCPQTY,
        YVMAXVAR, YVVARSTAT,
        YVRECNBY, YVRECNDT, YVRECNTM
    ) VALUES (
        :I_BORDNO, :w_FormCd, :w_ItemNo,
        :w_ThQty, :w_ActQty, :w_RejQty, :w_ScpQty,
        :w_MaxVar, :w_VarStat,
        :I_OPRID, CURRENT_DATE, CURRENT_TIME
    );

// Update blend order actual qty
EXEC SQL
    UPDATE APEXMFG.BLNDORDR
    SET    BACTQTY  = :w_ActQty,
           BREJQTY  = :w_RejQty,
           BSCRAPQTY = :w_ScpQty,
           BSTATUS  = 'YR',
           BCHGBY   = :I_OPRID,
           BCHGDT   = CURRENT_DATE,
           BCHGTM   = CURRENT_TIME
    WHERE  BORDNO = :I_BORDNO;

// STEP 10: Auto QA Hold if variance exceeded
IF w_VarStat = 'EX';
    EXEC SQL
        CALL APEXMFG.SP_PLACE_QA_HOLD(
            :w_FinLot, :w_ItemNo,
            'CHEM',
            'Automatic hold: yield variance ' || TRIM(CHAR(:w_VarPct)) || '% '
            || 'exceeds maximum ' || TRIM(CHAR(:w_MaxVar)) || '% '
            || 'for blend order ' || TRIM(:I_BORDNO),
            'N', '', 'N', :I_OPRID,
            :w_HoldSeq, :w_HoldRetCod, :w_HoldErrMsg,
            :w_HoldSqlSt, :w_HoldCascCt
        );

    // Update YLDVARNC with hold ID
    EXEC SQL
        UPDATE APEXMFG.YLDVARNC
        SET    YVQAHOLD   = 'Y',
               YVQAHOLDID = TRIM(CHAR(:w_HoldSeq))
        WHERE  YVBORDNO = :I_BORDNO;
ENDIF;

// STEP 11: Severe negative variance alert
IF w_VarPct < c_SevereNegVar;
    EXEC SQL
        INSERT INTO APEXMFG.INVTRANS (
            ITTRANSTYP, ITITEMNO, ITLOTNO, ITBORDNO,
            ITQTY, ITUOM, ITREASON, ITCRTBY
        ) VALUES (
            'ADJN', :w_ItemNo, :w_FinLot, :I_BORDNO,
            :w_VarQty, 'KG',
            'P1 INCIDENT: Severe short yield ' || TRIM(CHAR(:w_VarPct)) ||
            '% on blend order ' || TRIM(:I_BORDNO) ||
            '. Plant Manager notification required.',
            :I_OPRID
        );
    EXEC SQL
        CALL QSYS2.QCMDEXC('SNDMSG MSG(''P1: SEVERE SHORT YIELD ' ||
            TRIM(CHAR(:w_VarPct)) || '% ORDER ' || TRIM(:I_BORDNO) ||
            ' PLANT MGR SIGN-OFF REQUIRED'') TOUSR(PLANTMGR)');
ENDIF;

// Return results
O_VARPCT  = w_VarPct;
O_VARSTAT = w_VarStat;

IF w_VarStat = 'OK';
    O_ERRMSG = 'Yield reconciliation complete. '
             + 'Theoretical: ' + %TRIM(%CHAR(w_ThQty)) + ' KG. '
             + 'Actual: ' + %TRIM(%CHAR(w_ActQty)) + ' KG. '
             + 'Variance: ' + %TRIM(%CHAR(w_VarPct)) + '% (within spec).';
ELSE;
    O_RETCOD = c_StatusHold;
    O_ERRMSG = 'Yield variance EXCEEDED: '
             + %TRIM(%CHAR(w_VarPct)) + '% '
             + '(max allowed: ' + %TRIM(%CHAR(w_MaxVar)) + '%). '
             + 'QA hold placed on lot ' + %TRIM(w_FinLot) + '. '
             + 'QA approval required before batch can be closed.';
ENDIF;

RETURN;

BEGSR *PSSR;
    O_RETCOD = c_StatusSQL;
    O_ERRMSG = 'Unexpected error in YLDRECNC. Status='
             + %TRIM(%CHAR(%STATUS())) + ' Order=' + %TRIM(I_BORDNO);
    RETURN;
ENDSR;
