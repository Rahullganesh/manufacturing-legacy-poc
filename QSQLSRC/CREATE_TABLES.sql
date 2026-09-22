-- =============================================================================
-- FILE:    CREATE_TABLES.sql
-- SYSTEM:  APEX Nutritional Manufacturing — IBM i / DB2 for i
-- PURPOSE: SQL DDL for all MITS tables
--          Creates tables with referential integrity, check constraints,
--          generated columns, and indexes. Run in sequence.
-- SCHEMA:  APEXMFG
-- NOTE:    DDS physical files (QDDSSRC) are the legacy definitions.
--          These SQL tables replace them for new development.
--          Existing RPG programs still access the DDS-based objects;
--          SQL tables are used by stored procedures and reporting.
-- CREATED: 2024-01-15   J.MARTINEZ
-- MODIFIED:2026-07-10   R.CHEN — Added generated columns, hash indexes
--          2026-09-01   S.PATEL — Added INVTRANS, FORMSPEC tables
-- =============================================================================

-- =============================================================================
-- DROP SEQUENCE (if rebuilding)
-- =============================================================================
DROP SEQUENCE APEXMFG.BORDNO_SEQ;
DROP SEQUENCE APEXMFG.HOLDID_SEQ;
DROP SEQUENCE APEXMFG.LOGID_SEQ;

-- =============================================================================
-- SEQUENCES
-- =============================================================================
CREATE SEQUENCE APEXMFG.BORDNO_SEQ
    START WITH 100001
    INCREMENT BY 1
    MINVALUE 100001
    MAXVALUE 999999
    NO CYCLE
    CACHE 20;

CREATE SEQUENCE APEXMFG.HOLDID_SEQ
    START WITH 1
    INCREMENT BY 1
    NO CYCLE
    CACHE 10;

CREATE SEQUENCE APEXMFG.LOGID_SEQ
    START WITH 1
    INCREMENT BY 1
    NO CYCLE
    CACHE 50;

-- =============================================================================
-- TABLE: RMATMAS — Raw Material Master
-- =============================================================================
CREATE TABLE APEXMFG.RMATMAS (
    RMITEMNO       CHAR(18)      NOT NULL,
    RMITEMDSC      VARCHAR(40)   NOT NULL,
    RMITMTYPE      CHAR(4)       NOT NULL
                   CONSTRAINT CK_RMITMTYPE
                   CHECK (RMITMTYPE IN ('PROT','CARB','FAT ','VIT ','MIN ',
                                        'FLAV','EMUL','PRSV','BULK','PACK')),
    RMUOM          CHAR(3)       NOT NULL DEFAULT 'KG',
    RMSUPPLIER     CHAR(10)      NOT NULL,
    RMMINQTY       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    RMMAXQTY       DECIMAL(9,3)  NOT NULL DEFAULT 99999,
    RMMINVAR       DECIMAL(5,2)  NOT NULL DEFAULT -2.00,
    RMMAXVAR       DECIMAL(5,2)  NOT NULL DEFAULT  2.00,
    RMSHLFLIFE     SMALLINT      NOT NULL DEFAULT 365,
    RMRETESTDY     SMALLINT      NOT NULL DEFAULT 180,
    RMSTORTEMP     DECIMAL(5,1)           DEFAULT NULL,
    RMSTORHUMD     DECIMAL(5,1)           DEFAULT NULL,
    RMSTORLOCN     CHAR(10)               DEFAULT NULL,
    RMCOFA         CHAR(1)       NOT NULL DEFAULT 'Y'
                   CONSTRAINT CK_RMCOFA CHECK (RMCOFA IN ('Y','N')),
    RMCOFATYP      CHAR(4)                DEFAULT NULL
                   CONSTRAINT CK_RMCOFATYP
                   CHECK (RMCOFATYP IS NULL OR RMCOFATYP IN ('MICR','CHEM','FULL')),
    RMALLERGY      VARCHAR(80)            DEFAULT NULL,
    RMHAZMAT       CHAR(1)       NOT NULL DEFAULT 'N'
                   CONSTRAINT CK_RMHAZMAT CHECK (RMHAZMAT IN ('Y','N')),
    RMACTIVE       CHAR(1)       NOT NULL DEFAULT 'Y'
                   CONSTRAINT CK_RMACTIVE CHECK (RMACTIVE IN ('Y','N')),
    RMCRTBY        CHAR(10)      NOT NULL DEFAULT USER,
    RMCRTDT        DATE          NOT NULL DEFAULT CURRENT_DATE,
    RMCHGBY        CHAR(10)               DEFAULT NULL,
    RMCHGDT        DATE                   DEFAULT NULL,
    CONSTRAINT PK_RMATMAS PRIMARY KEY (RMITEMNO)
);

