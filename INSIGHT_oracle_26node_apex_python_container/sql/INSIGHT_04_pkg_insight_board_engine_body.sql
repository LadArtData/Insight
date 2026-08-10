SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- PL/SQL PACKAGE BODY: PKG_AI_BOARD_ENGINE
-- Implementation of EDL execution engine, state update, and APEX ORDS callbacks.
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY pkg_insight_board_engine AS

    ---------------------------------------------------------------------------
    -- PROCESS_EDL_EVENT: Main Write-Back Handler
    ---------------------------------------------------------------------------
    PROCEDURE process_edl_event(
        p_board_id       IN NUMBER,
        p_node_id        IN NUMBER,
        p_event_code     IN VARCHAR2,
        p_payload_json   IN CLOB,
        x_out_response   OUT CLOB
    ) IS
        v_start_time   TIMESTAMP := SYSTIMESTAMP;
        v_exec_ms      NUMBER;
        v_node_code    VARCHAR2(10);
        v_old_status   VARCHAR2(20);
        v_new_status   VARCHAR2(20) := 'ACTIVE';
        v_state_val    NUMBER;
    BEGIN
        -- 1. Validate Node ID Range (1 to 26)
        IF p_node_id < 1 OR p_node_id > 26 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Invalid Node ID: Must be between 1 and 26.');
        END IF;

        -- 2. Lock and fetch current node state
        SELECT node_code, current_status, state_value
          INTO v_node_code, v_old_status, v_state_val
          FROM insight_nodes_26
         WHERE board_id = p_board_id
           AND node_id = p_node_id
         FOR UPDATE;

        -- 3. Execute State Update
        v_state_val := LEAST(100, v_state_val + 10);
        
        UPDATE insight_nodes_26
           SET current_status = v_new_status,
               state_value = v_state_val,
               payload_json = p_payload_json,
               processing_count = processing_count + 1,
               last_event_timestamp = CURRENT_TIMESTAMP
         WHERE board_id = p_board_id
           AND node_id = p_node_id;

        -- 4. Evaluate EDL Rules
        evaluate_edl_rules(
            p_board_id   => p_board_id,
            p_node_id    => p_node_id,
            p_event_code => p_event_code
        );

        -- 5. Prepare Output JSON State Response
        x_out_response := get_matrix_state_json(p_board_id);

        -- 6. Log Execution Audit Trail
        v_exec_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_start_time)) * 1000;
        log_activity(
            p_board_id         => p_board_id,
            p_node_id          => p_node_id,
            p_event_type       => p_event_code,
            p_payload_sent     => p_payload_json,
            p_payload_received => x_out_response,
            p_exec_time_ms     => v_exec_ms,
            p_procedure_name   => 'PKG_AI_BOARD_ENGINE.PROCESS_EDL_EVENT'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_activity(
                p_board_id         => p_board_id,
                p_node_id          => NVL(p_node_id, 1),
                p_event_type       => 'ERROR_' || p_event_code,
                p_payload_sent     => p_payload_json,
                p_payload_received => SQLERRM,
                p_exec_time_ms     => 0,
                p_procedure_name   => 'PKG_AI_BOARD_ENGINE.PROCESS_EDL_EVENT',
                p_status           => 'ERROR'
            );
            RAISE;
    END process_edl_event;

    ---------------------------------------------------------------------------
    -- PROCESS_BOARD_EVENT: Direct APEX Write-Back Execution
    ---------------------------------------------------------------------------
    PROCEDURE process_board_event (
        p_board_id   IN NUMBER,
        p_node_index IN NUMBER,
        p_payload    IN CLOB,
        p_status     OUT VARCHAR2
    ) IS
    BEGIN
        UPDATE insight_nodes_26
        SET payload_json = p_payload,
            current_status = 'ACTIVE',
            last_event_timestamp = CURRENT_TIMESTAMP
        WHERE board_id = p_board_id 
          AND node_id = p_node_index;

        IF SQL%NOTFOUND THEN
            p_status := 'ERROR: NODE NOT FOUND';
            RETURN;
        END IF;

        INSERT INTO insight_board_activity_log (board_id, node_id, event_type, payload_sent, status)
        VALUES (p_board_id, p_node_index, 'PROCESS_BOARD_EVENT', p_payload, 'SUCCESS');

        p_status := 'SUCCESS';
    EXCEPTION
        WHEN OTHERS THEN
            p_status := 'ERROR: ' || SQLERRM;
    END process_board_event;

    ---------------------------------------------------------------------------
    -- EVALUATE_EDL_RULES: Rules Engine Execution
    ---------------------------------------------------------------------------
    PROCEDURE evaluate_edl_rules(
        p_board_id   IN NUMBER,
        p_node_id    IN NUMBER,
        p_event_code IN VARCHAR2
    ) IS
    BEGIN
        FOR r IN (
            SELECT rule_id, rule_code, target_node_list, action_type, action_params
              FROM insight_edl_rules
             WHERE (source_node_id = p_node_id OR source_node_id IS NULL OR source_node_id = 0)
               AND is_active = 'Y'
        ) LOOP
            propagate_cascade(
                p_board_id       => p_board_id,
                p_source_node_id => p_node_id,
                p_target_list    => r.target_node_list,
                p_action_type    => r.action_type,
                p_action_params  => r.action_params
            );
        END LOOP;
    END evaluate_edl_rules;

    ---------------------------------------------------------------------------
    -- PROPAGATE_CASCADE: Update Connected Target Nodes
    ---------------------------------------------------------------------------
    PROCEDURE propagate_cascade(
        p_board_id        IN NUMBER,
        p_source_node_id  IN NUMBER,
        p_target_list     IN VARCHAR2,
        p_action_type     IN VARCHAR2,
        p_action_params   IN CLOB
    ) IS
    BEGIN
        -- Target nodes update in Cascade state
        UPDATE insight_nodes_26
           SET current_status = CASE 
                   WHEN p_action_type = 'LOCK_NODE' THEN 'LOCKED'
                   ELSE 'CASCADE'
               END,
               processing_count = processing_count + 1,
               last_event_timestamp = CURRENT_TIMESTAMP
         WHERE board_id = p_board_id
           AND INSTR(',' || p_target_list || ',', ',' || TO_CHAR(node_id) || ',') > 0;
    END propagate_cascade;

    ---------------------------------------------------------------------------
    -- GET_MATRIX_STATE_JSON: Returns complete 26-node state payload
    ---------------------------------------------------------------------------
    FUNCTION get_matrix_state_json(
        p_board_id IN NUMBER
    ) RETURN CLOB IS
        v_clob CLOB;
    BEGIN
        SELECT JSON_ARRAYAGG(
                   JSON_OBJECT(
                       'node_id'              VALUE node_id,
                       'node_code'            VALUE node_code,
                       'node_letter'          VALUE node_letter,
                       'node_name'            VALUE node_name,
                       'category'             VALUE category,
                       'current_status'       VALUE current_status,
                       'state_value'          VALUE state_value,
                       'payload_json'         VALUE JSON_QUERY(payload_json, '$' RETURNING CLOB),
                       'priority'             VALUE priority,
                       'processing_count'     VALUE processing_count,
                       'last_event_timestamp' VALUE TO_CHAR(last_event_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
                   ) RETURNING CLOB
               )
          INTO v_clob
          FROM insight_nodes_26
         WHERE board_id = p_board_id;

        RETURN v_clob;
    END get_matrix_state_json;

    ---------------------------------------------------------------------------
    -- RESET_BOARD: Resets 26 Nodes back to IDLE
    ---------------------------------------------------------------------------
    PROCEDURE reset_board(
        p_board_id IN NUMBER
    ) IS
    BEGIN
        UPDATE insight_nodes_26
           SET current_status = 'IDLE',
               state_value = 10.0,
               processing_count = 0,
               last_event_timestamp = CURRENT_TIMESTAMP
         WHERE board_id = p_board_id;
        COMMIT;
    END reset_board;

    ---------------------------------------------------------------------------
    -- LOG_ACTIVITY: Write to Audit Log
    ---------------------------------------------------------------------------
    PROCEDURE log_activity(
        p_board_id         IN NUMBER,
        p_node_id          IN NUMBER,
        p_event_type       IN VARCHAR2,
        p_payload_sent     IN CLOB,
        p_payload_received IN CLOB,
        p_exec_time_ms     IN NUMBER,
        p_procedure_name   IN VARCHAR2,
        p_status           IN VARCHAR2 DEFAULT 'SUCCESS'
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO insight_board_activity_log (
            board_id, node_id, event_type, payload_sent, payload_received,
            execution_time_ms, plsql_procedure, status
        ) VALUES (
            p_board_id, p_node_id, p_event_type, p_payload_sent, p_payload_received,
            p_exec_time_ms, p_procedure_name, p_status
        );
        COMMIT;
    END log_activity;

END pkg_insight_board_engine;
/
