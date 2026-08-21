SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- FILLING A BLANK IS NOT AN EDIT
--
-- record_answer decided whether to gate a write by asking "does a row exist
-- for this client and question", and a row exists as soon as a question is
-- skipped or marked "not known yet" -- both of which store NO value.
--
-- So the first real answer to a skipped question was treated as an edit to
-- something already on record and routed into the approval queue. The value
-- never reached insight_client_answers. That is precisely the path the AI
-- Follow-Up chat takes: it exists to fill gaps, and a gap is usually a
-- skipped question. Every answer given in the chat went to PENDING and the
-- client record stayed blank.
--
-- The gate should key off the VALUE, not the row. The approval workflow
-- protects an answer of record from being silently overwritten; when the
-- stored value is NULL there is nothing to protect and nothing for a
-- reviewer to weigh -- only a blank being filled in, which is ordinary
-- intake.
--
-- Two changes, both here:
--   1. The package body, so it stops happening.
--   2. The rows it already produced, so the answers that were captured but
--      never applied are applied now.
-- ============================================================================

CREATE OR REPLACE PACKAGE BODY pkg_insight_answers AS

    PROCEDURE record_answer(
        p_client_id      IN VARCHAR2,
        p_question_id    IN VARCHAR2,
        p_value          IN CLOB,
        p_actor          IN VARCHAR2,
        p_is_skipped     IN NUMBER DEFAULT 0,
        x_out_status     OUT VARCHAR2,
        p_source         IN VARCHAR2 DEFAULT 'SALES_INTAKE',
        p_is_unknown     IN NUMBER DEFAULT 0
    ) IS
        v_existing_count NUMBER;
        v_has_value      NUMBER;
        v_unknown        NUMBER := NVL(p_is_unknown, 0);
        v_value          CLOB   := p_value;
    BEGIN
        IF p_client_id IS NULL OR p_question_id IS NULL THEN
            RAISE_APPLICATION_ERROR(-20101, 'client_id and question_id are required.');
        END IF;

        -- "Not known yet" and a value are mutually exclusive; the column
        -- constraint enforces it, so normalise here rather than letting a
        -- caller trip over it.
        IF v_unknown = 1 THEN
            v_value := NULL;
        END IF;

        SELECT COUNT(*)
          INTO v_existing_count
          FROM insight_client_answers
         WHERE client_id = p_client_id
           AND question_id = p_question_id;

        IF v_existing_count = 0 THEN
            INSERT INTO insight_client_answers (
                client_id, question_id, answer_value, answered_by, answered_at,
                is_skipped, answer_source, is_unknown
            ) VALUES (
                p_client_id, p_question_id, v_value, p_actor, CURRENT_TIMESTAMP,
                NVL(p_is_skipped, 0), NVL(p_source, 'SALES_INTAKE'), v_unknown
            );
            x_out_status := 'SAVED';

        ELSE
            -- Is there actually an answer of record here, or only a row?
            -- A skipped or "not known yet" row exists but asserts nothing.
            -- DBMS_LOB.GETLENGTH rather than a length comparison, since
            -- answer_value is a CLOB and an empty CLOB is not NULL.
            SELECT COUNT(*)
              INTO v_has_value
              FROM insight_client_answers
             WHERE client_id = p_client_id
               AND question_id = p_question_id
               AND answer_value IS NOT NULL
               AND DBMS_LOB.GETLENGTH(answer_value) > 0;

            -- Straight through in three cases, none of which overwrites an
            -- answer: a skip, a "not known yet", and the first real value
            -- for a question that had none. Gating any of them would fill
            -- the approval queue with non-decisions -- and in the last case
            -- would lose the answer entirely, since a pending request is
            -- not an answer.
            IF NVL(p_is_skipped, 0) = 1 OR v_unknown = 1 OR v_has_value = 0 THEN
                UPDATE insight_client_answers
                   SET is_skipped    = NVL(p_is_skipped, 0),
                       is_unknown    = v_unknown,
                       answer_value  = CASE
                                         WHEN v_unknown = 1 THEN NULL
                                         WHEN NVL(p_is_skipped, 0) = 1 AND v_value IS NULL THEN answer_value
                                         ELSE v_value
                                       END,
                       answer_source = NVL(p_source, answer_source),
                       answered_by   = p_actor,
                       answered_at   = CURRENT_TIMESTAMP
                 WHERE client_id = p_client_id
                   AND question_id = p_question_id;
                x_out_status := 'SAVED';
            ELSE
                INSERT INTO insight_answer_change_requests (
                    client_id, question_id, previous_value, proposed_value,
                    submitted_by, submitted_at, status
                )
                SELECT p_client_id, p_question_id, answer_value, v_value,
                       p_actor, CURRENT_TIMESTAMP, 'PENDING'
                  FROM insight_client_answers
                 WHERE client_id = p_client_id
                   AND question_id = p_question_id;
                x_out_status := 'PENDING_APPROVAL';
            END IF;
        END IF;
    END record_answer;

    PROCEDURE approve_change_request(
        p_request_id     IN NUMBER,
        p_reviewer       IN VARCHAR2,
        p_note           IN VARCHAR2 DEFAULT NULL
    ) IS
        v_client_id      VARCHAR2(40);
        v_question_id    VARCHAR2(20);
        v_proposed_value CLOB;
        v_status         VARCHAR2(10);
    BEGIN
        SELECT client_id, question_id, proposed_value, status
          INTO v_client_id, v_question_id, v_proposed_value, v_status
          FROM insight_answer_change_requests
         WHERE request_id = p_request_id
         FOR UPDATE;

        IF v_status != 'PENDING' THEN
            RAISE_APPLICATION_ERROR(-20102, 'Change request ' || p_request_id || ' is already ' || v_status || '.');
        END IF;

        UPDATE insight_client_answers
           SET answer_value = v_proposed_value,
               answered_by = p_reviewer,
               answered_at = CURRENT_TIMESTAMP,
               is_skipped = 0,
               is_unknown = 0
         WHERE client_id = v_client_id
           AND question_id = v_question_id;

        UPDATE insight_answer_change_requests
           SET status = 'APPROVED',
               reviewed_by = p_reviewer,
               reviewed_at = CURRENT_TIMESTAMP,
               review_note = p_note
         WHERE request_id = p_request_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20103, 'Change request ' || p_request_id || ' not found.');
    END approve_change_request;

    PROCEDURE reject_change_request(
        p_request_id     IN NUMBER,
        p_reviewer       IN VARCHAR2,
        p_note           IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status VARCHAR2(10);
    BEGIN
        SELECT status
          INTO v_status
          FROM insight_answer_change_requests
         WHERE request_id = p_request_id
         FOR UPDATE;

        IF v_status != 'PENDING' THEN
            RAISE_APPLICATION_ERROR(-20102, 'Change request ' || p_request_id || ' is already ' || v_status || '.');
        END IF;

        UPDATE insight_answer_change_requests
           SET status = 'REJECTED',
               reviewed_by = p_reviewer,
               reviewed_at = CURRENT_TIMESTAMP,
               review_note = p_note
         WHERE request_id = p_request_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20103, 'Change request ' || p_request_id || ' not found.');
    END reject_change_request;

    PROCEDURE confirm_answer(
        p_client_id      IN VARCHAR2,
        p_question_id    IN VARCHAR2,
        p_reviewer       IN VARCHAR2
    ) IS
    BEGIN
        UPDATE insight_client_answers
           SET is_confirmed = 1,
               confirmed_by = p_reviewer,
               confirmed_at = CURRENT_TIMESTAMP
         WHERE client_id = p_client_id
           AND question_id = p_question_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20104,
                'No answer to confirm for ' || p_client_id || ' / ' || p_question_id || '.');
        END IF;
    END confirm_answer;