-- =============================================================================
-- TABLE: BLNDORDR — Blend Order Master
-- =============================================================================
CREATE TABLE APEXMFG.BLNDORDR (
    BORDNO         CHAR(10)      NOT NULL,
    BFORMCD        CHAR(10)      NOT NULL,
    BFORMVER       SMALLINT      NOT NULL DEFAULT 1,
    BITEMNO        CHAR(18)      NOT NULL,
    BITEMDSC       VARCHAR(40)   NOT NULL,
    BTHQTY         DECIMAL(9,3)  NOT NULL,
    BACTQTY        DECIMAL(9,3)           DEFAULT 0,
    BREJQTY        DECIMAL(9,3)           DEFAULT 0,
    BSCRAPQTY      DECIMAL(9,3)           DEFAULT 0,
    BUOMCOD        CHAR(3)       NOT NULL DEFAULT 'KG',
    BSTATUS        CHAR(2)       NOT NULL DEFAULT 'CR'
                   CONSTRAINT CK_BSTATUS
                   CHECK (BSTATUS IN ('CR','NR','RL','BL','YR','QA','CL','VO')),
    BPRIORITY      CHAR(1)       NOT NULL DEFAULT '2'
                   CONSTRAINT CK_BPRIORITY CHECK (BPRIORITY IN ('1','2','3')),
    BLINENO        CHAR(4)       NOT NULL,
    BSHIFTNO       CHAR(1)       NOT NULL DEFAULT '1'
                   CONSTRAINT CK_BSHIFTNO CHECK (BSHIFTNO IN ('1','2','3')),
    BSCHEDDT       DATE                   DEFAULT NULL,
    BSCHEDTM       TIME                   DEFAULT NULL,
    BSTARTDT       DATE                   DEFAULT NULL,
    BSTARTTM       TIME                   DEFAULT NULL,
    BENDDT         DATE                   DEFAULT NULL,
    BENDTM         TIME                   DEFAULT NULL,
    BCLOSEDT       DATE                   DEFAULT NULL,
    BFINLOT        CHAR(16)               DEFAULT NULL,
    BBULKLOT       CHAR(16)               DEFAULT NULL,
    BQASTAT        CHAR(2)       NOT NULL DEFAULT 'PE'
                   CONSTRAINT CK_BQASTAT
                   CHECK (BQASTAT IN ('PE','AP','RJ','HO')),
    BQARELDT       DATE                   DEFAULT NULL,
    BQARELBY       CHAR(10)               DEFAULT NULL,
    BQANOTES       VARCHAR(200)           DEFAULT NULL,
    BCRTBY         CHAR(10)      NOT NULL DEFAULT USER,
    BCRTDT         DATE          NOT NULL DEFAULT CURRENT_DATE,
    BCRTTM         TIME          NOT NULL DEFAULT CURRENT_TIME,
    BCHGBY         CHAR(10)               DEFAULT NULL,
    BCHGDT         DATE                   DEFAULT NULL,
    BCHGTM         TIME                   DEFAULT NULL,
    -- Generated column: days since scheduled
    BDAYS_OPEN    GENERATED ALWAYS AS (DAYS(CURRENT_DATE) - DAYS(BSCHEDDT)),
    CONSTRAINT PK_BLNDORDR PRIMARY KEY (BORDNO),
    CONSTRAINT FK_BLNDORDR_ITEM
        FOREIGN KEY (BITEMNO) REFERENCES APEXMFG.RMATMAS (RMITEMNO)
        ON DELETE RESTRICT
);

