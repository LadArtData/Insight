SET DEFINE OFF
-- ============================================================================
-- ORDS REST MODULE: insight-questionnaire
--
-- The REST layer for the discovery questionnaire (V7-V13). Companion to
-- INSIGHT_06's insight-hooks module, which covers only the 26-node matrix
-- and exposes nothing from insight_clients / insight_client_answers --
-- which is why the questionnaire front end had no backend to talk to.
--
-- Registered under ADMIN (the only login on the target database) and
-- reaches into ITERIA_AI, same as insight-hooks.
--
-- Run AFTER V7-V13 have been applied. This is ORDS metadata, not a schema
-- migration, so it is deliberately not Flyway-tracked -- run it by hand,
-- connected as ADMIN, exactly like INSIGHT_06.
--
-- Base path once deployed: /ords/admin/insight-questionnaire/
--
--   GET    clients              List of client records (id, name, updated).
--   GET    clients/:client_id   One client, reassembled into the record
--                               shape the front end already uses.
--   PUT    clients/:client_id   Upsert a client and its answers.
--   DELETE clients/:client_id   Archive a client (status = ARCHIVED).
--
-- On the PUT handler: the front end saves the WHOLE answer set on every
-- save, but pkg_insight_answers.record_answer routes any change to an
-- already-answered question through the approval workflow. Replaying every
-- answer unconditionally would therefore raise a PENDING change request
-- per question on every save. So each answer is compared against what is
-- already stored and record_answer is called only where the value actually
-- changed. Unchanged answers are skipped entirely.
-- ============================================================================

BEGIN

  ORDS.DEFINE_MODULE(
      p_module_name    => 'insight-questionnaire',
      p_base_path      => '/insight-questionnaire/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'INSIGHT discovery questionnaire -- client records and answers');

  ----------------------------------------------------------------------------
  -- GET /insight-questionnaire/clients
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight-questionnaire',
      p_pattern        => 'clients',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'List of active client records');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-questionnaire',
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
BEGIN
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  SELECT JSON_ARRAYAGG(
           JSON_OBJECT(
             ''id''          VALUE client_id,
             ''companyName'' VALUE company_name,
             ''updatedAt''   VALUE TO_CHAR(updated_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"'')
             RETURNING CLOB)
           ORDER BY updated_at DESC RETURNING CLOB)
    INTO l_out
    FROM iteria_ai.insight_clients
   WHERE status = ''ACTIVE'';

  HTP.P(NVL(l_out, ''[]''));
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- GET /insight-questionnaire/clients/:client_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'insight-questionnaire',
      p_pattern        => 'clients/:client_id',
      p_priority       => 0,
      p_etag_type      => 'NONE',
      p_etag_query     => NULL,
      p_comments       => 'One client record with all answers');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-questionnaire',
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
  l_created   VARCHAR2(30);
  l_updated   VARCHAR2(30);
  l_answers   CLOB;
  l_skipped   CLOB;
BEGIN
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
  IF l_api_key IS NOT NULL AND NVL(l_req_key,''__none__'') != l_api_key THEN
    :status := 403; HTP.P(''{"ok":false,"error":"unauthorized"}''); RETURN;
  END IF;

  BEGIN
    SELECT company_name,
           TO_CHAR(created_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"''),
           TO_CHAR(updated_at AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"'')
      INTO l_name, l_created, l_updated
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

  HTP.P(''{"id":'' || JSON_SCALAR(l_client_id)
       || '',"companyName":'' || JSON_SCALAR(l_name)
       || '',"answers":''  || NVL(l_answers, ''{}'')
       || '',"skipped":''  || NVL(l_skipped, ''{}'')
       || '',"createdAt":'' || JSON_SCALAR(l_created)
       || '',"updatedAt":'' || JSON_SCALAR(l_updated)
       || ''}'');
EXCEPTION WHEN OTHERS THEN
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  ----------------------------------------------------------------------------
  -- PUT /insight-questionnaire/clients/:client_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-questionnaire',
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
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
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

  l_name  := SUBSTR(NVL(l_doc.get_String(''companyName''), ''Unnamed client''), 1, 300);
  l_actor := SUBSTR(NVL(l_doc.get_String(''actor''), ''insight-app''), 1, 100);

  MERGE INTO iteria_ai.insight_clients t
  USING (SELECT l_client_id AS client_id FROM dual) s
     ON (t.client_id = s.client_id)
  WHEN MATCHED THEN UPDATE SET t.company_name = l_name
  WHEN NOT MATCHED THEN INSERT (client_id, company_name, created_by)
                        VALUES (l_client_id, l_name, l_actor);

  IF l_doc.has(''answers'') THEN
    l_answers := l_doc.get_Object(''answers'');
    IF l_doc.has(''skipped'') THEN
      l_skipped := l_doc.get_Object(''skipped'');
    ELSE
      l_skipped := JSON_OBJECT_T.parse(''{}'');
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
  -- DELETE /insight-questionnaire/clients/:client_id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
      p_module_name    => 'insight-questionnaire',
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
BEGIN
  BEGIN SELECT api_key INTO l_api_key FROM iteria_ai.api_configuration
        WHERE is_active=''Y'' AND ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_api_key := NULL; END;
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
  HTP.P(''{"ok":true,"archived":'' || JSON_SCALAR(l_client_id) || ''}'');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  :status := 500;
  HTP.P(''{"ok":false,"error":"'' || REPLACE(SUBSTR(SQLERRM,1,300),''"'',''`'') || ''"}'');
END;');

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
