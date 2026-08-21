SET DEFINE OFF
-- ============================================================================
-- ORDS REST MODULE: insight
--
-- One module for the whole product. Everything INSIGHT exposes over REST
-- lives here, under a single base path:
--
--   GET    /ords/admin/insight/health                 board/node counts
--   GET    /ords/admin/insight/matrix/:board_id       26-node matrix state
--   POST   /ords/admin/insight/nodes/:node_id/trigger fire an EDL event
--   GET    /ords/admin/insight/clients                active client list
--   GET    /ords/admin/insight/clients/:client_id     one client + answers
--   PUT    /ords/admin/insight/clients/:client_id     upsert client + answers
--   DELETE /ords/admin/insight/clients/:client_id     archive a client
--   GET    /ords/admin/insight/clients/:id/notes      additional information
--   POST   /ords/admin/insight/clients/:id/notes      add a note
--   PUT    /ords/admin/insight/clients/:id/notes      edit or archive a note
--
-- This replaces the earlier insight-hooks and insight-questionnaire
-- modules, which split one product across two base paths and two entries in
-- the ORDS catalog for no benefit. The script drops both if present, so
-- running it on a database that has them is the migration -- no manual
-- cleanup needed. The handler bodies are unchanged.
--
-- Registered under ADMIN (the only login on the target database) and
-- reaches into ITERIA_AI.
--
-- RUN ORDER MATTERS. Apply V1-V20 first, and V17/V18 in particular: the
-- PUT handler below calls pkg_insight_answers.record_answer with p_source
-- and p_is_unknown, which do not exist until V17 redefines the spec.
-- Installing this module against an older package makes every PUT fail at
-- request time with ORDS-25001 / HTTP 555 -- an opaque error, because the
-- handler is an anonymous block whose compile failure has nowhere to
-- surface. Both parameters are defaulted, so the reverse order is safe:
-- an older module keeps working against the newer package.
--
-- V20 matters for the notes endpoints, which read and write
-- insight_client_notes directly. Without it those three handlers fail the
-- same opaque way -- but only those three: each handler compiles on its own
-- at request time, so the rest of the module is unaffected. The notes block
-- inside GET clients/:client_id is deliberately dynamic for that reason:
-- loading a client must not depend on a table that only the notes feature
-- needs.
--
-- This is ORDS metadata, not a schema
-- migration, so it is deliberately not Flyway-tracked -- run it by hand,
-- connected as ADMIN.
-- ============================================================================