-- =============================================================================
-- TABLE: LOTMSTR — Lot Master
-- =============================================================================
CREATE TABLE APEXMFG.LOTMSTR (
    LOTNO          CHAR(16)      NOT NULL,
    LOTITEM        CHAR(18)      NOT NULL,
    LITEMDSC       VARCHAR(40)   NOT NULL,
    LITMTYPE       CHAR(2)       NOT NULL
                   CONSTRAINT CK_LITMTYPE
                   CHECK (LITMTYPE IN ('RM','FG','BL','IN','PK')),
    LSUPPLIER      CHAR(10)               DEFAULT NULL,
    LSUPPLNO       VARCHAR(20)            DEFAULT NULL,
    LQTYRCVD       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    LQTYAVAIL      DECIMAL(9,3)  NOT NULL DEFAULT 0,
    LQTYHOLD       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    LQTYUSED       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    LQTYDEST       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    LUOM           CHAR(3)       NOT NULL DEFAULT 'KG',
    LQASTAT        CHAR(2)       NOT NULL DEFAULT 'PE'
                   CONSTRAINT CK_LQASTAT
                   CHECK (LQASTAT IN ('AP','PE','HO','RJ','QU','EX','RE','RC')),
    LHOLDRSN       VARCHAR(120)           DEFAULT NULL,
    LMFGDT         DATE                   DEFAULT NULL,
    LEXPDT         DATE          NOT NULL,
    LRCVDT         DATE          NOT NULL DEFAULT CURRENT_DATE,
    LSAMPLDT       DATE                   DEFAULT NULL,
    LRETESTDT      DATE                   DEFAULT NULL,
    LRETESTBY      CHAR(10)               DEFAULT NULL,
    LSUPSITE       CHAR(10)               DEFAULT NULL,
    LREGION        CHAR(3)                DEFAULT NULL,
    LCOUNTRY       CHAR(3)                DEFAULT NULL,
    LSTORLOCN      CHAR(10)               DEFAULT NULL,
    LSTORTEMP      DECIMAL(5,1)           DEFAULT NULL,
    LSTORHUMD      DECIMAL(5,1)           DEFAULT NULL,
    LCRTBY         CHAR(10)      NOT NULL DEFAULT USER,
    LCRTDT         DATE          NOT NULL DEFAULT CURRENT_DATE,
    LCHGBY         CHAR(10)               DEFAULT NULL,
    LCHGDT         DATE                   DEFAULT NULL,
    LCHGTM         TIME                   DEFAULT NULL,
    -- Generated: days to expiry
    LDAYS_TO_EXP  GENERATED ALWAYS AS (DAYS(LEXPDT) - DAYS(CURRENT_DATE)),
    -- Generated: expired flag
    LEXPIRED      GENERATED ALWAYS AS (CASE WHEN LEXPDT < CURRENT_DATE
                                        THEN 'Y' ELSE 'N' END),
    CONSTRAINT PK_LOTMSTR PRIMARY KEY (LOTNO, LOTITEM),
    CONSTRAINT FK_LOTMSTR_ITEM
        FOREIGN KEY (LOTITEM) REFERENCES APEXMFG.RMATMAS (RMITEMNO)
        ON DELETE RESTRICT
);

