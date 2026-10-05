-- =============================================================================
-- PROCEDURE:  SP_RECEIVE_LOT
-- SYSTEM:     APEX MITS Manufacturing Execution System
-- PURPOSE:    Assign QC status and retest/expiry dates to a received lot.
--             Called by PO Receiving and ASN Receiving for every lot.
--             Implements FRD-VLC-001 requirements 3.03, 3.04 and 4.01.
--
-- DEMO SOURCE — ALL CONTENT IS FABRICATED FOR POC PURPOSES
--
-- MODIFIED:
--   2015-04-02  Initial version (Vendor Lot Certification)
--   2019-10-14  Added secondary packaging 'NONE' placeholder handling (3.04)
--   2024-06-03  Added RJ status when calculated dates are already past
-- =============================================================================
CREATE OR REPLACE PROCEDURE APEXMFG.SP_RECEIVE_LOT (
    IN  P_MATERIAL_ID   VARCHAR(20),
    IN  P_VENDOR_ID     VARCHAR(20),
    IN  P_VENDOR_LOT    VARCHAR(20),
    IN  P_RECEIPT_TS    TIMESTAMP,
    IN  P_INTERNAL_LOT  VARCHAR(16),
    OUT P_QC_STATUS     CHAR(2),
    OUT P_RETEST_DATE   DATE,
    OUT P_EXPIRE_DATE   DATE,
    OUT P_REASON        VARCHAR(60)
)
LANGUAGE SQL
BEGIN
    DECLARE V_MATL_CLASS   VARCHAR(20);
    DECLARE V_VEN_STATUS   CHAR(2);
    DECLARE V_COA_FOUND    INTEGER DEFAULT 0;
    DECLARE V_MFG_DATE     DATE;
    DECLARE V_RETEST_DAYS  INTEGER;
    DECLARE V_EXPIRE_DAYS  INTEGER;
    DECLARE V_RULE_ID      VARCHAR(20);

    -- -------------------------------------------------------------------------
    -- Vendor/material setup
    -- -------------------------------------------------------------------------
    SELECT MATERIAL_CLASS, VEN_MATL_STATUS
      INTO V_MATL_CLASS, V_VEN_STATUS
      FROM APEXMFG.VENDOR_MATL_DTL
     WHERE MATERIAL_ID = P_MATERIAL_ID
       AND VENDOR_ID   = P_VENDOR_ID
     FETCH FIRST 1 ROW ONLY;

    -- -------------------------------------------------------------------------
    -- SR_FindCoaRow: look up the certified vendor lot.
    -- Secondary packaging has no CofA, so it must match the 'NONE'
    -- placeholder row entered by CIQA (FRD-VLC-001 3.04). The vendor lot
    -- on the receipt is NOT used for this lookup.
    -- -------------------------------------------------------------------------
    IF V_MATL_CLASS = 'SECONDARY_PACKAGING' THEN
        SELECT COUNT(*), MAX(MANUFACTURE_DATE)
          INTO V_COA_FOUND, V_MFG_DATE
          FROM APEXMFG.COA_VENDOR_LOT
         WHERE MATERIAL_ID = P_MATERIAL_ID
           AND VENDOR_ID   = P_VENDOR_ID
           AND VENDOR_LOT  = 'NONE';
    ELSE
        SELECT COUNT(*), MAX(MANUFACTURE_DATE)
          INTO V_COA_FOUND, V_MFG_DATE
          FROM APEXMFG.COA_VENDOR_LOT
         WHERE MATERIAL_ID = P_MATERIAL_ID
           AND VENDOR_ID   = P_VENDOR_ID
           AND VENDOR_LOT  = P_VENDOR_LOT;
    END IF;

    -- -------------------------------------------------------------------------
    -- SR_AssignStatus (FRD-VLC-001 3.03 / 3.04)
    -- No COA row -> UI, regardless of VENDOR_MATL_DTL. This is intentional:
    -- a missing CofA (or missing 'NONE' placeholder) means the lot has not
    -- been pre-approved by CIQA.
    -- -------------------------------------------------------------------------
    IF V_COA_FOUND = 0 THEN
        SET P_QC_STATUS = 'UI';
        SET P_REASON    = 'Received - awaiting QA';
    ELSEIF V_VEN_STATUS IS NULL THEN
        SET P_QC_STATUS = 'AP';
        SET P_REASON    = 'Vendor lot pre-approved';
    ELSE
        SET P_QC_STATUS = V_VEN_STATUS;
        SET P_REASON    = CASE WHEN V_VEN_STATUS = 'AP'
                               THEN 'Vendor lot pre-approved'
                               ELSE 'Received - awaiting QA' END;
    END IF;

    -- -------------------------------------------------------------------------
    -- SR_CalcDates
    -- Certified ingredients use the CofA manufacture date.
    -- Secondary packaging and uncertified lots use the receipt date.
    -- -------------------------------------------------------------------------
    IF V_COA_FOUND > 0 AND V_MATL_CLASS <> 'SECONDARY_PACKAGING' THEN
        SET V_RULE_ID = 'MANUFACTURE_DATE';
    ELSE
        SET V_RULE_ID = 'INITIAL_RECEIPT';
        SET V_MFG_DATE = DATE(P_RECEIPT_TS);
    END IF;

    SELECT MAX(CASE WHEN RULE_CLASS = 'RETEST_DATE' THEN RULE_DAYS END),
           MAX(CASE WHEN RULE_CLASS = 'EXPIRE_DATE' THEN RULE_DAYS END)
      INTO V_RETEST_DAYS, V_EXPIRE_DAYS
      FROM APEXMFG.QC_RULES
     WHERE MATERIAL_ID = P_MATERIAL_ID
       AND RULE_ID     = V_RULE_ID;

    IF V_RETEST_DAYS IS NULL THEN
        -- RECPACKDAYS for packaging, DEFAULT_RETEST for ingredients
        SELECT PARM_VALUE INTO V_RETEST_DAYS
          FROM APEXMFG.SYS_PARMS
         WHERE PARM_NAME = CASE WHEN V_MATL_CLASS LIKE '%PACKAGING'
                                THEN 'RECPACKDAYS' ELSE 'DEFAULT_RETEST' END;
        SET V_EXPIRE_DAYS = V_RETEST_DAYS;
    END IF;

    SET P_RETEST_DATE = V_MFG_DATE + V_RETEST_DAYS DAYS;
    SET P_EXPIRE_DATE = V_MFG_DATE + V_EXPIRE_DAYS DAYS;

    IF P_RETEST_DATE < CURRENT DATE OR P_EXPIRE_DATE < CURRENT DATE THEN
        SET P_QC_STATUS = 'RJ';
        SET P_REASON    = 'Calculated dates already past';
    END IF;

    -- -------------------------------------------------------------------------
    -- SR_LogReceipt
    -- -------------------------------------------------------------------------
    INSERT INTO APEXMFG.CONTAINER_LOG (INTERNAL_LOT, EVENT_TYPE, QC_STATUS,
                                       REASON, EVENT_TS)
    VALUES (P_INTERNAL_LOT, 'RECEIVE', P_QC_STATUS, P_REASON, P_RECEIPT_TS);
END;