BEGIN

  -- Remove the superseded split modules. Wrapped individually so a database
  -- that never had them (or has only one) still runs this cleanly.
  BEGIN
    ORDS.DELETE_MODULE(p_module_name => 'insight-hooks');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    ORDS.DELETE_MODULE(p_module_name => 'insight-questionnaire');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  ORDS.DEFINE_MODULE(
      p_module_name    => 'insight',
      p_base_path      => '/insight/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'INSIGHT -- 26-node EDL matrix and discovery questionnaire');

  --------------------------------------------------------------------------
  -- 26-node EDL matrix
  --------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight',
      p_pattern        => 'health',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Sanity ping -- board/node counts');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'health',
      p_method         => 'GET',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => NULL,
      p_comments       => NULL,
      p_source         =>
'DECLARE
  l_api_key VARCHAR2(200);
  l_req_key VARCHAR2(200) := :api_key;
  l_boards  NUMBER := 0;
  l_nodes   NUMBER := 0;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  SELECT COUNT(*) INTO l_boards FROM iteria_ai.insight_boards;
  SELECT COUNT(*) INTO l_nodes  FROM iteria_ai.insight_nodes_26;

  HTP.P(''{"ok":true,"status":"ACTIVE","board_count":'' || l_boards
       || '',"node_count":''  || l_nodes || ''}'' );
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- GET /insight/matrix/:board_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight',
      p_pattern        => 'matrix/:board_id',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Full current node state for one board');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'matrix/:board_id',
      p_method         => 'GET',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => NULL,
      p_comments       => 'Calls iteria_ai.pkg_insight_board_engine.get_matrix_state_json',
      p_source         =>
'DECLARE
  l_api_key  VARCHAR2(200);
  l_req_key  VARCHAR2(200) := :api_key;
  l_board_id NUMBER := :board_id;
  l_nodes    CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block''s own EXCEPTION clause can never
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
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  l_nodes := iteria_ai.pkg_insight_board_engine.get_matrix_state_json(p_board_id => l_board_id);

  HTP.PRN(''{"ok":true,"board_id":'' || l_board_id || '',"nodes":'');
  IF l_nodes IS NULL THEN HTP.PRN(''[]''); ELSE emit(l_nodes); END IF;
  HTP.PRN(''}'');
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- POST /insight/nodes/:node_id/trigger
  -- Body: {"board_id":1,"event_code":"ON_USER_TRIGGER","payload":{...}}
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight',
      p_pattern        => 'nodes/:node_id/trigger',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Fires the 2-way writeback for one node');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'nodes/:node_id/trigger',
      p_method         => 'POST',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => 'application/json',
      p_comments       => 'Calls iteria_ai.pkg_insight_board_engine.process_edl_event',
      p_source         =>
'DECLARE
  l_api_key    VARCHAR2(200);
  l_req_key    VARCHAR2(200) := :api_key;
  l_node_id    NUMBER := :node_id;
  l_body       CLOB   := :body_text;
  l_board_id   NUMBER;
  l_event_code VARCHAR2(50);
  l_payload    CLOB;
  l_out        CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block''s own EXCEPTION clause can never
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
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  IF l_node_id NOT BETWEEN 1 AND 26 THEN
    :status := 400; HTP.P(''{"ok":false,"error":"node_id must be between 1 and 26"}''); RETURN;
  END IF;

  l_board_id   := NVL(JSON_VALUE(l_body, ''$.board_id'' RETURNING NUMBER), 1);
  l_event_code := NVL(JSON_VALUE(l_body, ''$.event_code''), ''ON_USER_TRIGGER'');
  l_payload    := JSON_QUERY(l_body, ''$.payload'');
  IF l_payload IS NULL THEN l_payload := ''{}''; END IF;

  BEGIN
    iteria_ai.pkg_insight_board_engine.process_edl_event(
      p_board_id     => l_board_id,
      p_node_id      => l_node_id,
      p_event_code   => l_event_code,
      p_payload_json => l_payload,
      x_out_response => l_out
    );
  EXCEPTION WHEN NO_DATA_FOUND THEN
    :status := 404;
    HTP.P(''{"ok":false,"error":"node '' || l_node_id || '' not found on board '' || l_board_id || ''"}'');
    RETURN;
  END;

  HTP.PRN(''{"ok":true,"board_id":'' || l_board_id
        || '',"node_id":''  || l_node_id
        || '',"nodes":'');
  IF l_out IS NULL THEN HTP.PRN(''[]''); ELSE emit(l_out); END IF;
  HTP.PRN(''}'');
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  --------------------------------------------------------------------------
  -- Discovery questionnaire
  --------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight',
      p_pattern        => 'clients',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'List of active client records');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients',
      p_method         => 'GET',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => NULL,
      p_comments       => NULL,
      p_source         =>
