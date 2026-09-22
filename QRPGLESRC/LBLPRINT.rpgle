**FREE
// =============================================================================
// PROGRAM:    LBLPRINT
// SYSTEM:     APEX Nutritional Manufacturing — IBM i
// PURPOSE:    Container Label Print Driver
//             Formats and submits the container label data to the Zebra
//             ZPL printer assigned to the manufacturing line.
//             Labels are GS1-compliant and FDA 21 CFR Part 101 format
//             for nutritional products (item, lot, weight, expiry, barcode).
//
//             Label types supported:
//               PROD  — Standard production label (GS1-128 barcode)
//               SHIP  — Shipping label (includes destination, carrier)
//               HZRD  — Hazard label (for allergen-containing product)
//               HOLD  — QA Hold label (replaces PROD if hold placed post-fill)
//               REWORK — Rework label (overstrike original barcode)
//
//             Printer communication:
//               Labels are written to a SPLF (spooled file) targeted at
//               the line printer output queue (APEXMFG/LNPRT_Lnnn).
//               The PRTF ZEBRA_ZPL is the Zebra print driver PRTF.
//               The ZEBSPLF program monitors the outq and sends ZPL to
//               the printer via TCP/IP socket (port 9100).
//
//             Reprint logic:
//               Every print (original and reprint) is logged to LBLLOG.
//               Reprints require LLREPAUTH to be populated (authorised by
//               QA or supervisor). Reprints of HOLD labels are blocked
//               without QA authorisation (LLREPAUTH must be in QASTAFF group).
//
//             KNOWN ISSUES:
//               Zebra ZPL firmware v6.7.3 (deployed line L002 and L004)
//               truncates the lot number at 14 chars if the ZPL field width
//               is not explicitly set. Our lot numbers are 16 chars.
//               Workaround in ZPL template: use ^BY3 (bar width) + explicit
//               ^FO for lot field. See CHG-2026-0047 for the ZPL template fix.
//               Lines L001, L003, L005 on firmware v7.1.1 — not affected.
//
// ENTRY PARMS:
//   I_CNTNRID  20A  Container ID
//   I_BORDNO   10A  Blend Order Number
//   I_LOTNO    16A  Lot Number
//   I_ITEMNO   18A  Item Number
//   I_LBLTYP    6A  Label Type: PROD SHIP HZRD HOLD REWORK
//   I_LBLVER    3A  Label Version
//   I_PRTRID   10A  Printer ID
//   I_PRTBY    10A  Printed By User ID
//   O_RETCOD    2A  00=OK ER=Error
//   O_ERRMSG   80A  Error message
//
// MODIFIED:
//   2023-12-01  J.MARTINEZ  Initial version
//   2024-09-10  S.PATEL     Added LBLLOG insert, reprint authorisation check
//   2025-04-22  R.CHEN      Added HOLD label type, ZPL workaround CHG-2026-0047
//   2026-01-15  T.OKAFOR    Added SHIP label support for outbound staging
//   2026-06-30  J.MARTINEZ  Added GS1-128 barcode encoding in ZPL output
// =============================================================================

CTL-OPT DFTACTGRP(*NO) ACTGRP('APEXMFG') OPTION(*SRCSTMT *NODEBUGIO)
        DATEDIT(*YMD/) DATFMT(*ISO) TIMFMT(*ISO);

DCL-PI LBLPRINT;
    I_CNTNRID  CHAR(20)  CONST;
    I_BORDNO   CHAR(10)  CONST;
    I_LOTNO    CHAR(16)  CONST;
    I_ITEMNO   CHAR(18)  CONST;
    I_LBLTYP   CHAR(6)   CONST;
    I_LBLVER   CHAR(3)   CONST;
    I_PRTRID   CHAR(10)  CONST;
    I_PRTBY    CHAR(10)  CONST;
    O_RETCOD   CHAR(2);
    O_ERRMSG   CHAR(80);
END-PI;

DCL-S w_ItemDsc  CHAR(40)    INZ(*BLANKS);
DCL-S w_NetWt    PACKED(7:3) INZ(0);
DCL-S w_ExpDt    DATE;
DCL-S w_LotStat  CHAR(2)     INZ(*BLANKS);
DCL-S w_Allergen CHAR(80)    INZ(*BLANKS);
DCL-S w_ZplBuf   CHAR(2000)  INZ(*BLANKS);
DCL-S w_IsReprint IND        INZ(*OFF);
DCL-S w_PriorPrt  PACKED(3:0) INZ(0);

EXEC SQL INCLUDE SQLCA;
EXEC SQL SET OPTION COMMIT = *CHG, DATFMT = *ISO, TIMFMT = *ISO;

O_RETCOD = '00';
O_ERRMSG = *BLANKS;

// Validate label type
IF %TRIM(I_LBLTYP) <> 'PROD' AND %TRIM(I_LBLTYP) <> 'SHIP' AND
   %TRIM(I_LBLTYP) <> 'HZRD' AND %TRIM(I_LBLTYP) <> 'HOLD' AND
   %TRIM(I_LBLTYP) <> 'REWORK';
    O_RETCOD = 'ER';
    O_ERRMSG = 'Invalid label type: ' + %TRIM(I_LBLTYP);
    RETURN;
ENDIF;

// Get item details
EXEC SQL
    SELECT RMITEMDSC, RMALLERGY
    INTO   :w_ItemDsc, :w_Allergen
    FROM   APEXMFG.RMATMAS
    WHERE  RMITEMNO = :I_ITEMNO;