-- =============================================================================
-- TABLE: INGRISS — Ingredient Issue Log
-- =============================================================================
CREATE TABLE APEXMFG.INGRISS (
    IIBORDNO       CHAR(10)      NOT NULL,
    IIITEMNO       CHAR(18)      NOT NULL,
    IISSEQNO       SMALLINT      NOT NULL DEFAULT 1,
    IILOTNO        CHAR(16)      NOT NULL,
    IITHQTY        DECIMAL(9,3)  NOT NULL,
    IIACTQTY       DECIMAL(9,3)  NOT NULL,
    IIVARQTY       DECIMAL(9,3)  GENERATED ALWAYS AS (IIACTQTY - IITHQTY),
    IIVARPCT       DECIMAL(6,3)  GENERATED ALWAYS AS
                   (CASE WHEN IITHQTY = 0 THEN 0
                    ELSE ((IIACTQTY - IITHQTY) / IITHQTY) * 100 END),
    IIUOM          CHAR(3)       NOT NULL DEFAULT 'KG',
    IISTORLOCN     CHAR(10)               DEFAULT NULL,
    IIISSUEBY      CHAR(10)      NOT NULL DEFAULT USER,
    IIISSUEDT      DATE          NOT NULL DEFAULT CURRENT_DATE,
    IIISSUETM      TIME          NOT NULL DEFAULT CURRENT_TIME,
    IISTAT         CHAR(2)       NOT NULL DEFAULT 'IS'
                   CONSTRAINT CK_IISTAT
                   CHECK (IISTAT IN ('CM','IS','RV')),
    IIRVRSBY       CHAR(10)               DEFAULT NULL,
    IIRVRSDT       DATE                   DEFAULT NULL,
    IIRVRSRSN      VARCHAR(120)           DEFAULT NULL,
    CONSTRAINT PK_INGRISS PRIMARY KEY (IIBORDNO, IIITEMNO, IISSEQNO),
    CONSTRAINT FK_INGRISS_BORD
        FOREIGN KEY (IIBORDNO) REFERENCES APEXMFG.BLNDORDR (BORDNO)
        ON DELETE RESTRICT,
    CONSTRAINT FK_INGRISS_ITEM
        FOREIGN KEY (IIITEMNO) REFERENCES APEXMFG.RMATMAS (RMITEMNO)
        ON DELETE RESTRICT
);

-- =============================================================================
-- TABLE: CNTNRFIL — Container Fill Records
-- =============================================================================
CREATE TABLE APEXMFG.CNTNRFIL (
    CFCNTNRID      CHAR(20)      NOT NULL,
    CFSEQNO        SMALLINT      NOT NULL DEFAULT 1,
    CFBORDNO       CHAR(10)      NOT NULL,
    CFLINENO       CHAR(4)       NOT NULL,
    CFITEMNO       CHAR(18)      NOT NULL,
    CFLOTNO        CHAR(16)      NOT NULL,
    CFCONTTYP      CHAR(6)       NOT NULL
                   CONSTRAINT CK_CFCONTTYP
                   CHECK (CFCONTTYP IN ('CAN   ','BOT   ','PCH   ','CTN   ','BAG   ')),
    CFCONTSZE      CHAR(10)      NOT NULL,
    CFTARWT        DECIMAL(7,3)  NOT NULL DEFAULT 0,
    CFGROSSWT      DECIMAL(7,3)  NOT NULL DEFAULT 0,
    CFNETWT        DECIMAL(7,3)  GENERATED ALWAYS AS (CFGROSSWT - CFTARWT),
    CFMINWT        DECIMAL(7,3)  NOT NULL,
    CFMAXWT        DECIMAL(7,3)  NOT NULL,
    CFWTSTAT       CHAR(2)       NOT NULL DEFAULT 'OK'
                   CONSTRAINT CK_CFWTSTAT
                   CHECK (CFWTSTAT IN ('OK','LO','HI','RE')),
    CFOPRID        CHAR(10)      NOT NULL,
    CFSCANDT       DATE          NOT NULL DEFAULT CURRENT_DATE,
    CFSCANTM       TIME          NOT NULL DEFAULT CURRENT_TIME,
    CFDEVICID      CHAR(10)               DEFAULT NULL,
    CFPRTSTAT      CHAR(2)       NOT NULL DEFAULT 'NP'
                   CONSTRAINT CK_CFPRTSTAT
                   CHECK (CFPRTSTAT IN ('NP','PR','ER')),
    CFPRTDT        DATE                   DEFAULT NULL,
    CFPRTBY        CHAR(10)               DEFAULT NULL,
    CFSTATUS       CHAR(2)       NOT NULL DEFAULT 'AC'
                   CONSTRAINT CK_CFSTATUS
                   CHECK (CFSTATUS IN ('AC','RJ','SC','SH')),
    CONSTRAINT PK_CNTNRFIL PRIMARY KEY (CFCNTNRID, CFSEQNO),
    CONSTRAINT FK_CNTNRFIL_BORD
        FOREIGN KEY (CFBORDNO) REFERENCES APEXMFG.BLNDORDR (BORDNO)
        ON DELETE RESTRICT
);

