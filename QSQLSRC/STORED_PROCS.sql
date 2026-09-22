-- =============================================================================
-- FILE:    STORED_PROCS.sql
-- SYSTEM:  APEX Nutritional Manufacturing — IBM i / DB2 for i
-- PURPOSE: SQL stored procedures for MITS manufacturing execution
-- SCHEMA:  APEXMFG
-- NOTES:
--   All procedures use SQLSTATE-based error handling.
--   Commitment control is SET OPTION COMMIT = *CHG at procedure level.
--   Callers must CALL within their own transaction boundary.
--   Error codes returned in O_RETCOD:
--     00 = Success
--     10 = Record not found
--     20 = Validation error (see O_ERRMSG)
--     30 = QA hold / status block
--     40 = Quantity error
--     50 = SQL error (see O_SQLERR)
--     99 = Unexpected error
-- CREATED: 2024-03-01   J.MARTINEZ
-- MODIFIED:2025-08-15   S.PATEL  — Added SP_PLACE_QA_HOLD, SP_RELEASE_HOLD
--          2026-02-10   R.CHEN   — Added SP_CLOSE_BATCH, SP_SHIFT_SUMMARY
--          2026-06-22   T.OKAFOR — Added SP_BLEND_ORDER_STATUS_RPT
--          2026-09-05   S.PATEL  — Performance tuning on SP_VALIDATE_BLEND
-- =============================================================================

-- =============================================================================
-- SP_VALIDATE_BLEND
-- PURPOSE: Validates a blend order before blending can start.
--          Checks: blend order status, all ingredient lots approved,
--          no active QA holds on any lot, quantities within spec,
--          line CIP status current, formula version active.
-- CALLED BY: BLNDVAL (RPGLE), FILLINIT (RPGLE)
-- INPUTS:  I_BORDNO   — Blend Order Number
--          I_LINENO   — Manufacturing Line (must match order)
--          I_OPRID    — Operator User ID
-- OUTPUTS: O_RETCOD   — Return code (see header)
--          O_ERRMSG   — Error message
--          O_SQLERR   — SQL state on error
--          O_WARNMSG  — Warning (non-blocking)
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_VALIDATE_BLEND (
    IN  I_BORDNO    CHAR(10),
    IN  I_LINENO    CHAR(4),
    IN  I_OPRID     CHAR(10),
    OUT O_RETCOD    CHAR(2),
    OUT O_ERRMSG    VARCHAR(200),
    OUT O_SQLERR    CHAR(5),
    OUT O_WARNMSG   VARCHAR(200)
)
LANGUAGE SQL
SPECIFIC APEXMFG.SP_VALIDATE_BLEND
SET OPTION COMMIT = *CHG, DATFMT = *ISO, TIMFMT = *ISO

