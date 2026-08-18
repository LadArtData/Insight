ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- FIX: locked questions (e.g. QUAL-GL) never got a persisted answer.
--
-- insight_client_summary's progress calculation requires a real
-- insight_client_answers row for QUAL-<module> with answer_value = 'YES'
-- before any phase-3 question in that module counts (see INSIGHT_11's
-- in_scope subquery). Nothing wrote that row for locked questions on
-- client creation -- record_answer only inserts what's explicitly called,
-- and insight_clients had no trigger for it. Left as-is, every GL question
-- (28% of the 91-question deck) would silently drop out of every client's
-- completion % the moment the backend gets wired up, since QUAL-GL's
-- locked "Yes" only ever existed in the front end's in-memory state, never
-- in the database insight_client_answers is documented (INSIGHT_07) as the
-- direct read path for.
-- ============================================================================

CREATE OR REPLACE TRIGGER trg_insight_clients_seed_locked
AFTER INSERT ON insight_clients
FOR EACH ROW
BEGIN
    INSERT INTO insight_client_answers (client_id, question_id, answer_value, answered_by, is_skipped)
    SELECT :NEW.client_id, q.question_id, 'Yes', 'SYSTEM', 0
    FROM insight_questions q
    WHERE q.is_locked = 1
      AND q.is_active = 1;
END;
/

-- One-time backfill for any clients created before this trigger existed.
-- MERGE (not INSERT) so this migration is safe to design future backfills
-- around the same pattern -- Flyway itself guarantees this file only runs
-- once per environment, but the MERGE keeps the statement itself honest
-- about what it does if ever re-run by hand.
MERGE INTO insight_client_answers tgt
USING (
    SELECT c.client_id, q.question_id
    FROM insight_clients c
    CROSS JOIN insight_questions q
    WHERE q.is_locked = 1
      AND q.is_active = 1
) src
ON (tgt.client_id = src.client_id AND tgt.question_id = src.question_id)
WHEN NOT MATCHED THEN INSERT (client_id, question_id, answer_value, answered_by, is_skipped)
VALUES (src.client_id, src.question_id, 'Yes', 'SYSTEM', 0);

COMMIT;
