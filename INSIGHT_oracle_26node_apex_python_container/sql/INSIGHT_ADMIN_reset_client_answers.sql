SET DEFINE OFF
SET SERVEROUTPUT ON
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- RESET ONE CLIENT'S ANSWERS
--
-- Empties a client's answers, change requests and notes while keeping the
-- client row itself -- so the id, the name and anything referencing it
-- survive, and the file reads as a brand new intake.
--
-- Written for build-out: test typing accumulates fast, and V21 faithfully
-- restored a pile of it from the approval queue, because the answers had
-- been captured correctly and were only ever stranded. The fix worked; the
-- data it recovered was never real.
--
-- NOT Flyway-tracked, deliberately. This destroys data on purpose, and a
-- migration is something every environment runs exactly once without being
-- asked. Run it by hand, against the client you name below, when you mean
-- it.
--
-- Set the client id first. Running it as-is affects nothing.
-- ============================================================================

DEFINE client_id = 'PUT_THE_CLIENT_ID_HERE'

DECLARE
    v_client_id  VARCHAR2(40) := '&client_id';
    v_name       VARCHAR2(300);
    v_answers    NUMBER;
    v_requests   NUMBER;
    v_notes      NUMBER;
BEGIN
    BEGIN
        SELECT company_name INTO v_name
          FROM insight_clients
         WHERE client_id = v_client_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20200,
            'No client with id ' || v_client_id || '. Nothing was changed.');
    END;

    SELECT COUNT(*) INTO v_answers
      FROM insight_client_answers WHERE client_id = v_client_id;
    SELECT COUNT(*) INTO v_requests
      FROM insight_answer_change_requests WHERE client_id = v_client_id;
    SELECT COUNT(*) INTO v_notes
      FROM insight_client_notes WHERE client_id = v_client_id;

    -- Change requests first: they reference the answers being removed.
    DELETE FROM insight_answer_change_requests WHERE client_id = v_client_id;
    DELETE FROM insight_client_answers         WHERE client_id = v_client_id;
    DELETE FROM insight_client_notes           WHERE client_id = v_client_id;

    -- The client stays, and so does its name. Only what was answered goes.
    UPDATE insight_clients
       SET primary_contact = NULL,
           updated_at      = CURRENT_TIMESTAMP
     WHERE client_id = v_client_id;

    DBMS_OUTPUT.PUT_LINE('Reset ' || v_name || ' (' || v_client_id || '):');
    DBMS_OUTPUT.PUT_LINE('  answers removed         : ' || v_answers);
    DBMS_OUTPUT.PUT_LINE('  change requests removed : ' || v_requests);
    DBMS_OUTPUT.PUT_LINE('  notes removed           : ' || v_notes);
    DBMS_OUTPUT.PUT_LINE('The client row was kept. Nothing else was touched.');
END;
/

-- Locked answers (QUAL-GL, seeded by the V13 trigger on client creation) are
-- removed along with everything else, since that trigger fires on INSERT and
-- this client already exists. Reopening the client re-answers it: QUAL-GL
-- renders locked at "Yes" and saves on the first Next.

COMMIT;

-- Verify:
--   SELECT COUNT(*) FROM insight_client_answers WHERE client_id = '&client_id';
--   SELECT pct_complete, pending_change_requests
--     FROM insight_client_summary WHERE client_id = '&client_id';
