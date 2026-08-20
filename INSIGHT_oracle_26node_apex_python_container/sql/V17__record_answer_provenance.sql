SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- PKG_INSIGHT_ANSWERS: carry provenance through record_answer
--
-- record_answer gains p_source and p_is_unknown so a caller states where an
-- answer came from and whether it is a deliberate "not known yet". Both are
-- defaulted, so existing callers keep working unchanged.
--
-- Approval behaviour is unchanged: the first answer to a question writes
-- directly, a later change to it routes through insight_answer_change_requests.
-- Confirming an answer is a separate act from writing one -- record_answer
-- never sets is_confirmed, because the whole point of the provisional flag is
-- that the writer cannot self-certify.
-- ============================================================================

CREATE OR REPLACE PACKAGE pkg_insight_answers AS

    PROCEDURE record_answer(
        p_client_id      IN VARCHAR2,
        p_question_id    IN VARCHAR2,
        p_value          IN CLOB,
        p_actor          IN VARCHAR2,
        p_is_skipped     IN NUMBER DEFAULT 0,
        x_out_status     OUT VARCHAR2,
        p_source         IN VARCHAR2 DEFAULT 'SALES_INTAKE',
        p_is_unknown     IN NUMBER DEFAULT 0
    );

    PROCEDURE approve_change_request(
        p_request_id     IN NUMBER,
        p_reviewer       IN VARCHAR2,
        p_note           IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE reject_change_request(
        p_request_id     IN NUMBER,
        p_reviewer       IN VARCHAR2,
        p_note           IN VARCHAR2 DEFAULT NULL
    );

    -- Marking an answer confirmed is deliberately its own call: it is the
    -- act that moves an answer from "a rep said this" to "the team stands
    -- behind this", and it should never be a side effect of saving.
    PROCEDURE confirm_answer(
        p_client_id      IN VARCHAR2,
        p_question_id    IN VARCHAR2,
        p_reviewer       IN VARCHAR2
    );

END pkg_insight_answers;
/
