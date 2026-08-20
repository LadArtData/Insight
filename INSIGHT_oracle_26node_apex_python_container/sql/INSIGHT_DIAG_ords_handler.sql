-- ============================================================================
-- DIAGNOSTIC for ORDS-25001 / HTTP 555 on the insight module.
--
-- ORDS-25001 means the handler's PL/SQL failed, but ORDS does not report
-- which Oracle error caused it. This runs the same logic outside ORDS so
-- the database reports the real error.
--
-- Run as ADMIN in Database Actions. Read-only: creates nothing, changes
-- nothing. Paste the whole output back.
-- ============================================================================

SET SERVEROUTPUT ON

-- 1. Does the table every handler depends on actually exist, and can ADMIN
--    see it? A missing table is a COMPILE error inside the handler, which
--    is why the handler's own EXCEPTION block cannot catch it.
DECLARE
  l_cnt NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_cnt
    FROM all_objects
   WHERE owner = 'ITERIA_AI'
     AND object_name = 'INSIGHT_API_CONFIG';
  DBMS_OUTPUT.PUT_LINE('1. ITERIA_AI.INSIGHT_API_CONFIG visible to this user: ' ||
    CASE WHEN l_cnt > 0 THEN 'YES' ELSE 'NO  <-- this alone causes ORDS-25001' END);
END;
/

-- 2. The tables the handlers actually read.
DECLARE
  l_cnt NUMBER;
BEGIN
  FOR r IN (
    SELECT 'INSIGHT_BOARDS' t FROM dual UNION ALL
    SELECT 'INSIGHT_NODES_26'      FROM dual UNION ALL
    SELECT 'INSIGHT_CLIENTS'       FROM dual UNION ALL
    SELECT 'INSIGHT_CLIENT_ANSWERS' FROM dual UNION ALL
    SELECT 'INSIGHT_QUESTIONS'     FROM dual
  ) LOOP
    SELECT COUNT(*) INTO l_cnt
      FROM all_objects
     WHERE owner = 'ITERIA_AI' AND object_name = r.t;
    DBMS_OUTPUT.PUT_LINE('2. ITERIA_AI.' || RPAD(r.t, 24) || ' : ' ||
      CASE WHEN l_cnt > 0 THEN 'ok' ELSE 'MISSING' END);
  END LOOP;
END;
/

-- 3. The package the matrix handlers call.
DECLARE
  l_cnt NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_cnt
    FROM all_objects
   WHERE owner = 'ITERIA_AI'
     AND object_name = 'PKG_INSIGHT_ANSWERS'
     AND status = 'VALID';
  DBMS_OUTPUT.PUT_LINE('3. PKG_INSIGHT_ANSWERS valid: ' ||
    CASE WHEN l_cnt > 0 THEN 'YES' ELSE 'NO' END);
END;
/

-- 4. Run the health handler's body verbatim, with the ORDS binds replaced
--    by literals. Whatever error this raises is the error ORDS is hiding.
DECLARE
  l_api_key VARCHAR2(200);
  l_req_key VARCHAR2(200) := 'vld8x2k9mPqR7sNjT4hW';  -- stands in for :api_key
  l_boards  NUMBER := 0;
  l_nodes   NUMBER := 0;
BEGIN
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.insight_api_config
        WHERE is_active='Y' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;

  DBMS_OUTPUT.PUT_LINE('4. active api_key in insight_api_config: ' ||
    CASE WHEN l_api_key IS NULL THEN '(none - no key required)' ELSE l_api_key END);
  DBMS_OUTPUT.PUT_LINE('   key supplied by the container matches      : ' ||
    CASE WHEN l_api_key IS NULL THEN 'n/a'
         WHEN l_api_key = l_req_key THEN 'YES'
         ELSE 'NO  <-- every request would 403' END);

  SELECT COUNT(*) INTO l_boards FROM iteria_ai.insight_boards;
  SELECT COUNT(*) INTO l_nodes  FROM iteria_ai.insight_nodes_26;
  DBMS_OUTPUT.PUT_LINE('   boards=' || l_boards || ' nodes=' || l_nodes);
  DBMS_OUTPUT.PUT_LINE('4. health handler body ran clean.');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('4. HEALTH HANDLER FAILED: ' || SQLERRM);
END;
/

-- 5. What ORDS thinks is published right now.
SELECT m.name        AS module_name,
       m.uri_prefix,
       m.status,
       COUNT(DISTINCT t.id) AS templates,
       COUNT(h.id)          AS handlers
  FROM user_ords_modules m
  LEFT JOIN user_ords_templates t ON t.module_id = m.id
  LEFT JOIN user_ords_handlers  h ON h.template_id = t.id
 WHERE LOWER(m.name) LIKE '%insight%'
 GROUP BY m.name, m.uri_prefix, m.status
 ORDER BY m.name;
