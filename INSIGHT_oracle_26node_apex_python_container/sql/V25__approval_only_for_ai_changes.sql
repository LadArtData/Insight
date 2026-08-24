SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- APPROVAL IS FOR THE ASSISTANT, NOT FOR THE CONSULTANT
--
-- The workflow was built around one guardrail, stated plainly in V16: the
-- assistant proposes, a human confirms, so a model can never quietly turn a
-- verbal aside into an unreviewed fact.
--
-- What was actually implemented gated EVERY change to an answer of record,
-- whoever made it. On a client that is nearly complete, every subsequent
-- pass is edits, so every pass filled the queue. One test client reached a
-- hundred and thirty-three pending requests while the record still held the
-- values typed on the first pass -- and since nothing in the product ever
-- called approve_change_request, none of them could be applied. The answers
-- were not lost; they were unreachable, which from the outside is the same
-- thing.
--
-- Worse, it is ceremony that protects nothing here: there is no sign-in, so
-- the person approving is the person who typed it.
--
-- So the gate keys off WHO is proposing:
--
--   AI_ASSIST                      queues, and waits for a person
--   SALES_INTAKE / CONSULTANT      applies, and keeps the previous value in
--                                  the audit trail
--
-- The audit trail is not lost by applying directly. Every applied edit still
-- writes an APPLIED row to insight_answer_change_requests carrying what the
-- value used to be, so "what did this say before, and who changed it" is
-- still answerable. What changes is that nobody has to click twice to make
-- their own typing real.
-- ============================================================================

-- APPLIED is a new terminal status: changed without review, distinct from
-- APPROVED, which means a person looked at it. Collapsing the two would lose
-- exactly the distinction this migration is about.
ALTER TABLE insight_answer_change_requests DROP CONSTRAINT chk_insight_chgreq_status;

ALTER TABLE insight_answer_change_requests ADD CONSTRAINT chk_insight_chgreq_status
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'APPLIED'));

COMMENT ON COLUMN insight_answer_change_requests.status IS 'PENDING (awaiting review), APPROVED (a person accepted it), REJECTED (a person declined it), APPLIED (a consultant edit, applied directly -- the row is the audit trail, not a request).';

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
        v_source         VARCHAR2(20) := NVL(p_source, 'SALES_INTAKE');
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
                NVL(p_is_skipped, 0), v_source, v_unknown
            );
            x_out_status := 'SAVED';
            RETURN;
        END IF;

        -- Is there an answer of record here, or only a row? A skipped or
        -- "not known yet" row exists but asserts nothing. DBMS_LOB.GETLENGTH
        -- rather than a length comparison, since answer_value is a CLOB and
        -- an empty CLOB is not NULL.
        SELECT COUNT(*)
          INTO v_has_value
          FROM insight_client_answers
         WHERE client_id = p_client_id
           AND question_id = p_question_id
           AND answer_value IS NOT NULL
           AND DBMS_LOB.GETLENGTH(answer_value) > 0;

        -- Straight through, none of which overwrites an answer: a skip, a
        -- "not known yet", and the first real value for a question that had
        -- none.
        IF NVL(p_is_skipped, 0) = 1 OR v_unknown = 1 OR v_has_value = 0 THEN
            UPDATE insight_client_answers
               SET is_skipped    = NVL(p_is_skipped, 0),
                   is_unknown    = v_unknown,
                   answer_value  = CASE
                                     WHEN v_unknown = 1 THEN NULL
                                     WHEN NVL(p_is_skipped, 0) = 1 AND v_value IS NULL THEN answer_value
                                     ELSE v_value
                                   END,
                   answer_source = v_source,
                   answered_by   = p_actor,
                   answered_at   = CURRENT_TIMESTAMP
             WHERE client_id = p_client_id
               AND question_id = p_question_id;
            x_out_status := 'SAVED';
            RETURN;
        END IF;

        -- An answer of record is being changed. Who is asking decides.
        IF v_source = 'AI_ASSIST' THEN
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
        ELSE
            -- Applied, and recorded. The APPLIED row is what makes "what did
            -- this say before, and who changed it" still answerable -- the
            -- audit trail survives even though the approval step does not.
            INSERT INTO insight_answer_change_requests (
                client_id, question_id, previous_value, proposed_value,
                submitted_by, submitted_at, status, reviewed_by, reviewed_at, review_note
            )
            SELECT p_client_id, p_question_id, answer_value, v_value,
                   p_actor, CURRENT_TIMESTAMP, 'APPLIED', p_actor, CURRENT_TIMESTAMP,
                   'Applied directly: consultant edit.'
              FROM insight_client_answers
             WHERE client_id = p_client_id
               AND question_id = p_question_id;

            UPDATE insight_client_answers
               SET answer_value  = v_value,
                   answer_source = v_source,
                   answered_by   = p_actor,
                   answered_at   = CURRENT_TIMESTAMP,
                   is_skipped    = 0,
                   is_unknown    = 0,
                   -- A changed answer is no longer the confirmed one.
                   -- Leaving is_confirmed set would certify a value nobody
                   -- has looked at.
                   is_confirmed  = 0,
                   confirmed_by  = NULL,
                   confirmed_at  = NULL
             WHERE client_id = p_client_id
               AND question_id = p_question_id;
            x_out_status := 'SAVED';
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

COMMIT;