END pkg_insight_answers;
/

-- ----------------------------------------------------------------------------
-- Repair: apply the answers this bug stranded.
--
-- A pending request whose previous_value is empty is one of them. It cannot
-- be anything else: a genuine edit is a change to an answer that existed, so
-- it always carries the value it is replacing. These have nothing to replace,
-- which is the whole point -- they should never have been requests.
--
-- Applied through approve_change_request rather than raw UPDATEs, so the
-- audit trail reads the same as any other approval and the reviewer note says
-- why. Answers stay provisional (is_confirmed is untouched): this establishes
-- what the client said, not that anyone has verified it.
-- ----------------------------------------------------------------------------
DECLARE
    v_applied NUMBER := 0;
BEGIN
    FOR r IN (
        SELECT request_id
          FROM insight_answer_change_requests
         WHERE status = 'PENDING'
           AND (previous_value IS NULL OR DBMS_LOB.GETLENGTH(previous_value) = 0)
         ORDER BY request_id
    ) LOOP
        pkg_insight_answers.approve_change_request(
            p_request_id => r.request_id,
            p_reviewer   => 'system-V21',
            p_note       => 'Auto-applied: filling a blank answer was never an edit. See V21.');
        v_applied := v_applied + 1;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('V21 applied ' || v_applied || ' stranded answer(s).');
END;
/

COMMIT;
