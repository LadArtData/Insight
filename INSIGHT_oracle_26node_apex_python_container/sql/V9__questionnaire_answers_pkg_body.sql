ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- PL/SQL PACKAGE BODY: PKG_INSIGHT_ANSWERS
-- Requires INSIGHT_07 and INSIGHT_08.
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY pkg_insight_answers AS

    ---------------------------------------------------------------------------
    -- RECORD_ANSWER
    ---------------------------------------------------------------------------
    PROCEDURE record_answer(
        p_client_id      IN VARCHAR2,
        p_question_id    IN VARCHAR2,
        p_value          IN CLOB,
        p_actor          IN VARCHAR2,
        p_is_skipped     IN NUMBER DEFAULT 0,
        x_out_status     OUT VARCHAR2
    ) IS
        v_existing_count NUMBER;
    BEGIN
        IF p_client_id IS NULL OR p_question_id IS NULL THEN
            RAISE_APPLICATION_ERROR(-20101, 'client_id and question_id are required.');
        END IF;

        SELECT COUNT(*)
          INTO v_existing_count
          FROM insight_client_answers
         WHERE client_id = p_client_id
           AND question_id = p_question_id;

        IF v_existing_count = 0 THEN
            -- First answer for this question -- no approval needed, this is
            -- normal intake, not an edit to something already on record.
            INSERT INTO insight_client_answers (
                client_id, question_id, answer_value, answered_by, answered_at, is_skipped
            ) VALUES (
                p_client_id, p_question_id, p_value, p_actor, CURRENT_TIMESTAMP, NVL(p_is_skipped, 0)
            );
            x_out_status := 'SAVED';

        ELSE
            -- Already has an answer -- route the change through approval
            -- instead of overwriting it directly. Skips never need
            -- approval (marking something "come back to this later" isn't
            -- a data change worth gating), so they still write straight
            -- through.
            IF NVL(p_is_skipped, 0) = 1 THEN
                UPDATE insight_client_answers
                   SET is_skipped = 1,
                       answered_by = p_actor,
                       answered_at = CURRENT_TIMESTAMP
                 WHERE client_id = p_client_id
                   AND question_id = p_question_id;
                x_out_status := 'SAVED';
            ELSE
                INSERT INTO insight_answer_change_requests (
                    client_id, question_id, previous_value, proposed_value, submitted_by, submitted_at, status
                )
                SELECT p_client_id, p_question_id, answer_value, p_value, p_actor, CURRENT_TIMESTAMP, 'PENDING'
                  FROM insight_client_answers
                 WHERE client_id = p_client_id
                   AND question_id = p_question_id;
                x_out_status := 'PENDING_APPROVAL';
            END IF;
        END IF;
    END record_answer;

    ---------------------------------------------------------------------------
    -- APPROVE_CHANGE_REQUEST
    ---------------------------------------------------------------------------
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
               is_skipped = 0
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

    ---------------------------------------------------------------------------
    -- REJECT_CHANGE_REQUEST
    ---------------------------------------------------------------------------
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

END pkg_insight_answers;
/
