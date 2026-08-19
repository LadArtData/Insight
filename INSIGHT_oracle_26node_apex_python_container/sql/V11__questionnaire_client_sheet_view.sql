ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- QUESTIONNAIRE BACKEND: CONSOLIDATED "ONE SHEET PER CLIENT" VIEWS
-- Requires INSIGHT_07, INSIGHT_08, INSIGHT_10.
--
-- Two views, not one, because "one sheet per client" means two different
-- things to two different audiences:
--
--   INSIGHT_CLIENT_SHEET   - every answer for a client, one row per
--                             question, joined against the question
--                             metadata. This is the detail view -- a
--                             consultant or Maverick pulls it filtered to
--                             one client_id and gets that client's entire
--                             record in a single query. It's "long" format
--                             (tall, not wide) on purpose: a wide/pivoted
--                             sheet would need a new column added to the
--                             view every time a question is added, which
--                             defeats the whole point of insight_questions
--                             being metadata-driven. Long format absorbs
--                             new questions automatically with zero DDL
--                             changes here. If an actual wide spreadsheet
--                             export is needed, pivot this view at export
--                             time (APEX report, script, etc.) rather than
--                             baking columns into the view.
--
--   INSIGHT_CLIENT_SUMMARY - exactly one row per client: progress,
--                             pending-approval count, document count. This
--                             is the management rollup view described in
--                             the architecture notes (Section 3) -- status
--                             across clients without the full detail every
--                             consultant/implementation-team view needs.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. VIEW: INSIGHT_CLIENT_SHEET (detail -- one row per client + question)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW insight_client_sheet AS
SELECT
    c.client_id,
    c.company_name,
    c.primary_contact,
    c.status                                   AS client_status,
    q.question_id,
    q.module_code,
    q.phase,
    q.eyebrow,
    q.question_text,
    q.answer_type,
    q.is_required,
    q.display_order,
    a.answer_value,
    a.answered_by,
    a.answered_at,
    NVL(a.is_skipped, 0)                       AS is_skipped,
    CASE WHEN a.client_id IS NULL THEN 1 ELSE 0 END AS is_unanswered,
    cr.request_id                              AS pending_request_id,
    cr.proposed_value                          AS pending_proposed_value,
    cr.submitted_by                            AS pending_submitted_by,
    cr.submitted_at                            AS pending_submitted_at
FROM insight_clients c
CROSS JOIN insight_questions q
LEFT JOIN insight_client_answers a
       ON a.client_id = c.client_id
      AND a.question_id = q.question_id
LEFT JOIN insight_answer_change_requests cr
       ON cr.client_id = c.client_id
      AND cr.question_id = q.question_id
      AND cr.status = 'PENDING'
WHERE q.is_active = 1;

COMMENT ON TABLE insight_client_sheet IS 'One row per (client, active question) -- the full discovery record for a client in a single filtered query (WHERE client_id = ...). Long/tall format so new questions in insight_questions appear automatically. Pivot at export time for a wide spreadsheet layout.';

-- ----------------------------------------------------------------------------
-- 2. VIEW: INSIGHT_CLIENT_SUMMARY (rollup -- one row per client)
-- ----------------------------------------------------------------------------
-- "Required" here means: phase 1 (intake) or phase 2 (scope qualifiers)
-- questions always count, and phase 3 (module discovery) questions only
-- count if that module's own qualifier answer is 'Yes' for this client --
-- mirrors the front end's isModuleInScope logic, so progress % reflects
-- only the questions actually in scope for that client, not every
-- question that exists across every module.
CREATE OR REPLACE VIEW insight_client_summary AS
SELECT
    c.client_id,
    c.company_name,
    c.primary_contact,
    c.status                                   AS client_status,
    c.created_by,
    c.created_at,
    c.updated_at,
    in_scope.required_count,
    in_scope.answered_count,
    in_scope.skipped_count,
    CASE WHEN in_scope.required_count = 0 THEN 0
         ELSE ROUND(in_scope.answered_count * 100 / in_scope.required_count)
    END                                         AS pct_complete,
    NVL(pend.pending_count, 0)                  AS pending_change_requests,
    NVL(docs.document_count, 0)                 AS document_count
FROM insight_clients c
CROSS JOIN LATERAL (
    SELECT
        COUNT(*)                                                       AS required_count,
        SUM(CASE WHEN a.client_id IS NOT NULL AND NVL(a.is_skipped,0)=0
                  AND a.answer_value IS NOT NULL THEN 1 ELSE 0 END)     AS answered_count,
        SUM(CASE WHEN NVL(a.is_skipped,0)=1 THEN 1 ELSE 0 END)          AS skipped_count
    FROM insight_questions q
    LEFT JOIN insight_client_answers a
           ON a.client_id = c.client_id
          AND a.question_id = q.question_id
    WHERE q.is_active = 1
      AND q.is_required = 1
      AND (
            q.phase IN (1, 2)
         OR (
              q.phase = 3
              AND EXISTS (
                    SELECT 1
                      FROM insight_client_answers qual
                     WHERE qual.client_id = c.client_id
                       AND qual.question_id = 'QUAL-' || q.module_code
                       -- answer_value is CLOB; Oracle rejects a CLOB used
                       -- directly as a comparison key here (ORA-22848).
                       -- Qualifier answers are always short ("Yes"/"No"),
                       -- so a bounded VARCHAR2 cast is safe and sufficient.
                       AND UPPER(CAST(qual.answer_value AS VARCHAR2(10))) = 'YES'
              )
            )
          )
) in_scope
LEFT JOIN (
    SELECT client_id, COUNT(*) AS pending_count
      FROM insight_answer_change_requests
     WHERE status = 'PENDING'
     GROUP BY client_id
) pend ON pend.client_id = c.client_id
LEFT JOIN (
    SELECT client_id, COUNT(*) AS document_count
      FROM insight_client_documents
     GROUP BY client_id
) docs ON docs.client_id = c.client_id;

COMMENT ON TABLE insight_client_summary IS 'One row per client -- progress %, pending-approval count, document count. Management rollup view: status across clients and consultants without the full per-question detail.';