BEGIN

    -- Local variables
    DECLARE V_BSTATUS      CHAR(2);
    DECLARE V_BLINENO      CHAR(4);
    DECLARE V_BFORMCD      CHAR(10);
    DECLARE V_BFORMVER     SMALLINT;
    DECLARE V_BITEMNO      CHAR(18);
    DECLARE V_BTHQTY       DECIMAL(9,3);
    DECLARE V_LSCIPSTAT    CHAR(2);
    DECLARE V_LSSTATUS     CHAR(5);
    DECLARE V_LOTNO        CHAR(16);
    DECLARE V_LOTITEM      CHAR(18);
    DECLARE V_LQASTAT      CHAR(2);
    DECLARE V_LEXPDT       DATE;
    DECLARE V_HOLDCNT      INT DEFAULT 0;
    DECLARE V_INGRCNT      INT DEFAULT 0;
    DECLARE V_APPRCNT      INT DEFAULT 0;
    DECLARE V_EXPCNT       INT DEFAULT 0;
    DECLARE V_FORMACTIVE   INT DEFAULT 0;
    DECLARE V_CRITFAIL     CHAR(18) DEFAULT '';
    DECLARE V_WARNBUF      VARCHAR(200) DEFAULT '';

    -- Cursor: ingredients for this blend order
    DECLARE C_INGR CURSOR FOR
        SELECT II.IILOTNO, II.IIITEMNO,
               L.LQASTAT, L.LEXPDT,
               RM.RMITMTYPE
        FROM   APEXMFG.INGRISS  II
        JOIN   APEXMFG.LOTMSTR  L
               ON  L.LOTNO   = II.IILOTNO
               AND L.LOTITEM = II.IIITEMNO
        JOIN   APEXMFG.RMATMAS  RM
               ON  RM.RMITEMNO = II.IIITEMNO
        WHERE  II.IIBORDNO = I_BORDNO
        AND    II.IISTAT   = 'IS'
        ORDER BY II.IIITEMNO, II.IISSEQNO;

    -- Error handler
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 O_SQLERR = RETURNED_SQLSTATE;
        SET O_RETCOD = '50';
        SET O_ERRMSG = 'SQL error in SP_VALIDATE_BLEND: ' || O_SQLERR;
        RETURN;
    END;

    -- Initialise outputs
    SET O_RETCOD  = '00';
    SET O_ERRMSG  = '';
    SET O_SQLERR  = '00000';
    SET O_WARNMSG = '';

    -- -------------------------------------------------------------------------
    -- STEP 1: Fetch blend order header
    -- -------------------------------------------------------------------------
    SELECT BSTATUS, BLINENO, BFORMCD, BFORMVER, BITEMNO, BTHQTY
    INTO   V_BSTATUS, V_BLINENO, V_BFORMCD, V_BFORMVER, V_BITEMNO, V_BTHQTY
    FROM   APEXMFG.BLNDORDR
    WHERE  BORDNO = I_BORDNO;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '10';
        SET O_ERRMSG = 'Blend order ' || TRIM(I_BORDNO) || ' not found.';
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 2: Status check — must be NR (Not Released) or CR (Created)
    -- -------------------------------------------------------------------------
    IF V_BSTATUS NOT IN ('CR','NR') THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Blend order ' || TRIM(I_BORDNO)
                    || ' cannot be validated. Current status: '
                    || TRIM(V_BSTATUS)
                    || '. Expected CR or NR.';
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 3: Line assignment check
    -- -------------------------------------------------------------------------
    IF TRIM(V_BLINENO) <> TRIM(I_LINENO) THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Line mismatch. Order ' || TRIM(I_BORDNO)
                    || ' is assigned to line ' || TRIM(V_BLINENO)
                    || ', not line ' || TRIM(I_LINENO) || '.';
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 4: Line CIP status — must not be overdue
    -- -------------------------------------------------------------------------
    SELECT LSCIPSTAT, LSSTATUS
    INTO   V_LSCIPSTAT, V_LSSTATUS
    FROM   APEXMFG.LINESHFT
    WHERE  LSLINENO  = I_LINENO
    AND    LSSHIFTDT = CURRENT_DATE
    ORDER BY LSSHIFTNO DESC
    FETCH FIRST 1 ROW ONLY;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'No shift record found for line ' || TRIM(I_LINENO)
                    || ' today. Cannot validate CIP status.';
        RETURN;
    END IF;

    IF V_LSCIPSTAT = 'OV' THEN
        SET O_RETCOD = '30';
        SET O_ERRMSG = 'Line ' || TRIM(I_LINENO)
                    || ' CIP is OVERDUE. Clean-in-place must be completed '
                    || 'before blending can start. Contact Sanitation.';
        RETURN;
    END IF;

    IF V_LSCIPSTAT = 'DU' THEN
        SET V_WARNBUF = 'WARNING: Line ' || TRIM(I_LINENO)
                     || ' CIP is due. Schedule clean before next batch.';
    END IF;

    IF TRIM(V_LSSTATUS) IN ('DOWN','MAINT') THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Line ' || TRIM(I_LINENO)
                    || ' is currently in status ' || TRIM(V_LSSTATUS)
                    || '. Cannot start blending.';
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 5: Formula version active check
    -- -------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO   V_FORMACTIVE
    FROM   APEXMFG.FORMSPEC
    WHERE  FSFORMCD  = V_BFORMCD
    AND    FSFORMVER = V_BFORMVER
    AND    FSACTIVE  = 'Y'
    AND    FSEFFDTE <= CURRENT_DATE
    AND    (FSEXPDTE IS NULL OR FSEXPDTE >= CURRENT_DATE);

    IF V_FORMACTIVE = 0 THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Formula ' || TRIM(V_BFORMCD)
                    || ' version ' || TRIM(CHAR(V_BFORMVER))
                    || ' is not active or has expired. '
                    || 'Contact Technical Services to reactivate.';
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 6: Ingredient lot validation — open cursor
    -- -------------------------------------------------------------------------
    OPEN C_INGR;

    FETCH_LOOP: LOOP
        FETCH C_INGR INTO V_LOTNO, V_LOTITEM, V_LQASTAT, V_LEXPDT, V_CRITFAIL;

        IF SQLCODE = 100 THEN LEAVE FETCH_LOOP; END IF;

        SET V_INGRCNT = V_INGRCNT + 1;

        -- Check QA status
        IF V_LQASTAT = 'AP' THEN
            SET V_APPRCNT = V_APPRCNT + 1;
        ELSEIF V_LQASTAT IN ('HO','QU','RC') THEN
            -- Hard block: held, quarantined or recalled
            CLOSE C_INGR;
            SET O_RETCOD = '30';
            SET O_ERRMSG = 'Lot ' || TRIM(V_LOTNO)
                        || ' item ' || TRIM(V_LOTITEM)
                        || ' has QA status ' || TRIM(V_LQASTAT)
                        || '. Blending cannot proceed. '
                        || 'Raise a deviation with QA.';
            RETURN;
        ELSEIF V_LQASTAT = 'RJ' THEN
            CLOSE C_INGR;
            SET O_RETCOD = '30';
            SET O_ERRMSG = 'Lot ' || TRIM(V_LOTNO)
                        || ' item ' || TRIM(V_LOTITEM)
                        || ' has been REJECTED by QA. '
                        || 'Remove from staging area immediately.';
            RETURN;
        ELSEIF V_LQASTAT = 'PE' THEN
            CLOSE C_INGR;
            SET O_RETCOD = '30';
            SET O_ERRMSG = 'Lot ' || TRIM(V_LOTNO)
                        || ' item ' || TRIM(V_LOTITEM)
                        || ' is PENDING QA approval. '
                        || 'Wait for QA release before blending.';
            RETURN;
        ELSEIF V_LQASTAT = 'RE' THEN
            -- Retest status — warn but allow if critical ingredient not involved
            IF V_CRITFAIL IN ('PROT','VIT ','MIN ') THEN
                CLOSE C_INGR;
                SET O_RETCOD = '30';
                SET O_ERRMSG = 'Lot ' || TRIM(V_LOTNO)
                            || ' item ' || TRIM(V_LOTITEM)
                            || ' is in RETEST status and is a critical '
                            || 'ingredient type ' || TRIM(V_CRITFAIL)
                            || '. Cannot proceed without full approval.';
                RETURN;
            ELSE
                SET V_WARNBUF = V_WARNBUF
                    || ' LOT ' || TRIM(V_LOTNO) || ' is in retest;';
            END IF;
        END IF;

        -- Check expiry
        IF V_LEXPDT < CURRENT_DATE THEN
            SET V_EXPCNT = V_EXPCNT + 1;
            CLOSE C_INGR;
            SET O_RETCOD = '20';
            SET O_ERRMSG = 'Lot ' || TRIM(V_LOTNO)
                        || ' item ' || TRIM(V_LOTITEM)
                        || ' EXPIRED on ' || CHAR(V_LEXPDT)
                        || '. Expired lots cannot be used.';
            RETURN;
        END IF;

        -- Expiry within 30 days — warning
        IF DAYS(V_LEXPDT) - DAYS(CURRENT_DATE) < 30 THEN
            SET V_WARNBUF = V_WARNBUF
                || ' LOT ' || TRIM(V_LOTNO)
                || ' expires ' || CHAR(V_LEXPDT) || ';';
        END IF;

        -- Check active QA holds on this lot
        SELECT COUNT(*)
        INTO   V_HOLDCNT
        FROM   APEXMFG.QLTHOLD
        WHERE  QHLOTNO  = V_LOTNO
        AND    QHITEMNO = V_LOTITEM
        AND    QHSTATUS = 'AC';

        IF V_HOLDCNT > 0 THEN
            CLOSE C_INGR;
            SET O_RETCOD = '30';
            SET O_ERRMSG = 'Lot ' || TRIM(V_LOTNO)
                        || ' item ' || TRIM(V_LOTITEM)
                        || ' has ' || TRIM(CHAR(V_HOLDCNT))
                        || ' active QA hold(s). '
                        || 'All holds must be released before use.';
            RETURN;
        END IF;

    END LOOP FETCH_LOOP;

    CLOSE C_INGR;

    -- -------------------------------------------------------------------------
    -- STEP 7: All ingredients found and approved?
    -- -------------------------------------------------------------------------
    IF V_INGRCNT = 0 THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'No issued ingredients found for blend order '
                    || TRIM(I_BORDNO)
                    || '. Issue all ingredients before validating.';
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 8: Update blend order status to Released (RL)
    -- -------------------------------------------------------------------------
    UPDATE APEXMFG.BLNDORDR
    SET    BSTATUS = 'RL',
           BCHGBY  = I_OPRID,
           BCHGDT  = CURRENT_DATE,
           BCHGTM  = CURRENT_TIME
    WHERE  BORDNO  = I_BORDNO;

    -- -------------------------------------------------------------------------
    -- STEP 9: Log the validation event in INVTRANS
    -- -------------------------------------------------------------------------
    INSERT INTO APEXMFG.INVTRANS
        (ITTRANSTYP, ITITEMNO, ITLOTNO, ITBORDNO, ITQTY, ITUOM, ITREASON, ITCRTBY)
    VALUES
        ('ISSU', V_BITEMNO, COALESCE(
            (SELECT BFINLOT FROM APEXMFG.BLNDORDR WHERE BORDNO = I_BORDNO), 'UNKNOWN'),
         I_BORDNO, V_BTHQTY, 'KG',
         'Blend order validated and released by ' || TRIM(I_OPRID),
         I_OPRID);

    -- -------------------------------------------------------------------------
    -- Return success
    -- -------------------------------------------------------------------------
    SET O_WARNMSG = V_WARNBUF;
    SET O_RETCOD  = '00';
    SET O_ERRMSG  = 'Blend order ' || TRIM(I_BORDNO)
                 || ' validated successfully. '
                 || TRIM(CHAR(V_INGRCNT)) || ' ingredients checked.';