-- =============================================================================
-- TABLE: QLTHOLD — Quality Hold Master
-- =============================================================================
CREATE TABLE APEXMFG.QLTHOLD (
    QHLOTNO        CHAR(16)      NOT NULL,
    QHITEMNO       CHAR(18)      NOT NULL,
    QHSEQNO        SMALLINT      NOT NULL,
    QHBORDNO       CHAR(10)               DEFAULT NULL,
    QHCNTNRID      CHAR(20)               DEFAULT NULL,
    QHHOLDTYP      CHAR(4)       NOT NULL
                   CONSTRAINT CK_QHHOLDTYP
                   CHECK (QHHOLDTYP IN ('MICR','CHEM','PHYS','DOCU','PEST','FORE','ALLG')),
    QHHOLDRSN      VARCHAR(200)  NOT NULL,
    QHHOLDBY       CHAR(10)      NOT NULL,
    QHHOLDDT       DATE          NOT NULL DEFAULT CURRENT_DATE,
    QHHOLDTM       TIME          NOT NULL DEFAULT CURRENT_TIME,
    QHLABREQD      CHAR(1)       NOT NULL DEFAULT 'N'
                   CONSTRAINT CK_QHLABREQD CHECK (QHLABREQD IN ('Y','N')),
    QHLABREF       CHAR(20)               DEFAULT NULL,
    QHLABRSLT      CHAR(2)                DEFAULT 'PE'
                   CONSTRAINT CK_QHLABRSLT
                   CHECK (QHLABRSLT IN ('PA','FA','PE')),
    QHLABDT        DATE                   DEFAULT NULL,
    QHSTATUS       CHAR(2)       NOT NULL DEFAULT 'AC'
                   CONSTRAINT CK_QHSTATUS
                   CHECK (QHSTATUS IN ('AC','RL','DS','EX')),
    QHRELBY        CHAR(10)               DEFAULT NULL,
    QHRELDT        DATE                   DEFAULT NULL,
    QHRELTM        TIME                   DEFAULT NULL,
    QHRELRSN       VARCHAR(200)           DEFAULT NULL,
    QHESCBY        CHAR(10)               DEFAULT NULL,
    QHESCDT        DATE                   DEFAULT NULL,
    -- Generated: hold duration days
    QHHOLDDYS     GENERATED ALWAYS AS
                   (CASE WHEN QHRELDT IS NOT NULL
                    THEN DAYS(QHRELDT) - DAYS(QHHOLDDT)
                    ELSE DAYS(CURRENT_DATE) - DAYS(QHHOLDDT) END),
    CONSTRAINT PK_QLTHOLD PRIMARY KEY (QHLOTNO, QHSEQNO)
);

