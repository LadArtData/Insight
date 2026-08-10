SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- SEED DATA: Board #1 and its 26 Node rows
-- Required before any PL/SQL call succeeds -- process_edl_event SELECTs FOR
-- UPDATE against an existing (board_id, node_id) row and raises NO_DATA_FOUND
-- if this has not been run.
-- ============================================================================

INSERT INTO insight_boards (board_id, board_name, description, status)
VALUES (1, 'Primary EDL Matrix', 'Default 26-node operational board.', 'ACTIVE');

INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (1, 1, 'N01', 'A', 'Control Interface Node', 'CONTROL', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (2, 1, 'N02', 'B', 'Master Controller', 'CONTROL', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (3, 1, 'N03', 'C', 'Matrix Coordinator', 'CONTROL', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (4, 1, 'N04', 'D', 'EDL Business Rules', 'RULES_ENGINE', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (5, 1, 'N05', 'E', 'Pipeline Evaluator', 'RULES_ENGINE', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (6, 1, 'N06', 'F', 'Event Classifier', 'RULES_ENGINE', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (7, 1, 'N07', 'G', 'Priority Queue Manager', 'PROCESSING', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (8, 1, 'N08', 'H', 'State Inspector', 'PROCESSING', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (9, 1, 'N09', 'I', 'Signal Normalizer', 'PROCESSING', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (10, 1, 'N10', 'J', 'Validation Engine', 'PROCESSING', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (11, 1, 'N11', 'K', 'Data Stream Router', 'PROCESSING', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (12, 1, 'N12', 'L', 'Batch Processor', 'PROCESSING', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (13, 1, 'N13', 'M', 'Threshold Monitor', 'MONITORING', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (14, 1, 'N14', 'N', 'State Cache Manager', 'MONITORING', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (15, 1, 'N15', 'O', 'Telemetry Collector', 'MONITORING', 'IDLE', 0.0000, 3, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (16, 1, 'N16', 'P', 'Audit Logger', 'MONITORING', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (17, 1, 'N17', 'Q', 'Schema A Table Buffer', 'DATA_LAYER', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (18, 1, 'N18', 'R', 'PL/SQL Package Cache', 'DATA_LAYER', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (19, 1, 'N19', 'S', 'CLOB Payload Repo', 'DATA_LAYER', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (20, 1, 'N20', 'T', 'Writeback Dispatcher', 'DATA_LAYER', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (21, 1, 'N21', 'U', 'ORDS Gateway Node', 'GATEWAY', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (22, 1, 'N22', 'V', 'REST Service Bridge', 'GATEWAY', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (23, 1, 'N23', 'W', 'Security Guard', 'GATEWAY', 'IDLE', 0.0000, 1, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (24, 1, 'N24', 'X', 'Session State Sync', 'GATEWAY', 'IDLE', 0.0000, 2, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (25, 1, 'N25', 'Y', 'Metrics Visualizer', 'REPORTING', 'IDLE', 0.0000, 3, 0);
INSERT INTO insight_nodes_26 (node_id, board_id, node_code, node_letter, node_name, category, current_status, state_value, priority, processing_count)
VALUES (26, 1, 'N26', 'Z', 'Recovery Monitor', 'REPORTING', 'IDLE', 0.0000, 1, 0);

COMMIT;
