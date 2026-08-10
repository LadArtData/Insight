SET DEFINE OFF
-- ============================================================================
-- OPTIONAL CLEANUP: drop the old copies created under ADMIN
-- Before the object rename + ITERIA_AI move, INSIGHT_01/02 were run while
-- connected as ADMIN, creating AI_BOARDS, AI_NODES_26, AI_BOARD_ACTIVITY_LOG,
-- and AI_EDL_RULES there. Now that INSIGHT_01-05 target ITERIA_AI with the
-- renamed INSIGHT_* objects, those ADMIN-schema copies are orphaned
-- duplicates. Run this ONCE, connected as ADMIN, to remove them.
--
-- Safe to run even if some/all of these were never created, or already
-- dropped -- each DROP is wrapped so a missing object is silently skipped.
-- ============================================================================

DECLARE
  PROCEDURE drop_if_exists(p_sql IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE NOT IN (-942, -4043) THEN  -- ORA-00942 table/view, ORA-04043 does not exist
        RAISE;
      END IF;
  END;
BEGIN
  drop_if_exists('DROP TABLE ai_nodes_26 CASCADE CONSTRAINTS PURGE');
  drop_if_exists('DROP TABLE ai_board_activity_log CASCADE CONSTRAINTS PURGE');
  drop_if_exists('DROP TABLE ai_edl_rules CASCADE CONSTRAINTS PURGE');
  drop_if_exists('DROP TABLE ai_boards CASCADE CONSTRAINTS PURGE');
  drop_if_exists('DROP PACKAGE pkg_ai_board_engine');
END;
/
