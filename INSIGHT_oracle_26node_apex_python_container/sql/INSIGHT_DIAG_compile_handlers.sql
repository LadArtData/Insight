-- ============================================================================
-- Compiles each ORDS handler body as a real procedure so Oracle reports the
-- exact PLS- error and line number. ORDS only ever says ORDS-25001.
--
-- Run as ADMIN in Database Actions with Run Script (F5).
-- Creates seven INSIGHT_DIAG_* procedures, then lists their errors and
-- drops them. Touches no INSIGHT data.
--
-- Paste back everything the final query returns. No rows = all seven
-- compile cleanly and the fault is elsewhere.
-- ============================================================================
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;

CREATE OR REPLACE PROCEDURE insight_diag_health_get (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key VARCHAR2(200);
  l_req_key VARCHAR2(200) := p_api_key;
  l_boards  NUMBER := 0;
  l_nodes   NUMBER := 0;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  SELECT COUNT(*) INTO l_boards FROM iteria_ai.insight_boards;
  SELECT COUNT(*) INTO l_nodes  FROM iteria_ai.insight_nodes_26;

  HTP.P('{"ok":true,"status":"ACTIVE","board_count":' || l_boards
       || ',"node_count":'  || l_nodes || '}' );
EXCEPTION WHEN OTHERS THEN
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/

CREATE OR REPLACE PROCEDURE insight_diag_matrix_get (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key  VARCHAR2(200);
  l_req_key  VARCHAR2(200) := p_api_key;
  l_board_id NUMBER := p_board_id;
  l_nodes    CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block's own EXCEPTION clause can never
  -- catch, so ORDS reports only ORDS-25001 / HTTP 555. Write the CLOB out
  -- in chunks instead; these responses can exceed 32767 characters.
  PROCEDURE emit(p_clob IN CLOB) IS
    l_len PLS_INTEGER;
    l_off PLS_INTEGER := 1;
    l_amt PLS_INTEGER := 8000;
  BEGIN
    IF p_clob IS NULL THEN RETURN; END IF;
    l_len := DBMS_LOB.GETLENGTH(p_clob);
    WHILE l_off <= l_len LOOP
      HTP.PRN(DBMS_LOB.SUBSTR(p_clob, l_amt, l_off));
      l_off := l_off + l_amt;
    END LOOP;
  END emit;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  l_nodes := iteria_ai.pkg_insight_board_engine.get_matrix_state_json(p_board_id => l_board_id);

  HTP.PRN('{"ok":true,"board_id":' || l_board_id || ',"nodes":');
  IF l_nodes IS NULL THEN HTP.PRN('[]'); ELSE emit(l_nodes); END IF;
  HTP.PRN('}');
EXCEPTION WHEN OTHERS THEN
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/

CREATE OR REPLACE PROCEDURE insight_diag_nodes_post (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key    VARCHAR2(200);
  l_req_key    VARCHAR2(200) := p_api_key;
  l_node_id    NUMBER := p_node_id;
  l_body       CLOB   := p_body_text;
  l_board_id   NUMBER;
  l_event_code VARCHAR2(50);
  l_payload    CLOB;
  l_out        CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block's own EXCEPTION clause can never
  -- catch, so ORDS reports only ORDS-25001 / HTTP 555. Write the CLOB out
  -- in chunks instead; these responses can exceed 32767 characters.
  PROCEDURE emit(p_clob IN CLOB) IS
    l_len PLS_INTEGER;
    l_off PLS_INTEGER := 1;
    l_amt PLS_INTEGER := 8000;
  BEGIN
    IF p_clob IS NULL THEN RETURN; END IF;
    l_len := DBMS_LOB.GETLENGTH(p_clob);
    WHILE l_off <= l_len LOOP
      HTP.PRN(DBMS_LOB.SUBSTR(p_clob, l_amt, l_off));
      l_off := l_off + l_amt;
    END LOOP;
  END emit;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  IF l_node_id NOT BETWEEN 1 AND 26 THEN
    p_status := 400; HTP.P('{"ok":false,"error":"node_id must be between 1 and 26"}'); RETURN;
  END IF;

  l_board_id   := NVL(JSON_VALUE(l_body, '$.board_id' RETURNING NUMBER), 1);
  l_event_code := NVL(JSON_VALUE(l_body, '$.event_code'), 'ON_USER_TRIGGER');
  l_payload    := JSON_QUERY(l_body, '$.payload');
  IF l_payload IS NULL THEN l_payload := '{}'; END IF;

  BEGIN
    iteria_ai.pkg_insight_board_engine.process_edl_event(
      p_board_id     => l_board_id,
      p_node_id      => l_node_id,
      p_event_code   => l_event_code,
      p_payload_json => l_payload,
      x_out_response => l_out
    );
  EXCEPTION WHEN NO_DATA_FOUND THEN
    p_status := 404;
    HTP.P('{"ok":false,"error":"node ' || l_node_id || ' not found on board ' || l_board_id || '"}');
    RETURN;
  END;

  HTP.PRN('{"ok":true,"board_id":' || l_board_id
        || ',"node_id":'  || l_node_id
        || ',"nodes":');
  IF l_out IS NULL THEN HTP.PRN('[]'); ELSE emit(l_out); END IF;
  HTP.PRN('}');
EXCEPTION WHEN OTHERS THEN
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/

CREATE OR REPLACE PROCEDURE insight_diag_clients_get (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key VARCHAR2(200);
  l_req_key VARCHAR2(200) := p_api_key;
  l_out     CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block's own EXCEPTION clause can never
  -- catch, so ORDS reports only ORDS-25001 / HTTP 555. Write the CLOB out
  -- in chunks instead; JSON responses here can exceed 32767 characters.
  PROCEDURE emit(p_clob IN CLOB) IS
    l_len PLS_INTEGER;
    l_off PLS_INTEGER := 1;
    l_amt PLS_INTEGER := 8000;
  BEGIN
    IF p_clob IS NULL THEN RETURN; END IF;
    l_len := DBMS_LOB.GETLENGTH(p_clob);
    WHILE l_off <= l_len LOOP
      HTP.PRN(DBMS_LOB.SUBSTR(p_clob, l_amt, l_off));
      l_off := l_off + l_amt;
    END LOOP;
  END emit;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  SELECT JSON_ARRAYAGG(
           JSON_OBJECT(
             'id'          VALUE client_id,
             'companyName' VALUE company_name,
             'updatedAt'   VALUE TO_CHAR(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
             RETURNING CLOB)
           ORDER BY updated_at DESC RETURNING CLOB)
    INTO l_out
    FROM iteria_ai.insight_clients
   WHERE status = 'ACTIVE';

  IF l_out IS NULL THEN HTP.P('[]'); ELSE emit(l_out); END IF;
EXCEPTION WHEN OTHERS THEN
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/

CREATE OR REPLACE PROCEDURE insight_diag_client_get (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := p_api_key;
  l_client_id VARCHAR2(40)  := p_client_id;
  l_name      VARCHAR2(300);
  l_created   VARCHAR2(30);
  l_updated   VARCHAR2(30);
  l_answers   CLOB;
  l_skipped   CLOB;
  l_out       CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block's own EXCEPTION clause can never
  -- catch, so ORDS reports only ORDS-25001 / HTTP 555. Write the CLOB out
  -- in chunks instead; JSON responses here can exceed 32767 characters.
  PROCEDURE emit(p_clob IN CLOB) IS
    l_len PLS_INTEGER;
    l_off PLS_INTEGER := 1;
    l_amt PLS_INTEGER := 8000;
  BEGIN
    IF p_clob IS NULL THEN RETURN; END IF;
    l_len := DBMS_LOB.GETLENGTH(p_clob);
    WHILE l_off <= l_len LOOP
      HTP.PRN(DBMS_LOB.SUBSTR(p_clob, l_amt, l_off));
      l_off := l_off + l_amt;
    END LOOP;
  END emit;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  BEGIN
    SELECT company_name,
           TO_CHAR(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           TO_CHAR(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      INTO l_name, l_created, l_updated
      FROM iteria_ai.insight_clients
     WHERE client_id = l_client_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    p_status := 404;
    HTP.P('{"ok":false,"error":"client not found"}');
    RETURN;
  END;

  SELECT JSON_OBJECTAGG(KEY question_id VALUE answer_value RETURNING CLOB)
    INTO l_answers
    FROM iteria_ai.insight_client_answers
   WHERE client_id = l_client_id;

  SELECT JSON_OBJECTAGG(KEY question_id VALUE 'true' FORMAT JSON RETURNING CLOB)
    INTO l_skipped
    FROM iteria_ai.insight_client_answers
   WHERE client_id = l_client_id
     AND is_skipped = 1;

  -- Built by JSON_OBJECT rather than string concatenation: it escapes the
  -- values, and it avoids JSON_SCALAR, which does not exist before 21c.
  SELECT JSON_OBJECT(
           'id'          VALUE l_client_id,
           'companyName' VALUE l_name,
           'answers'     VALUE NVL(l_answers, TO_CLOB('{}')) FORMAT JSON,
           'skipped'     VALUE NVL(l_skipped, TO_CLOB('{}')) FORMAT JSON,
           'createdAt'   VALUE l_created,
           'updatedAt'   VALUE l_updated
           RETURNING CLOB)
    INTO l_out
    FROM dual;

  emit(l_out);
EXCEPTION WHEN OTHERS THEN
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/

CREATE OR REPLACE PROCEDURE insight_diag_client_put (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key     VARCHAR2(200);
  l_req_key     VARCHAR2(200) := p_api_key;
  l_client_id   VARCHAR2(40)  := p_client_id;
  l_body        CLOB          := p_body_text;
  l_doc         JSON_OBJECT_T;
  l_answers     JSON_OBJECT_T;
  l_skipped     JSON_OBJECT_T;
  l_keys        JSON_KEY_LIST;
  l_qid         VARCHAR2(20);
  l_val         CLOB;
  l_is_skipped  NUMBER;
  l_name        VARCHAR2(300);
  l_actor       VARCHAR2(100);
  l_existing    CLOB;
  l_exist_skip  NUMBER;
  l_found       NUMBER;
  l_status      VARCHAR2(30);
  l_written     NUMBER := 0;
  l_pending     NUMBER := 0;
  l_unknown     NUMBER := 0;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  IF l_body IS NULL OR DBMS_LOB.GETLENGTH(l_body) = 0 THEN
    p_status := 400; HTP.P('{"ok":false,"error":"request body is required"}'); RETURN;
  END IF;

  BEGIN
    l_doc := JSON_OBJECT_T.parse(l_body);
  EXCEPTION WHEN OTHERS THEN
    p_status := 400; HTP.P('{"ok":false,"error":"request body is not valid JSON"}'); RETURN;
  END;

  l_name  := SUBSTR(NVL(l_doc.get_String('companyName'), 'Unnamed client'), 1, 300);
  l_actor := SUBSTR(NVL(l_doc.get_String('actor'), 'insight-app'), 1, 100);

  MERGE INTO iteria_ai.insight_clients t
  USING (SELECT l_client_id AS client_id FROM dual) s
     ON (t.client_id = s.client_id)
  WHEN MATCHED THEN UPDATE SET t.company_name = l_name
  WHEN NOT MATCHED THEN INSERT (client_id, company_name, created_by)
                        VALUES (l_client_id, l_name, l_actor);

  IF l_doc.has('answers') THEN
    l_answers := l_doc.get_Object('answers');
    IF l_doc.has('skipped') THEN
      l_skipped := l_doc.get_Object('skipped');
    ELSE
      l_skipped := JSON_OBJECT_T.parse('{}');
    END IF;

    l_keys := l_answers.get_keys;
    FOR i IN 1 .. l_keys.COUNT LOOP
      l_qid := SUBSTR(l_keys(i), 1, 20);
      l_val := l_answers.get_String(l_qid);
      l_is_skipped := CASE WHEN l_skipped.has(l_qid) THEN 1 ELSE 0 END;

      SELECT COUNT(*) INTO l_found
        FROM iteria_ai.insight_questions
       WHERE question_id = l_qid;

      IF l_found = 0 THEN
        l_unknown := l_unknown + 1;
      ELSE
        BEGIN
          SELECT answer_value, is_skipped
            INTO l_existing, l_exist_skip
            FROM iteria_ai.insight_client_answers
           WHERE client_id = l_client_id AND question_id = l_qid;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          l_existing := NULL; l_exist_skip := -1;
        END;

        IF l_val IS NULL AND l_exist_skip = -1 AND l_is_skipped = 0 THEN
          NULL;
        ELSIF NVL(TO_CHAR(SUBSTR(l_existing,1,4000)),'~~') = NVL(TO_CHAR(SUBSTR(l_val,1,4000)),'~~')
              AND l_exist_skip = l_is_skipped THEN
          NULL;
        ELSE
          iteria_ai.pkg_insight_answers.record_answer(
            p_client_id   => l_client_id,
            p_question_id => l_qid,
            p_value       => l_val,
            p_actor       => l_actor,
            p_is_skipped  => l_is_skipped,
            x_out_status  => l_status);
          IF l_status = 'PENDING_APPROVAL' THEN
            l_pending := l_pending + 1;
          ELSE
            l_written := l_written + 1;
          END IF;
        END IF;
      END IF;
    END LOOP;
  END IF;

  UPDATE iteria_ai.insight_clients
     SET updated_at = CURRENT_TIMESTAMP
   WHERE client_id = l_client_id;

  COMMIT;

  HTP.P('{"ok":true,"saved":'    || l_written
       || ',"pendingApproval":' || l_pending
       || ',"unknownQuestions":' || l_unknown || '}');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/

CREATE OR REPLACE PROCEDURE insight_diag_client_delete (
    p_api_key   IN  VARCHAR2 DEFAULT NULL,
    p_client_id IN  VARCHAR2 DEFAULT NULL,
    p_board_id  IN  NUMBER   DEFAULT NULL,
    p_node_id   IN  NUMBER   DEFAULT NULL,
    p_body_text IN  CLOB     DEFAULT NULL,
    p_status    OUT NUMBER
) AS
l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := p_api_key;
  l_client_id VARCHAR2(40)  := p_client_id;
  l_resp      VARCHAR2(4000);
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block's own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''Y'' AND ROWNUM = 1'
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,'__none__') != l_api_key THEN
    p_status := 403; HTP.P('{"ok":false,"error":"unauthorized"}'); RETURN;
  END IF;

  UPDATE iteria_ai.insight_clients
     SET status = 'ARCHIVED'
   WHERE client_id = l_client_id;

  IF SQL%ROWCOUNT = 0 THEN
    p_status := 404; HTP.P('{"ok":false,"error":"client not found"}'); RETURN;
  END IF;

  COMMIT;
  SELECT JSON_OBJECT('ok' VALUE 'true' FORMAT JSON, 'archived' VALUE l_client_id)
    INTO l_resp FROM dual;
  HTP.P(l_resp);
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  p_status := 500;
  HTP.P('{"ok":false,"error":"' || REPLACE(SUBSTR(SQLERRM,1,300),'"','`') || '"}');
END;
/


-- The answer:
SELECT name, line, position, text
  FROM user_errors
 WHERE name LIKE 'INSIGHT_DIAG_%'
 ORDER BY name, sequence;

BEGIN
  FOR r IN (SELECT object_name FROM user_objects
             WHERE object_name LIKE 'INSIGHT_DIAG\_%' ESCAPE '\'
               AND object_type = 'PROCEDURE') LOOP
    EXECUTE IMMEDIATE 'DROP PROCEDURE ' || r.object_name;
  END LOOP;
END;
/