'DECLARE
  l_api_key VARCHAR2(200);
  l_req_key VARCHAR2(200) := :api_key;
  l_out     CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block''s own EXCEPTION clause can never
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
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  -- Reads insight_client_summary (V11), not insight_clients, so each row
  -- carries a real completion percentage. The roster used to be built in
  -- the browser and kept its own percent; once the list moved server-side
  -- that value had nowhere to come from and every progress bar rendered
  -- empty. pct_complete counts only questions actually in scope for the
  -- client, so declining a module raises the percentage rather than
  -- capping it below 100.
  -- Joined to insight_clients only for primary_contact: the roster row has
  -- always rendered it, but the summary view does not carry it, so it read
  -- as blank on every client. The view is Flyway-applied and not editable
  -- in place, and a join here is cheaper than a migration that exists to
  -- add one column to a projection.
  SELECT JSON_ARRAYAGG(
           JSON_OBJECT(
             ''id''          VALUE s.client_id,
             ''companyName'' VALUE s.company_name,
             ''primaryContact'' VALUE c.primary_contact,
             ''updatedAt''   VALUE TO_CHAR(s.updated_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"''),
             ''percent''     VALUE s.pct_complete,
             ''pendingApproval'' VALUE s.pending_change_requests
             RETURNING CLOB)
           ORDER BY s.updated_at DESC RETURNING CLOB)
    INTO l_out
    FROM iteria_ai.insight_client_summary s
    JOIN iteria_ai.insight_clients c
      ON c.client_id = s.client_id
   WHERE s.client_status = ''ACTIVE'';

  IF l_out IS NULL THEN HTP.P(''[]''); ELSE emit(l_out); END IF;
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- GET /insight/clients/:client_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'One client record with all answers');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id',
      p_method         => 'GET',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => NULL,
      p_comments       => 'Reassembles the normalized rows into the front end record shape',
      p_source         =>