END;

-- =============================================================================
-- SP_PLACE_QA_HOLD
-- PURPOSE: Places a quality hold on a lot, optionally cascading to all
--          containers and blend orders using that lot.
--          Cascading is required when hold type is MICR or FORE (safety).
-- CALLED BY: QHOLDPRC (RPGLE), QA portal
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_PLACE_QA_HOLD (
    IN  I_LOTNO     CHAR(16),
    IN  I_ITEMNO    CHAR(18),
    IN  I_HOLDTYP   CHAR(4),
    IN  I_HOLDRSN   VARCHAR(200),
    IN  I_LABREQD   CHAR(1),
    IN  I_LABREF    CHAR(20),
    IN  I_CASCADE   CHAR(1),      -- Y = cascade to containers and blend orders
    IN  I_OPRID     CHAR(10),
    OUT O_HOLDSEQ   SMALLINT,
    OUT O_RETCOD    CHAR(2),
    OUT O_ERRMSG    VARCHAR(200),
    OUT O_SQLERR    CHAR(5),
    OUT O_CASCADECT INT           -- Number of cascaded records updated
)
LANGUAGE SQL
SPECIFIC APEXMFG.SP_PLACE_QA_HOLD
SET OPTION COMMIT = *CHG, DATFMT = *ISO

