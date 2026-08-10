SET DEFINE OFF
-- ============================================================================
-- ORDS REST MODULE: insight-hooks
-- Native Oracle REST Data Services module, following the same pattern as the
-- frp-hooks / scout-hooks / validate-hooks modules already defined in this
-- ADMIN schema (see ADMIN.sql): ORDS.DEFINE_MODULE/TEMPLATE/HANDLER with
-- plsql/block handlers, the same api_key check against
-- iteria_ai.api_configuration, and the same {"ok":...} JSON envelope.
--
-- This is the live REST interface for the 26-node matrix -- it calls
-- iteria_ai.pkg_insight_board_engine directly, no separate application
-- server required. This module itself is registered under ADMIN (there is
-- a single Oracle login), same as frp-hooks/scout-hooks/validate-hooks,
-- while the tables and package it calls live in ITERIA_AI (INSIGHT_01
-- through INSIGHT_05), alongside FRP_DOCS, FRP_CHUNKS, etc.
--
-- Base path once deployed: /ords/admin/insight-hooks/
-- Run after INSIGHT_01 through INSIGHT_05.
-- ============================================================================

DECLARE
  l_roles     OWA.VC_ARR;
  l_modules   OWA.VC_ARR;
  l_patterns  OWA.VC_ARR;
BEGIN
  ORDS.DEFINE_MODULE(
      p_module_name    => 'insight-hooks',
      p_base_path      => '/insight-hooks/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'INSIGHT 26-node EDL matrix -- health, state, and node trigger endpoints');

  ----------------------------------------------------------------------------
  -- GET /insight-hooks/health
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight-hooks',
      p_pattern        => 'health',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Sanity ping -- board/node counts');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-hooks',
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
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
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
  -- GET /insight-hooks/matrix/:board_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight-hooks',
      p_pattern        => 'matrix/:board_id',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Full current node state for one board');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-hooks',
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
BEGIN
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  l_nodes := iteria_ai.pkg_insight_board_engine.get_matrix_state_json(p_board_id => l_board_id);

  HTP.P(''{"ok":true,"board_id":'' || l_board_id
       || '',"nodes":'' || NVL(l_nodes, ''[]'') || ''}'' );
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- POST /insight-hooks/nodes/:node_id/trigger
  -- Body: {"board_id":1,"event_code":"ON_USER_TRIGGER","payload":{...}}
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight-hooks',
      p_pattern        => 'nodes/:node_id/trigger',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'Fires the 2-way writeback for one node');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-hooks',
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
BEGIN
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
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

  HTP.P(''{"ok":true,"board_id":'' || l_board_id
       || '',"node_id":''  || l_node_id
       || '',"nodes":''    || NVL(l_out, ''[]'') || ''}'' );
EXCEPTION WHEN OTHERS THEN
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
