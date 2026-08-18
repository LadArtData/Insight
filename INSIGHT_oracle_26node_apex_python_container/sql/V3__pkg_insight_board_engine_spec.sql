ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- PL/SQL PACKAGE SPECIFICATION: PKG_AI_BOARD_ENGINE
-- Handles 26-node state-machine, EDL evaluation, and APEX 2-Way Writebacks.
-- ============================================================================
CREATE OR REPLACE PACKAGE pkg_insight_board_engine AS

    -- Types
    TYPE t_node_rec IS RECORD (
        node_id        insight_nodes_26.node_id%TYPE,
        node_code      insight_nodes_26.node_code%TYPE,
        current_status insight_nodes_26.current_status%TYPE,
        state_value    insight_nodes_26.state_value%TYPE,
        payload_json   insight_nodes_26.payload_json%TYPE
    );

    -- Main Entry Point for APEX apex.server.process asynchronous calls
    PROCEDURE process_edl_event(
        p_board_id       IN NUMBER,
        p_node_id        IN NUMBER,
        p_event_code     IN VARCHAR2,
        p_payload_json   IN CLOB,
        x_out_response   OUT CLOB
    );

    -- Standard APEX Process Event Writeback Procedure
    PROCEDURE process_board_event (
        p_board_id   IN NUMBER,
        p_node_index IN NUMBER,
        p_payload    IN CLOB,
        p_status     OUT VARCHAR2
    );

    -- EDL Rule Evaluation Engine
    PROCEDURE evaluate_edl_rules(
        p_board_id   IN NUMBER,
        p_node_id    IN NUMBER,
        p_event_code IN VARCHAR2
    );

    -- Cascade Event Propagator across target nodes
    PROCEDURE propagate_cascade(
        p_board_id        IN NUMBER,
        p_source_node_id  IN NUMBER,
        p_target_list     IN VARCHAR2,
        p_action_type     IN VARCHAR2,
        p_action_params   IN CLOB
    );

    -- Matrix JSON Generator for APEX UI Refresh
    FUNCTION get_matrix_state_json(
        p_board_id IN NUMBER
    ) RETURN CLOB;

    -- Board State Reset Procedure
    PROCEDURE reset_board(
        p_board_id IN NUMBER
    );

    -- Audit Activity Logger
    PROCEDURE log_activity(
        p_board_id         IN NUMBER,
        p_node_id          IN NUMBER,
        p_event_type       IN VARCHAR2,
        p_payload_sent     IN CLOB,
        p_payload_received IN CLOB,
        p_exec_time_ms     IN NUMBER,
        p_procedure_name   IN VARCHAR2,
        p_status           IN VARCHAR2 DEFAULT 'SUCCESS'
    );

END pkg_insight_board_engine;
/