BEGIN

    DECLARE V_LQASTAT    CHAR(2);
    DECLARE V_LQTYAVAIL  DECIMAL(9,3);
    DECLARE V_NEXTSEQ    SMALLINT;
    DECLARE V_CASCADECT  INT DEFAULT 0;
    DECLARE V_BORDNO     CHAR(10);
    DECLARE V_CNTNRID    CHAR(20);

    -- Cursor: open blend orders using this lot
    DECLARE C_BORD CURSOR FOR
        SELECT DISTINCT II.IIBORDNO
        FROM   APEXMFG.INGRISS II
        JOIN   APEXMFG.BLNDORDR B ON B.BORDNO = II.IIBORDNO
        WHERE  II.IILOTNO  = I_LOTNO
        AND    II.IIITEMNO = I_ITEMNO
        AND    II.IISTAT   = 'IS'
        AND    B.BSTATUS   NOT IN ('CL','VO');

    -- Cursor: containers filled from this lot
    DECLARE C_CNTR CURSOR FOR
        SELECT CFCNTNRID
        FROM   APEXMFG.CNTNRFIL
        WHERE  CFLOTNO  = I_LOTNO
        AND    CFSTATUS = 'AC';

    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 O_SQLERR = RETURNED_SQLSTATE;
        SET O_RETCOD = '50';
        SET O_ERRMSG = 'SQL error in SP_PLACE_QA_HOLD state=' || O_SQLERR;
        RETURN;
    END;

    SET O_RETCOD   = '00';
    SET O_ERRMSG   = '';
    SET O_SQLERR   = '00000';
    SET O_HOLDSEQ  = 0;
    SET O_CASCADECT = 0;

    -- Validate hold type
    IF I_HOLDTYP NOT IN ('MICR','CHEM','PHYS','DOCU','PEST','FORE','ALLG') THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Invalid hold type: ' || TRIM(I_HOLDTYP)
                    || '. Valid types: MICR CHEM PHYS DOCU PEST FORE ALLG';
        RETURN;
    END IF;

    -- Fetch current lot status
    SELECT LQASTAT, LQTYAVAIL
    INTO   V_LQASTAT, V_LQTYAVAIL
    FROM   APEXMFG.LOTMSTR
    WHERE  LOTNO    = I_LOTNO
    AND    LOTITEM  = I_ITEMNO;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '10';
        SET O_ERRMSG = 'Lot ' || TRIM(I_LOTNO)
                    || ' item ' || TRIM(I_ITEMNO) || ' not found.';
        RETURN;
    END IF;

    IF V_LQASTAT = 'RC' THEN
        SET O_RETCOD = '30';
        SET O_ERRMSG = 'Lot ' || TRIM(I_LOTNO)
                    || ' is already RECALLED. Cannot place an additional hold.';
        RETURN;
    END IF;

    -- Get next hold sequence number
    SELECT COALESCE(MAX(QHSEQNO), 0) + 1
    INTO   V_NEXTSEQ
    FROM   APEXMFG.QLTHOLD
    WHERE  QHLOTNO = I_LOTNO;

    SET O_HOLDSEQ = V_NEXTSEQ;

    -- Insert hold record
    INSERT INTO APEXMFG.QLTHOLD (
        QHLOTNO, QHITEMNO, QHSEQNO, QHHOLDTYP, QHHOLDRSN,
        QHHOLDBY, QHHOLDDT, QHHOLDTM, QHLABREQD, QHLABREF,
        QHLABRSLT, QHSTATUS
    ) VALUES (
        I_LOTNO, I_ITEMNO, V_NEXTSEQ, I_HOLDTYP, I_HOLDRSN,
        I_OPRID, CURRENT_DATE, CURRENT_TIME, I_LABREQD, I_LABREF,
        'PE', 'AC'
    );

    -- Update lot QA status to HO (Hold)
    UPDATE APEXMFG.LOTMSTR
    SET    LQASTAT  = 'HO',
           LHOLDRSN = SUBSTR(I_HOLDRSN, 1, 120),
           LQTYHOLD = LQTYAVAIL,
           LQTYAVAIL = 0,
           LCHGBY   = I_OPRID,
           LCHGDT   = CURRENT_DATE,
           LCHGTM   = CURRENT_TIME
    WHERE  LOTNO    = I_LOTNO
    AND    LOTITEM  = I_ITEMNO;

    -- Log inventory transaction
    INSERT INTO APEXMFG.INVTRANS
        (ITTRANSTYP, ITITEMNO, ITLOTNO, ITQTY, ITUOM, ITREASON, ITCRTBY)
    VALUES
        ('HOLD', I_ITEMNO, I_LOTNO, V_LQTYAVAIL, 'KG',
         'QA Hold placed: ' || TRIM(I_HOLDTYP) || ' — ' || SUBSTR(I_HOLDRSN,1,60),
         I_OPRID);

    -- -------------------------------------------------------------------------
    -- CASCADE: For MICR and FORE holds — safety critical, must cascade
    -- -------------------------------------------------------------------------
    IF I_CASCADE = 'Y' OR I_HOLDTYP IN ('MICR','FORE','ALLG') THEN

        -- Cascade to open blend orders
        OPEN C_BORD;
        BORD_LOOP: LOOP
            FETCH C_BORD INTO V_BORDNO;
            IF SQLCODE = 100 THEN LEAVE BORD_LOOP; END IF;

            UPDATE APEXMFG.BLNDORDR
            SET    BSTATUS  = 'QA',
                   BQASTAT  = 'HO',
                   BQANOTES = 'Auto-held: lot ' || TRIM(I_LOTNO)
                            || ' placed on QA hold ' || CHAR(CURRENT_DATE),
                   BCHGBY   = I_OPRID,
                   BCHGDT   = CURRENT_DATE,
                   BCHGTM   = CURRENT_TIME
            WHERE  BORDNO = V_BORDNO
            AND    BSTATUS NOT IN ('CL','VO');

            SET V_CASCADECT = V_CASCADECT + 1;
        END LOOP BORD_LOOP;
        CLOSE C_BORD;

        -- Cascade to active containers
        OPEN C_CNTR;
        CNTR_LOOP: LOOP
            FETCH C_CNTR INTO V_CNTNRID;
            IF SQLCODE = 100 THEN LEAVE CNTR_LOOP; END IF;

            UPDATE APEXMFG.CNTNRFIL
            SET    CFSTATUS = 'RJ'
            WHERE  CFCNTNRID = V_CNTNRID
            AND    CFSTATUS  = 'AC';

            SET V_CASCADECT = V_CASCADECT + 1;
        END LOOP CNTR_LOOP;
        CLOSE C_CNTR;

    END IF;

    SET O_CASCADECT = V_CASCADECT;
    SET O_ERRMSG = 'Hold ' || TRIM(CHAR(V_NEXTSEQ))
                || ' placed on lot ' || TRIM(I_LOTNO)
                || '. Cascaded to ' || TRIM(CHAR(V_CASCADECT)) || ' records.';