'DECLARE
  l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := :api_key;
  l_client_id VARCHAR2(40)  := :client_id;
  l_name      VARCHAR2(300);
  l_contact   VARCHAR2(300);
  l_notes     CLOB;
  l_created   VARCHAR2(30);
  l_updated   VARCHAR2(30);
  l_answers   CLOB;
  l_skipped   CLOB;
  l_unknownm  CLOB;
  l_out       CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 --
  -- a COMPILE error, which the block''s own EXCEPTION clause can never
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
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  BEGIN
    SELECT company_name,
           primary_contact,
           TO_CHAR(created_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"''),
           TO_CHAR(updated_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"'')
      INTO l_name, l_contact, l_created, l_updated
      FROM iteria_ai.insight_clients
     WHERE client_id = l_client_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    :status := 404;
    HTP.P(''{"ok":false,"error":"client not found"}'');
    RETURN;
  END;

  SELECT JSON_OBJECTAGG(KEY question_id VALUE answer_value RETURNING CLOB)
    INTO l_answers
    FROM iteria_ai.insight_client_answers
   WHERE client_id = l_client_id;

  SELECT JSON_OBJECTAGG(KEY question_id VALUE ''true'' FORMAT JSON RETURNING CLOB)
    INTO l_skipped
    FROM iteria_ai.insight_client_answers
   WHERE client_id = l_client_id
     AND is_skipped = 1;

  SELECT JSON_OBJECTAGG(KEY question_id VALUE ''true'' FORMAT JSON RETURNING CLOB)
    INTO l_unknownm
    FROM iteria_ai.insight_client_answers
   WHERE client_id = l_client_id
     AND is_unknown = 1;

  -- Notes ride along so the client screen loads in one request. Dynamic on
  -- purpose: a static reference would make this whole handler fail to
  -- compile on a database without V20, and reading a client''s answers must
  -- not depend on a table only the notes feature needs. Absent table means
  -- no notes, not a dead endpoint.
  BEGIN
    EXECUTE IMMEDIATE
      ''SELECT JSON_ARRAYAGG(
                 JSON_OBJECT(
                   ''''id''''        VALUE note_id,
                   ''''text''''      VALUE note_text,
                   ''''source''''    VALUE note_source,
                   ''''createdBy'''' VALUE created_by,
                   ''''createdAt'''' VALUE TO_CHAR(created_at AT TIME ZONE ''''UTC'''', ''''YYYY-MM-DD"T"HH24:MI:SS"Z"''''),
                   ''''updatedAt'''' VALUE TO_CHAR(updated_at AT TIME ZONE ''''UTC'''', ''''YYYY-MM-DD"T"HH24:MI:SS"Z"'''')
                   RETURNING CLOB)
                 ORDER BY created_at DESC
                 RETURNING CLOB)
         FROM iteria_ai.insight_client_notes
        WHERE client_id = :1
          AND is_archived = 0''
      INTO l_notes USING l_client_id;
  EXCEPTION WHEN OTHERS THEN l_notes := NULL; END;

  -- Built by JSON_OBJECT rather than string concatenation: it escapes the
  -- values, and it avoids JSON_SCALAR, which does not exist before 21c.
  SELECT JSON_OBJECT(
           ''id''             VALUE l_client_id,
           ''companyName''    VALUE l_name,
           ''primaryContact'' VALUE l_contact,
           ''notes''          VALUE NVL(l_notes, TO_CLOB(''[]'')) FORMAT JSON,
           ''answers''     VALUE NVL(l_answers, TO_CLOB(''{}'')) FORMAT JSON,
           ''skipped''     VALUE NVL(l_skipped, TO_CLOB(''{}'')) FORMAT JSON,
           ''unknown''     VALUE NVL(l_unknownm, TO_CLOB(''{}'')) FORMAT JSON,
           ''createdAt''   VALUE l_created,
           ''updatedAt''   VALUE l_updated
           RETURNING CLOB)
    INTO l_out
    FROM dual;

  emit(l_out);
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- PUT /insight/clients/:client_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id',
      p_method         => 'PUT',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => 'application/json',
      p_comments       => 'Upserts the client and only those answers whose value changed',
      p_source         =>
'DECLARE
  l_api_key     VARCHAR2(200);
  l_req_key     VARCHAR2(200) := :api_key;
  l_client_id   VARCHAR2(40)  := :client_id;
  l_body        CLOB          := :body_text;
  l_doc         JSON_OBJECT_T;
  l_answers     JSON_OBJECT_T;
  l_skipped     JSON_OBJECT_T;
  l_unknownmap  JSON_OBJECT_T;
  l_is_unknown  NUMBER;
  l_source      VARCHAR2(20);
  l_keys        JSON_KEY_LIST;
  l_qid         VARCHAR2(20);
  l_val         CLOB;
  l_is_skipped  NUMBER;
  l_name        VARCHAR2(300);
  l_contact     VARCHAR2(300);
  l_has_name    NUMBER;
  l_has_contact NUMBER;
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
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  IF l_body IS NULL OR DBMS_LOB.GETLENGTH(l_body) = 0 THEN
    :status := 400; HTP.P(''{"ok":false,"error":"request body is required"}''); RETURN;
  END IF;

  BEGIN
    l_doc := JSON_OBJECT_T.parse(l_body);
  EXCEPTION WHEN OTHERS THEN
    :status := 400; HTP.P(''{"ok":false,"error":"request body is not valid JSON"}''); RETURN;
  END;

  -- Presence, not value, decides whether a field is touched. A caller
  -- saving only answers must not blank the company profile, and a caller
  -- editing only the profile must not have to resend every answer. Sending
  -- "" is therefore a deliberate clear (Oracle stores it as NULL), while
  -- omitting the key leaves what is there alone.
  l_has_name    := CASE WHEN l_doc.has(''companyName'')    THEN 1 ELSE 0 END;
  l_has_contact := CASE WHEN l_doc.has(''primaryContact'') THEN 1 ELSE 0 END;

  l_name    := SUBSTR(NVL(l_doc.get_String(''companyName''), ''Unnamed client''), 1, 300);
  l_contact := SUBSTR(l_doc.get_String(''primaryContact''), 1, 300);
  l_actor   := SUBSTR(NVL(l_doc.get_String(''actor''), ''insight-app''), 1, 100);

  MERGE INTO iteria_ai.insight_clients t
  USING (SELECT l_client_id AS client_id FROM dual) s
     ON (t.client_id = s.client_id)
  WHEN MATCHED THEN UPDATE SET
       t.company_name    = CASE WHEN l_has_name    = 1 THEN l_name    ELSE t.company_name    END,
       t.primary_contact = CASE WHEN l_has_contact = 1 THEN l_contact ELSE t.primary_contact END
  WHEN NOT MATCHED THEN INSERT (client_id, company_name, primary_contact, created_by)
                        VALUES (l_client_id, l_name, l_contact, l_actor);

  IF l_doc.has(''answers'') THEN
    l_answers := l_doc.get_Object(''answers'');
    IF l_doc.has(''skipped'') THEN
      l_skipped := l_doc.get_Object(''skipped'');
    ELSE
      l_skipped := JSON_OBJECT_T.parse(''{}'');
    END IF;
    -- "Not known yet" travels as its own map, parallel to skipped. They mean
    -- different things: skipped is come-back-to-it, unknown is settled as
    -- not yet knowable, and only the first should keep being chased.
    IF l_doc.has(''unknown'') THEN
      l_unknownmap := l_doc.get_Object(''unknown'');
    ELSE
      l_unknownmap := JSON_OBJECT_T.parse(''{}'');
    END IF;
    -- Anything arriving through this endpoint is sales intake unless the
    -- caller says otherwise; provisional either way, since confirming is a
    -- separate act.
    l_source := SUBSTR(NVL(l_doc.get_String(''source''), ''SALES_INTAKE''), 1, 20);

    l_keys := l_answers.get_keys;
    FOR i IN 1 .. l_keys.COUNT LOOP
      l_qid := SUBSTR(l_keys(i), 1, 20);
      l_val := l_answers.get_String(l_qid);
      l_is_skipped := CASE WHEN l_skipped.has(l_qid) THEN 1 ELSE 0 END;
      l_is_unknown := CASE WHEN l_unknownmap.has(l_qid) THEN 1 ELSE 0 END;

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
        ELSIF NVL(TO_CHAR(SUBSTR(l_existing,1,4000)),''~~'') = NVL(TO_CHAR(SUBSTR(l_val,1,4000)),''~~'')
              AND l_exist_skip = l_is_skipped THEN
          NULL;
        ELSE
          iteria_ai.pkg_insight_answers.record_answer(
            p_client_id   => l_client_id,
            p_question_id => l_qid,
            p_value       => l_val,
            p_actor       => l_actor,
            p_is_skipped  => l_is_skipped,
            p_source      => l_source,
            p_is_unknown  => l_is_unknown,
            x_out_status  => l_status);
          IF l_status = ''PENDING_APPROVAL'' THEN
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

  HTP.P(''{"ok":true,"saved":''    || l_written
       || '',"pendingApproval":'' || l_pending
       || '',"unknownQuestions":'' || l_unknown || ''}'');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- DELETE /insight/clients/:client_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id',
      p_method         => 'DELETE',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => NULL,
      p_comments       => 'Archives rather than deletes -- answer history is kept',
      p_source         =>
'DECLARE
  l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := :api_key;
  l_client_id VARCHAR2(40)  := :client_id;
  l_resp      VARCHAR2(4000);
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  UPDATE iteria_ai.insight_clients
     SET status = ''ARCHIVED''
   WHERE client_id = l_client_id;

  IF SQL%ROWCOUNT = 0 THEN
    :status := 404; HTP.P(''{"ok":false,"error":"client not found"}''); RETURN;
  END IF;

  COMMIT;
  SELECT JSON_OBJECT(''ok'' VALUE ''true'' FORMAT JSON, ''archived'' VALUE l_client_id)
    INTO l_resp FROM dual;
  HTP.P(l_resp);
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- /insight/clients/:client_id/notes
  --
  -- Additional information about a client: anything they told us that no
  -- question asked. Kept off the answers endpoints deliberately -- notes
  -- feed no Fusion setup field, so they carry no question id, no type and
  -- no approval workflow. See V20 for why that separation is the point
  -- rather than a shortcut.
  --
  -- Requires V20. These three handlers reference insight_client_notes
  -- statically, unlike the notes block inside GET clients/:client_id: a
  -- missing table here means the feature does not exist, so degrading
  -- quietly would only hide that.
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id/notes',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Free-form additional information for one client');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id/notes',
      p_method         => 'GET',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => NULL,
      p_comments       => 'Live notes for a client, newest first',
      p_source         =>
'DECLARE
  l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := :api_key;
  l_client_id VARCHAR2(40)  := :client_id;
  l_out       CLOB;
  -- HTP.P is declared for VARCHAR2, so handing it a CLOB is PLS-00306 -- a
  -- COMPILE error, which this block''s EXCEPTION clause can never catch, so
  -- ORDS reports only ORDS-25001 / HTTP 555. Emit in chunks instead.
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
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  SELECT JSON_ARRAYAGG(
           JSON_OBJECT(
             ''id''        VALUE note_id,
             ''text''      VALUE note_text,
             ''source''    VALUE note_source,
             ''createdBy'' VALUE created_by,
             ''createdAt'' VALUE TO_CHAR(created_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"''),
             ''updatedAt'' VALUE TO_CHAR(updated_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"'')
             RETURNING CLOB)
           ORDER BY created_at DESC
           RETURNING CLOB)
    INTO l_out
    FROM iteria_ai.insight_client_notes
   WHERE client_id = l_client_id
     AND is_archived = 0;

  emit(NVL(l_out, TO_CLOB(''[]'')));
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id/notes',
      p_method         => 'POST',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => 'application/json',
      p_comments       => 'Adds one note. Additive -- never replaces an existing one',
      p_source         =>
'DECLARE
  l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := :api_key;
  l_client_id VARCHAR2(40)  := :client_id;
  l_body      CLOB          := :body_text;
  l_doc       JSON_OBJECT_T;
  l_text      CLOB;
  l_source    VARCHAR2(20);
  l_actor     VARCHAR2(100);
  l_note_id   NUMBER;
  l_exists    NUMBER;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  IF l_body IS NULL OR DBMS_LOB.GETLENGTH(l_body) = 0 THEN
    :status := 400; HTP.P(''{"ok":false,"error":"request body is required"}''); RETURN;
  END IF;

  BEGIN
    l_doc := JSON_OBJECT_T.parse(l_body);
  EXCEPTION WHEN OTHERS THEN
    :status := 400; HTP.P(''{"ok":false,"error":"request body is not valid JSON"}''); RETURN;
  END;

  l_text := l_doc.get_String(''text'');
  -- An empty note is a mis-click, not information. Rejecting it here is the
  -- enforcement the table cannot provide: Oracle allows no CHECK constraint
  -- on a LOB column.
  IF l_text IS NULL OR DBMS_LOB.GETLENGTH(l_text) = 0 THEN
    :status := 400; HTP.P(''{"ok":false,"error":"note text is required"}''); RETURN;
  END IF;

  -- Default CONSULTANT, not SALES_INTAKE: a note is typed by whoever is
  -- looking at the client screen. The assistant sends AI_ASSIST explicitly.
  l_source := SUBSTR(NVL(l_doc.get_String(''source''), ''CONSULTANT''), 1, 20);
  l_actor  := SUBSTR(NVL(l_doc.get_String(''actor''), ''insight-app''), 1, 100);

  -- The foreign key would catch this, but as ORA-02291 in a 500. A client
  -- that does not exist is a 404, and saying so is more use to the caller.
  SELECT COUNT(*) INTO l_exists
    FROM iteria_ai.insight_clients
   WHERE client_id = l_client_id;
  IF l_exists = 0 THEN
    :status := 404; HTP.P(''{"ok":false,"error":"client not found"}''); RETURN;
  END IF;

  INSERT INTO iteria_ai.insight_client_notes
         (client_id, note_text, note_source, created_by)
  VALUES (l_client_id, l_text, l_source, l_actor)
  RETURNING note_id INTO l_note_id;

  -- Notes are part of the client record, so adding one makes the client
  -- newer -- otherwise the roster''s "last updated" would ignore them.
  UPDATE iteria_ai.insight_clients
     SET updated_at = CURRENT_TIMESTAMP
   WHERE client_id = l_client_id;

  COMMIT;
  :status := 201;
  HTP.P(''{"ok":true,"noteId":'' || l_note_id || ''}'');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight',
      p_pattern        => 'clients/:client_id/notes',
      p_method         => 'PUT',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => 'application/json',
      p_comments       => 'Edits or archives one note, identified by noteId in the body',
      p_source         =>
'DECLARE
  l_api_key   VARCHAR2(200);
  l_req_key   VARCHAR2(200) := :api_key;
  l_client_id VARCHAR2(40)  := :client_id;
  l_body      CLOB          := :body_text;
  l_doc       JSON_OBJECT_T;
  l_note_id   NUMBER;
  l_text      CLOB;
  l_archived  NUMBER;
  l_has_text  NUMBER;
  l_has_arch  NUMBER;
BEGIN
  -- Dynamic SQL on purpose. A static reference to api_configuration makes
  -- the whole handler fail to COMPILE if that table is absent, and a
  -- compile error cannot be caught by the block''s own EXCEPTION clause --
  -- ORDS just returns ORDS-25001 / HTTP 555 with no usable detail. Bound
  -- at run time instead, a missing table is an ordinary exception, and
  -- "no key table" degrades to "no key required" rather than a dead API.
  BEGIN
    EXECUTE IMMEDIATE ''SELECT api_key FROM iteria_ai.insight_api_config WHERE is_active = ''''Y'''' AND ROWNUM = 1''
      INTO l_api_key;
  EXCEPTION WHEN OTHERS THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  IF l_body IS NULL OR DBMS_LOB.GETLENGTH(l_body) = 0 THEN
    :status := 400; HTP.P(''{"ok":false,"error":"request body is required"}''); RETURN;
  END IF;

  BEGIN
    l_doc := JSON_OBJECT_T.parse(l_body);
  EXCEPTION WHEN OTHERS THEN
    :status := 400; HTP.P(''{"ok":false,"error":"request body is not valid JSON"}''); RETURN;
  END;

  -- noteId travels in the body rather than the path so this needs no second
  -- template. The client id stays in the path, and the UPDATE matches on
  -- both -- so a note id from one client cannot be edited through another.
  BEGIN
    l_note_id := l_doc.get_Number(''noteId'');
  EXCEPTION WHEN OTHERS THEN l_note_id := NULL; END;
  IF l_note_id IS NULL THEN
    :status := 400; HTP.P(''{"ok":false,"error":"noteId is required"}''); RETURN;
  END IF;

  l_has_text := CASE WHEN l_doc.has(''text'')     THEN 1 ELSE 0 END;
  l_has_arch := CASE WHEN l_doc.has(''archived'') THEN 1 ELSE 0 END;
  IF l_has_text = 0 AND l_has_arch = 0 THEN
    :status := 400; HTP.P(''{"ok":false,"error":"nothing to change: send text or archived"}''); RETURN;
  END IF;

  l_text := l_doc.get_String(''text'');
  IF l_has_text = 1 AND (l_text IS NULL OR DBMS_LOB.GETLENGTH(l_text) = 0) THEN
    :status := 400; HTP.P(''{"ok":false,"error":"note text cannot be empty -- archive it instead"}''); RETURN;
  END IF;

  BEGIN
    l_archived := CASE WHEN l_doc.get_Boolean(''archived'') THEN 1 ELSE 0 END;
  EXCEPTION WHEN OTHERS THEN l_archived := 0; END;

  UPDATE iteria_ai.insight_client_notes
     SET note_text   = CASE WHEN l_has_text = 1 THEN l_text     ELSE note_text   END,
         is_archived = CASE WHEN l_has_arch = 1 THEN l_archived ELSE is_archived END
   WHERE note_id   = l_note_id
     AND client_id = l_client_id;

  IF SQL%ROWCOUNT = 0 THEN
    :status := 404; HTP.P(''{"ok":false,"error":"note not found for this client"}''); RETURN;
  END IF;

  UPDATE iteria_ai.insight_clients
     SET updated_at = CURRENT_TIMESTAMP
   WHERE client_id = l_client_id;

  COMMIT;
  HTP.P(''{"ok":true,"noteId":'' || l_note_id || ''}'');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ORDS.FINALIZE_IMPORT(
      p_prune   => FALSE,
      p_objects => NULL);

COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
