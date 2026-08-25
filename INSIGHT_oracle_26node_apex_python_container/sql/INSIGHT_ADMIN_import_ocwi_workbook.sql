SET DEFINE OFF
SET SERVEROUTPUT ON
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- IMPORT: OUTAGAMIE COUNTY, FROM THE OCWI GL CONFIGURATION WORKBOOK
--
-- Creates one client and the answers a completed GL configuration workbook
-- actually evidences. This is the hand-run stand-in for the upload feature
-- that does not exist yet -- for an existing client there is no interview to
-- run, because the engagement already happened and the workbook is the only
-- record of it.
--
-- 23 answers, out of the 49 questions in a GL-only scope. Every one carries a
-- comment naming the sheet and column it came from. The other 26 are left
-- BLANK ON PURPOSE:
--
--   * A GL workbook cannot answer the AP, AR, Fixed Assets or Cash Management
--     qualifiers, so those are not answered here. Answering them would be
--     inventing a scope decision.
--   * Nobody recorded employee count, conversion year counts, approval
--     thresholds, or reporting requirements. A blank is the honest record of
--     that, and it is what tells a consultant what to ask next time.
--
-- Two answers are the opposite of missing: GL-006 and GL-019 record "none
-- defined", because the Cross-Validation Rules, Segment Security and
-- Allocation sheets are empty. That is a finding, not a gap.
--
-- Written through pkg_insight_answers.record_answer rather than by INSERT, so
-- the import behaves like any other write: provenance is set, the first
-- answer to a question saves directly, and a re-run against an answer that
-- has since changed raises a change request instead of overwriting it.
--
-- Source is AI_ASSIST -- the closest of the three permitted values to what
-- actually happened, which is a machine reading a spreadsheet. It is
-- deliberately not SALES_INTAKE: no rep sat with this client and asked.
--
-- NOT Flyway-tracked. This is client data for one client, not schema.
-- Requires V25.
-- ============================================================================

DECLARE
    v_client_id CONSTANT VARCHAR2(40)  := 'client_ocwi_outagamie';
    v_name      CONSTANT VARCHAR2(300) := 'Outagamie County';
    v_actor     CONSTANT VARCHAR2(100) := 'workbook-import';
    v_status    VARCHAR2(30);
    v_saved     NUMBER := 0;
    v_pending   NUMBER := 0;

    PROCEDURE put(p_qid IN VARCHAR2, p_value IN VARCHAR2) IS
    BEGIN
        pkg_insight_answers.record_answer(
            p_client_id   => v_client_id,
            p_question_id => p_qid,
            p_value       => p_value,
            p_actor       => v_actor,
            p_is_skipped  => 0,
            p_source      => 'AI_ASSIST',
            p_is_unknown  => 0,
            x_out_status  => v_status);
        IF v_status = 'PENDING_APPROVAL' THEN
            v_pending := v_pending + 1;
        ELSE
            v_saved := v_saved + 1;
        END IF;
    END put;