END;

-- =============================================================================
-- SP_RELEASE_HOLD
-- PURPOSE: Releases one or all active holds on a lot.
--          If releasing the last hold, updates lot QA status to AP.
--          Requires lab result PA if QHLABREQD = 'Y'.
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_RELEASE_HOLD (
    IN  I_LOTNO     CHAR(16),
    IN  I_ITEMNO    CHAR(18),
    IN  I_HOLDSEQ   SMALLINT,     -- 0 = release all active holds
    IN  I_LABRSLT   CHAR(2),      -- PA=Pass FA=Fail PE=Pending
    IN  I_RELRSN    VARCHAR(200),
    IN  I_OPRID     CHAR(10),
    OUT O_RETCOD    CHAR(2),
    OUT O_ERRMSG    VARCHAR(200),
    OUT O_SQLERR    CHAR(5),
    OUT O_REMHOLDS  INT           -- Remaining active holds after release
)
LANGUAGE SQL
SPECIFIC APEXMFG.SP_RELEASE_HOLD
SET OPTION COMMIT = *CHG, DATFMT = *ISO

BEGIN

    DECLARE V_HOLDCNT    INT DEFAULT 0;
    DECLARE V_LABREQD    CHAR(1);
    DECLARE V_HSEQNO     SMALLINT;
    DECLARE V_QTYHOLD    DECIMAL(9,3);
    DECLARE V_REMAINCNT  INT DEFAULT 0;

    DECLARE C_HOLDS CURSOR FOR
        SELECT QHSEQNO, QHLABREQD
        FROM   APEXMFG.QLTHOLD
        WHERE  QHLOTNO  = I_LOTNO
        AND    QHITEMNO = I_ITEMNO
        AND    QHSTATUS = 'AC'
        AND    (I_HOLDSEQ = 0 OR QHSEQNO = I_HOLDSEQ)
        ORDER BY QHSEQNO;

    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 O_SQLERR = RETURNED_SQLSTATE;
        SET O_RETCOD = '50';
        SET O_ERRMSG = 'SQL error in SP_RELEASE_HOLD: ' || O_SQLERR;
        RETURN;
    END;

    SET O_RETCOD   = '00';
    SET O_ERRMSG   = '';
    SET O_SQLERR   = '00000';
    SET O_REMHOLDS = 0;

    -- Verify lot exists
    SELECT LQTYHOLD
    INTO   V_QTYHOLD
    FROM   APEXMFG.LOTMSTR
    WHERE  LOTNO   = I_LOTNO
    AND    LOTITEM = I_ITEMNO;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '10';
        SET O_ERRMSG = 'Lot ' || TRIM(I_LOTNO) || ' not found.';
        RETURN;
    END IF;

    -- Process each hold
    OPEN C_HOLDS;
    HOLD_LOOP: LOOP
        FETCH C_HOLDS INTO V_HSEQNO, V_LABREQD;
        IF SQLCODE = 100 THEN LEAVE HOLD_LOOP; END IF;

        -- If lab required, result must be PA
        IF V_LABREQD = 'Y' AND I_LABRSLT <> 'PA' THEN
            CLOSE C_HOLDS;
            SET O_RETCOD = '30';
            SET O_ERRMSG = 'Hold ' || TRIM(CHAR(V_HSEQNO))
                        || ' requires a PASS lab result before release. '
                        || 'Current result: ' || TRIM(I_LABRSLT);
            RETURN;
        END IF;

        UPDATE APEXMFG.QLTHOLD
        SET    QHSTATUS  = 'RL',
               QHLABRSLT = I_LABRSLT,
               QHLABDT   = CURRENT_DATE,
               QHRELBY   = I_OPRID,
               QHRELDT   = CURRENT_DATE,
               QHRELTM   = CURRENT_TIME,
               QHRELRSN  = I_RELRSN
        WHERE  QHLOTNO   = I_LOTNO
        AND    QHSEQNO   = V_HSEQNO;

        SET V_HOLDCNT = V_HOLDCNT + 1;
    END LOOP HOLD_LOOP;
    CLOSE C_HOLDS;

    IF V_HOLDCNT = 0 THEN
        SET O_RETCOD = '10';
        SET O_ERRMSG = 'No active holds found for lot ' || TRIM(I_LOTNO)
                    || CASE WHEN I_HOLDSEQ > 0
                            THEN ' sequence ' || TRIM(CHAR(I_HOLDSEQ))
                            ELSE '' END || '.';
        RETURN;
    END IF;

    -- Count remaining active holds
    SELECT COUNT(*)
    INTO   V_REMAINCNT
    FROM   APEXMFG.QLTHOLD
    WHERE  QHLOTNO  = I_LOTNO
    AND    QHITEMNO = I_ITEMNO
    AND    QHSTATUS = 'AC';

    SET O_REMHOLDS = V_REMAINCNT;

    -- If no remaining holds, update lot to Approved
    IF V_REMAINCNT = 0 THEN
        UPDATE APEXMFG.LOTMSTR
        SET    LQASTAT   = 'AP',
               LHOLDRSN  = NULL,
               LQTYAVAIL = LQTYAVAIL + V_QTYHOLD,
               LQTYHOLD  = 0,
               LCHGBY    = I_OPRID,
               LCHGDT    = CURRENT_DATE,
               LCHGTM    = CURRENT_TIME
        WHERE  LOTNO     = I_LOTNO
        AND    LOTITEM   = I_ITEMNO;

        INSERT INTO APEXMFG.INVTRANS
            (ITTRANSTYP, ITITEMNO, ITLOTNO, ITQTY, ITUOM, ITREASON, ITCRTBY)
        VALUES
            ('RELE', I_ITEMNO, I_LOTNO, V_QTYHOLD, 'KG',
             'All QA holds released by ' || TRIM(I_OPRID) || ': ' || SUBSTR(I_RELRSN,1,60),
             I_OPRID);

        SET O_ERRMSG = 'All holds released. Lot ' || TRIM(I_LOTNO)
                    || ' status updated to APPROVED.';
    ELSE
        SET O_ERRMSG = TRIM(CHAR(V_HOLDCNT)) || ' hold(s) released. '
                    || TRIM(CHAR(V_REMAINCNT)) || ' hold(s) still active.';
    END IF;

