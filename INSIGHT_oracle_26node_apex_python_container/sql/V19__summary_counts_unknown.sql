ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- insight_client_summary: count "not known yet" as answered
--
-- V16 added is_unknown, and the front end treats it as satisfying a
-- required question -- a clear gap beats an invented value. The summary
-- view still required answer_value IS NOT NULL, so an unknown answer read
-- as incomplete and the roster progress bar under-reported. A client with
-- values that genuinely cannot be settled during a sales call could never
-- reach 100%.
--
-- Also exposes unknown_count alongside skipped_count, so the two remain
-- distinguishable downstream: skipped is still outstanding, unknown is
-- settled.
--
-- Replaces only insight_client_summary. insight_client_sheet is unchanged.
-- ============================================================================

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
    in_scope.unknown_count,
    CASE WHEN in_scope.required_count = 0 THEN 0
         ELSE ROUND(in_scope.answered_count * 100 / in_scope.required_count)
    END                                         AS pct_complete,
    NVL(pend.pending_count, 0)                  AS pending_change_requests,
    NVL(docs.document_count, 0)                 AS document_count
FROM insight_clients c
CROSS JOIN LATERAL (
    SELECT
        COUNT(*)                                                       AS required_count,
        -- "Not known yet" counts as answered. It is a deliberate outcome,
        -- not an omission, and some values genuinely cannot be settled
        -- during a sales conversation -- so excluding it would mean those
        -- clients could never reach 100% no matter what a rep did.
        SUM(CASE WHEN a.client_id IS NOT NULL AND NVL(a.is_skipped,0)=0
                  AND (a.answer_value IS NOT NULL OR NVL(a.is_unknown,0)=1)
                 THEN 1 ELSE 0 END)                                     AS answered_count,
        SUM(CASE WHEN NVL(a.is_skipped,0)=1 THEN 1 ELSE 0 END)          AS skipped_count,
        SUM(CASE WHEN NVL(a.is_unknown,0)=1 THEN 1 ELSE 0 END)          AS unknown_count
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