BEGIN
    MERGE INTO insight_clients t
    USING (SELECT v_client_id AS client_id FROM dual) s
       ON (t.client_id = s.client_id)
    WHEN MATCHED THEN UPDATE SET t.company_name = v_name
    WHEN NOT MATCHED THEN INSERT (client_id, company_name, created_by)
                          VALUES (v_client_id, v_name, v_actor);

    -- Legal Entity sheet, Legal Entity Name; Ledger sheet, Description
    put('INTAKE-001',
        'Outagamie County, Wisconsin. Legal name: COUNTY OF OUTAGAMIE.');

    -- CB-OCWI Budget / Adopted-Monthly Track / Adopted BC, Budget Manager
    put('INTAKE-003',
        'Michelle Uitenbroek, Budget Manager — named on all three control budgets.');

    -- Legal Entity sheet -- jurisdiction and entity name. Size is nowhere in the workbook
    put('INTAKE-004',
        'County government, Wisconsin. Employee count and revenue are not stated in the workbook.');

    -- Legal Entity sheet -- one entity row
    put('INTAKE-005',
        '1');

    -- Journal Categories sheet -- custom category Conversion, described as conversion from JDE
    put('INTAKE-006',
        'JD Edwards. The workbook carries a custom journal category ''Conversion'', described as conversion from JDE.');

    -- CB sheets, Source Budget Type
    put('INTAKE-007',
        'Hyperion Planning supplies the source budget for all three control budgets.');

    -- Legal Entity sheet, the single populated row
    put('GL-001',
        'COUNTY OF OUTAGAMIE. EIN/TIN 39-6005724. 320 S. Walnut Street, Appleton WI 54911, United States. Jurisdiction: United States Federal Tax. Payroll statutory unit and legal employer: yes. 1099 reporting entity: yes. Start date 1951-01-01.');

    -- Ledger sheet -- Currency, Accounting Method, Ledger Type
    put('GL-002',
        'USD. Accounting method: OCWI Accrual with Encumbrances. One primary ledger (OCWI); no secondary or reporting ledger is defined.');

    -- Manage COA Structures and Manage COA Value Sets -- segment order, codes, maximum lengths, delimiter
    put('GL-004',
        'Six segments: Fund(5), Cost Center(6), Program(5), Natural Account(6), Activity(7), Future 1(7). Delimiter ''.''. Structure OCWI_COA.');

    -- Cross-Validation Rules and Segment Security sheets -- both empty below the header
    put('GL-006',
        'None defined. Both the Cross-Validation Rules and Segment Security sheets are empty in the workbook.');

    -- Manage Accounting Calendar -- Period Frequency, Format, First Period, Start Date
    put('GL-008',
        'Calendar year with monthly periods. Calendar OCWI_Month, format MMMYYYY, first period JAN-2027, built back to 1951 to carry converted history.');

    -- Manage Accounting Calendar -- Adjusting Period Frequency
    put('GL-009',
        'Two. Adjusting period frequency is set to ''Twice at year end''.');

    -- Ledger sheet -- Number of Future Enterable Periods, Enable Suspense
    put('GL-010',
        'One future enterable period. Suspense posting is disabled for both General Ledger and Subledger Accounting.');

    -- Journal Categories sheet -- the two custom rows
    put('GL-011',
        'Custom categories: Conversion (from JDE) and YE Carryover, alongside Oracle''s seeded categories.');

    -- Journal Approval sheet -- approval group names
    put('GL-012',
        'Approval groups exist by function — GL Finance, GL General Accounting, GL Human Services and others. Dollar thresholds are not stated in the workbook.');

    -- Auto Post Criteria Sets sheet
    put('GL-013',
        'One AutoPost criteria set, ''All Journals'': all sources, all categories, Actual balance type, priority 1, enabled.');

    -- Journal Reversal Criteria Sets sheet
    put('GL-014',
        'Reversal set ''OCWI Reversal Set'' on the Accrual category — reverse automatically, switch debit or credit, no default reversal period.');

    -- The three CB-* sheets
    put('GL-015',
        'Three control budgets: OCWI Adopted-Monthly Track, OCWI Budget, and OCWI Adopted BC.');

    -- CB-* sheets, Control Level
    put('GL-017',
        'Track on the monthly and annual budgets; Advisory on Adopted BC. No absolute control is configured.');

    -- CB-* sheets, Budget Manager
    put('GL-018',
        'Budget manager Michelle Uitenbroek is named on all three control budgets.');

    -- Allocation sheet -- empty below the header
    put('GL-019',
        'None defined. The Allocation sheet is empty in the workbook.');

    -- Descriptive Flexfields sheet, GLOBAL SEGMENTS block
    put('GL-023',
        'Descriptive flexfields on GL account combinations: State Reporting Code, GEARS Profile ID, GEARS Profile Type, GEARS Agency Code, SPARC Code.');

    -- CB sheets Source Budget Type; Journal Categories Conversion row
    put('GL-025',
        'Hyperion Planning feeds the control budgets. JD Edwards is the legacy source being converted.');
    -- The workbook contradicts itself, and the record should say so rather
    -- than quietly carrying it. Every one of the 13 Journal Approval members
    -- and 24 of the 26 InterCompany Approval members has an @fdlco.wi.gov
    -- address -- Fond du Lac County -- while the legal entity is Outagamie.
    -- The approval sheets were copied from another engagement and never
    -- updated, so no approver was imported as Outagamie's.
    INSERT INTO insight_client_notes (client_id, note_text, note_source, created_by)
    VALUES (v_client_id,
            'Imported from the OCWI GL configuration workbook. Note: every Journal Approval member and 24 of 26 InterCompany Approval members carry @fdlco.wi.gov (Fond du Lac County) addresses while the legal entity is Outagamie. Those sheets appear to be copied from another engagement. No approver was imported.',
            'AI_ASSIST', v_actor);

    UPDATE insight_clients
       SET updated_at = CURRENT_TIMESTAMP
     WHERE client_id = v_client_id;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Imported ' || v_name || ' (' || v_client_id || ')');
    DBMS_OUTPUT.PUT_LINE('  answers applied        : ' || v_saved);
    DBMS_OUTPUT.PUT_LINE('  raised for review      : ' || v_pending);
    DBMS_OUTPUT.PUT_LINE('  left blank on purpose  : 26 of 49 in a GL-only scope');
    DBMS_OUTPUT.PUT_LINE('  1 note recorded about the approval-sheet mismatch');
END;
/

-- Verify:
--   SELECT company_name, pct_complete, pending_change_requests
--     FROM insight_client_summary WHERE client_id = 'client_ocwi_outagamie';
--   SELECT question_id, answer_source, SUBSTR(answer_value,1,60)
--     FROM insight_client_answers WHERE client_id = 'client_ocwi_outagamie'
--    ORDER BY question_id;