END;

-- =============================================================================
-- SP_CLOSE_BATCH
-- PURPOSE: Closes a blend order batch after all containers are filled
--          and yield reconciliation is complete.
--          Validates: all containers labelled, yield variance within spec,
--          QA release received, no outstanding holds.
--          On success: updates blend order to CL, locks lot for shipment.
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_CLOSE_BATCH (
    IN  I_BORDNO    CHAR(10),
    IN  I_OPRID     CHAR(10),
    OUT O_RETCOD    CHAR(2),
    OUT O_ERRMSG    VARCHAR(200),
    OUT O_SQLERR    CHAR(5),
    OUT O_SUMMARY   VARCHAR(500)
)
LANGUAGE SQL
SPECIFIC APEXMFG.SP_CLOSE_BATCH
SET OPTION COMMIT = *CHG, DATFMT = *ISO

BEGIN

    DECLARE V_BSTATUS    CHAR(2);
    DECLARE V_BQASTAT    CHAR(2);
    DECLARE V_BFINLOT    CHAR(16);
    DECLARE V_BITEMNO    CHAR(18);
    DECLARE V_BTHQTY     DECIMAL(9,3);
    DECLARE V_BACTQTY    DECIMAL(9,3);
    DECLARE V_TOTFILL    INT;
    DECLARE V_UNLBLCNT   INT;
    DECLARE V_ACTHOLCNT  INT;
    DECLARE V_YVVARPCT   DECIMAL(6,3);
    DECLARE V_YVMAXVAR   DECIMAL(5,2);
    DECLARE V_YVVARSTAT  CHAR(2);
    DECLARE V_SUMMARYSTR VARCHAR(500) DEFAULT '';

    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 O_SQLERR = RETURNED_SQLSTATE;
        SET O_RETCOD = '50';
        SET O_ERRMSG = 'SQL error in SP_CLOSE_BATCH: ' || O_SQLERR;
        RETURN;
    END;

    SET O_RETCOD = '00';
    SET O_ERRMSG = '';
    SET O_SQLERR = '00000';
    SET O_SUMMARY = '';

    -- Fetch blend order
    SELECT BSTATUS, BQASTAT, BFINLOT, BITEMNO, BTHQTY, BACTQTY
    INTO   V_BSTATUS, V_BQASTAT, V_BFINLOT, V_BITEMNO, V_BTHQTY, V_BACTQTY
    FROM   APEXMFG.BLNDORDR
    WHERE  BORDNO = I_BORDNO;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '10';
        SET O_ERRMSG = 'Blend order ' || TRIM(I_BORDNO) || ' not found.';
        RETURN;
    END IF;

    -- Must be in YR (Yield Recon) status
    IF V_BSTATUS NOT IN ('YR','QA') THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Blend order ' || TRIM(I_BORDNO)
                    || ' is not ready to close. Status: '
                    || TRIM(V_BSTATUS) || '. Expected YR or QA.';
        RETURN;
    END IF;

    -- QA must have approved
    IF V_BQASTAT <> 'AP' THEN
        SET O_RETCOD = '30';
        SET O_ERRMSG = 'Batch cannot be closed. QA status is '
                    || TRIM(V_BQASTAT) || '. QA must approve before close.';
        RETURN;
    END IF;

    -- Count total filled containers
    SELECT COUNT(*), SUM(CASE WHEN CFPRTSTAT <> 'PR' THEN 1 ELSE 0 END)
    INTO   V_TOTFILL, V_UNLBLCNT
    FROM   APEXMFG.CNTNRFIL
    WHERE  CFBORDNO = I_BORDNO
    AND    CFSTATUS = 'AC';

    IF V_TOTFILL = 0 THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'No filled containers found for order '
                    || TRIM(I_BORDNO) || '. Cannot close.';
        RETURN;
    END IF;

    IF V_UNLBLCNT > 0 THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = TRIM(CHAR(V_UNLBLCNT))
                    || ' container(s) have not been labelled. '
                    || 'All containers must be labelled before batch close.';
        RETURN;
    END IF;

    -- Check yield variance
    SELECT YVVARPCT, YVMAXVAR, YVVARSTAT
    INTO   V_YVVARPCT, V_YVMAXVAR, V_YVVARSTAT
    FROM   APEXMFG.YLDVARNC
    WHERE  YVBORDNO = I_BORDNO;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '20';
        SET O_ERRMSG = 'Yield reconciliation not found for order '
                    || TRIM(I_BORDNO)
                    || '. Run yield reconciliation before closing.';
        RETURN;
    END IF;

    IF V_YVVARSTAT = 'EX' AND V_YVAPRVBY IS NULL THEN
        SET O_RETCOD = '30';
        SET O_ERRMSG = 'Yield variance of '
                    || TRIM(CHAR(V_YVVARPCT)) || '% exceeds maximum '
                    || TRIM(CHAR(V_YVMAXVAR)) || '%. '
                    || 'Variance must be approved by QA before batch close.';
        RETURN;
    END IF;

    -- Check active QA holds on finished lot
    SELECT COUNT(*)
    INTO   V_ACTHOLCNT
    FROM   APEXMFG.QLTHOLD
    WHERE  QHLOTNO  = V_BFINLOT
    AND    QHSTATUS = 'AC';

    IF V_ACTHOLCNT > 0 THEN
        SET O_RETCOD = '30';
        SET O_ERRMSG = 'Finished lot ' || TRIM(V_BFINLOT)
                    || ' has ' || TRIM(CHAR(V_ACTHOLCNT))
                    || ' active hold(s). Release all holds before closing.';
        RETURN;
    END IF;

    -- Close the batch
    UPDATE APEXMFG.BLNDORDR
    SET    BSTATUS   = 'CL',
           BCLOSEDT  = CURRENT_DATE,
           BENDDT    = CURRENT_DATE,
           BENDTM    = CURRENT_TIME,
           BCHGBY    = I_OPRID,
           BCHGDT    = CURRENT_DATE,
           BCHGTM    = CURRENT_TIME
    WHERE  BORDNO = I_BORDNO;

    -- Update finished lot to released for shipment
    UPDATE APEXMFG.LOTMSTR
    SET    LQASTAT  = 'AP',
           LCHGBY   = I_OPRID,
           LCHGDT   = CURRENT_DATE,
           LCHGTM   = CURRENT_TIME
    WHERE  LOTNO    = V_BFINLOT
    AND    LOTITEM  = V_BITEMNO;

    -- Log closure transaction
    INSERT INTO APEXMFG.INVTRANS
        (ITTRANSTYP, ITITEMNO, ITLOTNO, ITBORDNO, ITQTY, ITUOM, ITREASON, ITCRTBY)
    VALUES
        ('ADJP', V_BITEMNO, V_BFINLOT, I_BORDNO, V_BACTQTY, 'KG',
         'Batch closed by ' || TRIM(I_OPRID)
         || '. Yield variance: ' || TRIM(CHAR(V_YVVARPCT)) || '%',
         I_OPRID);

    SET O_SUMMARY = 'Batch ' || TRIM(I_BORDNO) || ' closed successfully. '
                 || 'Containers: ' || TRIM(CHAR(V_TOTFILL))
                 || '. Actual yield: ' || TRIM(CHAR(V_BACTQTY)) || ' KG. '
                 || 'Yield variance: ' || TRIM(CHAR(V_YVVARPCT)) || '%. '
                 || 'Lot ' || TRIM(V_BFINLOT) || ' released for shipment.';
    SET O_RETCOD = '00';
    SET O_ERRMSG = O_SUMMARY;