-- =============================================================================
-- TABLE: YLDVARNC — Yield Variance
-- =============================================================================
CREATE TABLE APEXMFG.YLDVARNC (
    YVBORDNO       CHAR(10)      NOT NULL,
    YVFORMCD       CHAR(10)      NOT NULL,
    YVITEMNO       CHAR(18)      NOT NULL,
    YVTHQTY        DECIMAL(9,3)  NOT NULL,
    YVACTQTY       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    YVREJQTY       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    YVSCPQTY       DECIMAL(9,3)  NOT NULL DEFAULT 0,
    YVVARQTY       DECIMAL(9,3)  GENERATED ALWAYS AS (YVACTQTY - YVTHQTY),
    YVVARPCT       DECIMAL(6,3)  GENERATED ALWAYS AS
                   (CASE WHEN YVTHQTY = 0 THEN 0
                    ELSE ((YVACTQTY - YVTHQTY) / YVTHQTY) * 100 END),
    YVMAXVAR       DECIMAL(5,2)  NOT NULL DEFAULT 3.00,
    YVVARSTAT      CHAR(2)       NOT NULL DEFAULT 'OK'
                   CONSTRAINT CK_YVVARSTAT
                   CHECK (YVVARSTAT IN ('OK','EX','PE')),
    YVQAHOLD       CHAR(1)       NOT NULL DEFAULT 'N',
    YVQAHOLDID     CHAR(10)               DEFAULT NULL,
    YVRECNBY       CHAR(10)      NOT NULL DEFAULT USER,
    YVRECNDT       DATE          NOT NULL DEFAULT CURRENT_DATE,
    YVRECNTM       TIME          NOT NULL DEFAULT CURRENT_TIME,
    YVAPRVBY       CHAR(10)               DEFAULT NULL,
    YVAPRVDT       DATE                   DEFAULT NULL,
    YVNOTES        VARCHAR(200)           DEFAULT NULL,
    CONSTRAINT PK_YLDVARNC PRIMARY KEY (YVBORDNO),
    CONSTRAINT FK_YLDVARNC_BORD
        FOREIGN KEY (YVBORDNO) REFERENCES APEXMFG.BLNDORDR (BORDNO)
        ON DELETE RESTRICT
);

-- =============================================================================
-- TABLE: LINESHFT — Line/Shift Log
-- =============================================================================
CREATE TABLE APEXMFG.LINESHFT (
    LSLINENO       CHAR(4)       NOT NULL,
    LSSHIFTNO      CHAR(1)       NOT NULL,
    LSSHIFTDT      DATE          NOT NULL,
    LSBORDNO       CHAR(10)               DEFAULT NULL,
    LSOPRID        CHAR(10)      NOT NULL,
    LSSUPVID       CHAR(10)               DEFAULT NULL,
    LSSTRTDT       DATE                   DEFAULT NULL,
    LSSTRTTM       TIME                   DEFAULT NULL,
    LSENDDT        DATE                   DEFAULT NULL,
    LSENDTM        TIME                   DEFAULT NULL,
    LSSTATUS       CHAR(5)       NOT NULL DEFAULT 'IDLE '
                   CONSTRAINT CK_LSSTATUS
                   CHECK (LSSTATUS IN ('IDLE ','RUN  ','DOWN ','CIP  ','SANIT','MAINT')),
    LSCIPDT        DATE                   DEFAULT NULL,
    LSCIPTM        TIME                   DEFAULT NULL,
    LSCIPBY        CHAR(10)               DEFAULT NULL,
    LSCIPSTAT      CHAR(2)       NOT NULL DEFAULT 'OK'
                   CONSTRAINT CK_LSCIPSTAT
                   CHECK (LSCIPSTAT IN ('OK','DU','OV')),
    LSTOTFILL      INTEGER       NOT NULL DEFAULT 0,
    LSTOTREJ       INTEGER       NOT NULL DEFAULT 0,
    LSTOTDNT       INTEGER       NOT NULL DEFAULT 0,
    LSNOTES        VARCHAR(200)           DEFAULT NULL,
    CONSTRAINT PK_LINESHFT PRIMARY KEY (LSLINENO, LSSHIFTNO, LSSHIFTDT)
);

