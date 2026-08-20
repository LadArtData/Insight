SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- PKG_INSIGHT_ANSWERS body -- provenance-aware.
-- Requires V16 (provenance columns) and V17 (spec).
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
            -- Skips and "not known yet" write straight through. Neither
            -- asserts a value, so there is nothing for a reviewer to weigh:
            -- gating them would fill the approval queue with non-decisions.
            IF NVL(p_is_skipped, 0) = 1 OR v_unknown = 1 THEN
                UPDATE insight_client_answers
                   SET is_skipped    = NVL(p_is_skipped, 0),
                       is_unknown    = v_unknown,
                       answer_value  = CASE WHEN v_unknown = 1 THEN NULL ELSE answer_value END,
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