END;

-- =============================================================================
-- SP_BLEND_ORDER_STATUS_RPT
-- PURPOSE: Returns a comprehensive status report for a blend order,
--          joining all related tables. Used by the shift supervisor
--          dashboard and the service desk agent.
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_BLEND_ORDER_STATUS_RPT (
    IN  I_BORDNO    CHAR(10),
    OUT O_RETCOD    CHAR(2),
    OUT O_ERRMSG    VARCHAR(200)
)
LANGUAGE SQL
SPECIFIC APEXMFG.SP_BLEND_ORDER_STATUS_RPT
DYNAMIC RESULT SETS 4
SET OPTION COMMIT = *NONE, DATFMT = *ISO

BEGIN

    -- Result set 1: Blend order header
    DECLARE C_HDR CURSOR WITH RETURN FOR
        SELECT B.BORDNO, B.BFORMCD, B.BFORMVER, B.BITEMDSC,
               B.BTHQTY, B.BACTQTY,
               CASE B.BSTATUS
                   WHEN 'CR' THEN 'Created'
                   WHEN 'NR' THEN 'Not Released'
                   WHEN 'RL' THEN 'Released'
                   WHEN 'BL' THEN 'Blending'
                   WHEN 'YR' THEN 'Yield Reconciliation'
                   WHEN 'QA' THEN 'QA Review'
                   WHEN 'CL' THEN 'Closed'
                   WHEN 'VO' THEN 'Voided'
                   ELSE B.BSTATUS END AS STATUS_DESC,
               B.BLINENO, B.BSHIFTNO, B.BFINLOT,
               B.BSCHEDDT, B.BSTARTDT, B.BENDDT,
               B.BQASTAT, B.BQARELBY, B.BQARELDT,
               B.BCRTBY, B.BCRTDT
        FROM   APEXMFG.BLNDORDR B
        WHERE  B.BORDNO = I_BORDNO;

    -- Result set 2: Ingredient issues
    DECLARE C_INGR CURSOR WITH RETURN FOR
        SELECT II.IIITEMNO, RM.RMITEMDSC, II.IILOTNO,
               II.IITHQTY, II.IIACTQTY, II.IIVARQTY, II.IIVARPCT,
               L.LQASTAT AS LOT_QASTAT,
               L.LEXPDT  AS LOT_EXPIRY,
               II.IIISSUEBY, II.IIISSUEDT, II.IISTAT
        FROM   APEXMFG.INGRISS  II
        JOIN   APEXMFG.RMATMAS  RM ON RM.RMITEMNO = II.IIITEMNO
        JOIN   APEXMFG.LOTMSTR  L
               ON L.LOTNO    = II.IILOTNO
               AND L.LOTITEM = II.IIITEMNO
        WHERE  II.IIBORDNO = I_BORDNO
        ORDER BY II.IIITEMNO, II.IISSEQNO;

    -- Result set 3: Containers
    DECLARE C_CNTR CURSOR WITH RETURN FOR
        SELECT CF.CFCNTNRID, CF.CFCONTTYP, CF.CFCONTSZE,
               CF.CFNETWT, CF.CFMINWT, CF.CFMAXWT, CF.CFWTSTAT,
               CF.CFOPRID, CF.CFSCANDT, CF.CFSCANTM,
               CF.CFPRTSTAT, CF.CFSTATUS,
               CF.CFDEVICID
        FROM   APEXMFG.CNTNRFIL CF
        WHERE  CF.CFBORDNO = I_BORDNO
        ORDER BY CF.CFSCANDT, CF.CFSCANTM;

    -- Result set 4: QA holds on the finished lot
    DECLARE C_HOLD CURSOR WITH RETURN FOR
        SELECT QH.QHSEQNO, QH.QHHOLDTYP, QH.QHHOLDRSN,
               QH.QHHOLDBY, QH.QHHOLDDT,
               QH.QHLABRSLT, QH.QHLABDT,
               QH.QHSTATUS, QH.QHRELBY, QH.QHRELDT,
               QH.QHHOLDDYS
        FROM   APEXMFG.QLTHOLD QH
        JOIN   APEXMFG.BLNDORDR B ON B.BFINLOT = QH.QHLOTNO
        WHERE  B.BORDNO = I_BORDNO
        ORDER BY QH.QHSEQNO;

    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 O_ERRMSG = MESSAGE_TEXT;
        SET O_RETCOD = '50';
        RETURN;
    END;

    SET O_RETCOD = '00';
    SET O_ERRMSG = '';

    OPEN C_HDR;
    OPEN C_INGR;
    OPEN C_CNTR;
    OPEN C_HOLD;