-- =============================================================================
-- TABLE: LBLLOG — Label Print Log
-- =============================================================================
CREATE TABLE APEXMFG.LBLLOG (
    LLLOGID        BIGINT        NOT NULL
                   GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    LLCNTNRID      CHAR(20)      NOT NULL,
    LLBORDNO       CHAR(10)      NOT NULL,
    LLLOTNO        CHAR(16)      NOT NULL,
    LLITEMNO       CHAR(18)      NOT NULL,
    LLLBLTYP       CHAR(6)       NOT NULL
                   CONSTRAINT CK_LLLBLTYP
                   CHECK (LLLBLTYP IN ('PROD  ','SHIP  ','HZRD  ','HOLD  ','REWORK')),
    LLLBLVER       CHAR(3)       NOT NULL DEFAULT '001',
    LLPRTRID       CHAR(10)      NOT NULL,
    LLPRTBY        CHAR(10)      NOT NULL DEFAULT USER,
    LLPRTDT        DATE          NOT NULL DEFAULT CURRENT_DATE,
    LLPRTTM        TIME          NOT NULL DEFAULT CURRENT_TIME,
    LLPRTSTAT      CHAR(2)       NOT NULL DEFAULT 'OK'
                   CONSTRAINT CK_LLPRTSTAT
                   CHECK (LLPRTSTAT IN ('OK','ER','CA')),
    LLREPFLG       CHAR(1)       NOT NULL DEFAULT 'N',
    LLREPRSN       VARCHAR(120)           DEFAULT NULL,
    LLREPAUTH      CHAR(10)               DEFAULT NULL,
    CONSTRAINT PK_LBLLOG PRIMARY KEY (LLLOGID)
);

-- =============================================================================
-- TABLE: INVTRANS — Inventory Transaction Log (all movements)
-- =============================================================================
CREATE TABLE APEXMFG.INVTRANS (
    ITTRANSID      BIGINT        NOT NULL
                   GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    ITTRANSTYP     CHAR(4)       NOT NULL
                   CONSTRAINT CK_ITTRANSTYP
                   CHECK (ITTRANSTYP IN ('RCPT','ISSU','RTRN','ADJP','ADJN',
                                         'SCRAP','DEST','TRFR','HOLD','RELE')),
    ITITEMNO       CHAR(18)      NOT NULL,
    ITLOTNO        CHAR(16)      NOT NULL,
    ITBORDNO       CHAR(10)               DEFAULT NULL,
    ITCNTNRID      CHAR(20)               DEFAULT NULL,
    ITQTY          DECIMAL(9,3)  NOT NULL,
    ITUOM          CHAR(3)       NOT NULL DEFAULT 'KG',
    ITFROMLOC      CHAR(10)               DEFAULT NULL,
    ITTOLOC        CHAR(10)               DEFAULT NULL,
    ITREFNO        CHAR(20)               DEFAULT NULL,
    ITREASON       VARCHAR(80)            DEFAULT NULL,
    ITCRTBY        CHAR(10)      NOT NULL DEFAULT USER,
    ITCRTDT        DATE          NOT NULL DEFAULT CURRENT_DATE,
    ITCRTTM        TIME          NOT NULL DEFAULT CURRENT_TIME,
    CONSTRAINT PK_INVTRANS PRIMARY KEY (ITTRANSID)
);