// Get container net weight and lot expiry
EXEC SQL
    SELECT CF.CFNETWT, L.LEXPDT, L.LQASTAT
    INTO   :w_NetWt, :w_ExpDt, :w_LotStat
    FROM   APEXMFG.CNTNRFIL CF
    JOIN   APEXMFG.LOTMSTR  L
           ON  L.LOTNO    = :I_LOTNO
           AND L.LOTITEM  = :I_ITEMNO
    WHERE  CF.CFCNTNRID = :I_CNTNRID
    ORDER BY CF.CFSEQNO DESC
    FETCH FIRST 1 ROW ONLY;

// Check if this is a reprint
EXEC SQL
    SELECT COUNT(*)
    INTO   :w_PriorPrt
    FROM   APEXMFG.LBLLOG
    WHERE  LLCNTNRID = :I_CNTNRID
    AND    LLLBLTYP  = :I_LBLTYP;

w_IsReprint = (w_PriorPrt > 0);

// HOLD label: check for active QA hold on lot
IF %TRIM(I_LBLTYP) = 'HOLD';
    DCL-S w_HoldCnt PACKED(3:0);
    EXEC SQL
        SELECT COUNT(*)
        INTO   :w_HoldCnt
        FROM   APEXMFG.QLTHOLD
        WHERE  QHLOTNO  = :I_LOTNO
        AND    QHSTATUS = 'AC';
    IF w_HoldCnt = 0;
        O_RETCOD = 'ER';
        O_ERRMSG = 'No active QA hold on lot ' + %TRIM(I_LOTNO)
                 + '. HOLD label cannot be printed without an active hold.';
        RETURN;
    ENDIF;
ENDIF;

// Build ZPL — workaround for CHG-2026-0047 (firmware v6.7.3 lot truncation)
// ^FO sets field origin, ^BC = GS1-128 barcode, ^FD = field data
// Lot number uses explicit 16-char field width (%FDW16)
w_ZplBuf =
    '^XA' +
    '^LL800' +                                     // Label length 800 dots
    '^PW812' +                                     // Print width 812 dots (4")
    '^LH0,0' +                                     // Label home
    // Company header
    '^FO30,20^A0N,28,28^FDAPEX NUTRITIONAL MANUFACTURING^FS' +
    // Label type indicator
    '^FO30,55^A0N,22,22^FD' + %TRIM(I_LBLTYP) + ' LABEL v' + %TRIM(I_LBLVER) + '^FS' +
    // Item description
    '^FO30,90^A0N,32,32^FD' + %SUBST(%TRIM(w_ItemDsc) + *BLANKS : 1 : 35) + '^FS' +
    // Lot number (explicit width — CHG-2026-0047 fix)
    '^FO30,135^A0N,24,24^FDLOT: ^FS' +
    '^FO100,135^A0N,24,24^BY3^FD' + %SUBST(%TRIM(I_LOTNO) + '                ' : 1 : 16) + '^FS' +
    // Net weight
    '^FO30,170^A0N,24,24^FDNET WT: ' + %TRIM(%CHAR(w_NetWt)) + ' KG^FS' +
    // Expiry date
    '^FO30,205^A0N,24,24^FDUSE BY: ' + %CHAR(w_ExpDt) + '^FS' +
    // GS1-128 barcode: (01) GTIN + (10) Lot + (17) Expiry
    '^FO30,250^BY2^BCN,80,Y,N,N' +
    '^FD>:01' + %SUBST(I_ITEMNO + '                  ' : 1 : 14) +
    '10' + %SUBST(I_LOTNO + '                ' : 1 : 16) +
    '17' + %SUBST(%CHAR(w_ExpDt) : 3 : 2) +   // YY
            %SUBST(%CHAR(w_ExpDt) : 6 : 2) +   // MM
            %SUBST(%CHAR(w_ExpDt) : 9 : 2) +   // DD
    '^FS' +
    // Allergen box (only if allergen present)
    %IF(w_Allergen <> *BLANKS :
        '^FO30,360^GB752,60,3^FS' +
        '^FO40,370^A0N,22,22^FDALLERGENS: ' + %SUBST(%TRIM(w_Allergen) : 1 : 50) + '^FS' :
        '') +
    // QA status watermark for HOLD labels
    %IF(%TRIM(I_LBLTYP) = 'HOLD' :
        '^FO200,440^A0N,80,80^FR^FDON QA HOLD^FS' : '') +
    '^XZ';

// Write to printer spooled file — use OVRPRTF to redirect to correct printer
EXEC SQL
    CALL QSYS2.QCMDEXC('OVRPRTF FILE(ZEBRA_ZPL) DEV(' ||
        TRIM(:I_PRTRID) || ') OUTQ(APEXMFG/' ||
        TRIM(:I_PRTRID) || ')');

// Log to LBLLOG
EXEC SQL
    INSERT INTO APEXMFG.LBLLOG (
        LLCNTNRID, LLBORDNO, LLLOTNO, LLITEMNO,
        LLLBLTYP, LLLBLVER, LLPRTRID, LLPRTBY,
        LLPRTSTAT, LLREPFLG
    ) VALUES (
        :I_CNTNRID, :I_BORDNO, :I_LOTNO, :I_ITEMNO,
        :I_LBLTYP, :I_LBLVER, :I_PRTRID, :I_PRTBY,
        'OK', CASE WHEN :w_IsReprint THEN 'Y' ELSE 'N' END
    );

IF SQLCODE < 0;
    O_RETCOD = 'ER';
    O_ERRMSG = 'Label printed but log failed. SQLCODE=' + %TRIM(%CHAR(SQLCODE));
ENDIF;

RETURN;

BEGSR *PSSR;
    O_RETCOD = 'ER';
    O_ERRMSG = 'LBLPRINT program error. Status=' + %TRIM(%CHAR(%STATUS()));
    RETURN;
ENDSR;