END;

-- =============================================================================
-- SP_SHIFT_SUMMARY
-- PURPOSE: Produces a shift summary for a given line and shift date.
--          Called by LNECLSRPT at end of shift and by the supervisor
--          dashboard. Returns key metrics: fills, rejects, downtime,
--          yield vs plan, open holds, and any overweight/underweight events.
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_SHIFT_SUMMARY (
    IN  I_LINENO    CHAR(4),
    IN  I_SHIFTNO   CHAR(1),
    IN  I_SHIFTDT   DATE,
    OUT O_RETCOD    CHAR(2),
    OUT O_ERRMSG    VARCHAR(200),
    OUT O_TOTFILL   INT,
    OUT O_TOTREJ    INT,
    OUT O_TOTDNT    INT,
    OUT O_AVGYLD    DECIMAL(6,3),
    OUT O_LOSTATUS  CHAR(5),
    OUT O_OPENHOLDS INT,
    OUT O_UNDWT_CT  INT,
    OUT O_OVWT_CT   INT
)
LANGUAGE SQL
SPECIFIC APEXMFG.SP_SHIFT_SUMMARY
SET OPTION COMMIT = *NONE, DATFMT = *ISO

BEGIN

    DECLARE V_BORDNO    CHAR(10);
    DECLARE V_THQTY     DECIMAL(9,3);
    DECLARE V_ACTQTY    DECIMAL(9,3);

    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 O_ERRMSG = MESSAGE_TEXT;
        SET O_RETCOD = '50';
        RETURN;
    END;

    SET O_RETCOD   = '00';
    SET O_ERRMSG   = '';
    SET O_TOTFILL  = 0;
    SET O_TOTREJ   = 0;
    SET O_TOTDNT   = 0;
    SET O_AVGYLD   = 0;
    SET O_LOSTATUS = 'IDLE ';
    SET O_OPENHOLDS = 0;
    SET O_UNDWT_CT = 0;
    SET O_OVWT_CT  = 0;

    -- Fetch shift log
    SELECT LSBORDNO, LSTOTFILL, LSTOTREJ, LSTOTDNT, LSSTATUS
    INTO   V_BORDNO, O_TOTFILL, O_TOTREJ, O_TOTDNT, O_LOSTATUS
    FROM   APEXMFG.LINESHFT
    WHERE  LSLINENO  = I_LINENO
    AND    LSSHIFTNO = I_SHIFTNO
    AND    LSSHIFTDT = I_SHIFTDT;

    IF SQLCODE = 100 THEN
        SET O_RETCOD = '10';
        SET O_ERRMSG = 'No shift record found for line '
                    || TRIM(I_LINENO) || ' shift '
                    || TRIM(I_SHIFTNO) || ' date '
                    || CHAR(I_SHIFTDT);
        RETURN;
    END IF;

    -- Weight stats from container fill
    SELECT
        SUM(CASE WHEN CFWTSTAT = 'LO' THEN 1 ELSE 0 END),
        SUM(CASE WHEN CFWTSTAT = 'HI' THEN 1 ELSE 0 END)
    INTO   O_UNDWT_CT, O_OVWT_CT
    FROM   APEXMFG.CNTNRFIL
    WHERE  CFBORDNO = V_BORDNO
    AND    CFLINENO = I_LINENO;

    -- Average yield vs plan
    SELECT BTHQTY, BACTQTY
    INTO   V_THQTY, V_ACTQTY
    FROM   APEXMFG.BLNDORDR
    WHERE  BORDNO = V_BORDNO;

    IF V_THQTY > 0 THEN
        SET O_AVGYLD = (V_ACTQTY / V_THQTY) * 100;
    END IF;

    -- Count open QA holds on blend order lots
    SELECT COUNT(*)
    INTO   O_OPENHOLDS
    FROM   APEXMFG.QLTHOLD QH
    JOIN   APEXMFG.BLNDORDR B
           ON B.BFINLOT = QH.QHLOTNO
    WHERE  B.BORDNO     = V_BORDNO
    AND    QH.QHSTATUS  = 'AC';

END;