-- =============================================================================
-- TABLE: FORMSPEC — Formula Specification
--        Stores the bill of materials / formula for each finished good.
--        BLNDVAL reads this to validate ingredient issues.
-- =============================================================================
CREATE TABLE APEXMFG.FORMSPEC (
    FSFORMCD       CHAR(10)      NOT NULL,
    FSFORMVER      SMALLINT      NOT NULL DEFAULT 1,
    FSITEMNO       CHAR(18)      NOT NULL,   -- Finished good item
    FSLINESEQ      SMALLINT      NOT NULL,   -- Line sequence in formula
    FSCOMPITEM     CHAR(18)      NOT NULL,   -- Component / ingredient item
    FSCOMPUOM      CHAR(3)       NOT NULL DEFAULT 'KG',
    FSQTYPER       DECIMAL(9,5)  NOT NULL,   -- Qty per 100 KG batch
    FSTOLNEG       DECIMAL(5,3)  NOT NULL DEFAULT 0.500,  -- Tolerance neg %
    FSTOLPOS       DECIMAL(5,3)  NOT NULL DEFAULT 0.500,  -- Tolerance pos %
    FSCRITICAL     CHAR(1)       NOT NULL DEFAULT 'N',    -- Critical ingredient
    FSACTIVE       CHAR(1)       NOT NULL DEFAULT 'Y',
    FSEFFDTE       DATE          NOT NULL DEFAULT CURRENT_DATE,
    FSEXPDTE       DATE                   DEFAULT NULL,
    FSCRTBY        CHAR(10)      NOT NULL DEFAULT USER,
    FSCRTDT        DATE          NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT PK_FORMSPEC PRIMARY KEY (FSFORMCD, FSFORMVER, FSLINESEQ),
    CONSTRAINT FK_FORMSPEC_FGITEM
        FOREIGN KEY (FSITEMNO) REFERENCES APEXMFG.RMATMAS (RMITEMNO),
    CONSTRAINT FK_FORMSPEC_COMP
        FOREIGN KEY (FSCOMPITEM) REFERENCES APEXMFG.RMATMAS (RMITEMNO)
);

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX APEXMFG.IX_LOTMSTR_STAT  ON APEXMFG.LOTMSTR  (LQASTAT, LEXPDT);
CREATE INDEX APEXMFG.IX_LOTMSTR_ITEM  ON APEXMFG.LOTMSTR  (LOTITEM, LQASTAT);
CREATE INDEX APEXMFG.IX_BLNDORDR_STAT ON APEXMFG.BLNDORDR (BSTATUS, BSCHEDDT);
CREATE INDEX APEXMFG.IX_BLNDORDR_LINE ON APEXMFG.BLNDORDR (BLINENO, BSHIFTNO, BSTATUS);
CREATE INDEX APEXMFG.IX_INGRISS_BORD  ON APEXMFG.INGRISS  (IIBORDNO);
CREATE INDEX APEXMFG.IX_CNTNRFIL_BORD ON APEXMFG.CNTNRFIL (CFBORDNO, CFSTATUS);
CREATE INDEX APEXMFG.IX_CNTNRFIL_LOT  ON APEXMFG.CNTNRFIL (CFLOTNO);
CREATE INDEX APEXMFG.IX_QLTHOLD_STAT  ON APEXMFG.QLTHOLD  (QHSTATUS, QHHOLDDT);
CREATE INDEX APEXMFG.IX_QLTHOLD_LOT   ON APEXMFG.QLTHOLD  (QHLOTNO, QHSTATUS);
CREATE INDEX APEXMFG.IX_INVTRANS_LOT  ON APEXMFG.INVTRANS (ITLOTNO, ITTRANSTYP, ITCRTDT);
CREATE INDEX APEXMFG.IX_INVTRANS_BORD ON APEXMFG.INVTRANS (ITBORDNO, ITCRTDT);
CREATE INDEX APEXMFG.IX_LBLLOG_CNTNR  ON APEXMFG.LBLLOG   (LLCNTNRID, LLPRTDT);
CREATE INDEX APEXMFG.IX_FORMSPEC_ITEM ON APEXMFG.FORMSPEC  (FSITEMNO, FSACTIVE);
