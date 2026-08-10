-- Runs once, at first container startup, connected as SYS to the FREE
-- instance root (per gvenzl/oracle-free's init-script contract). We switch
-- into the FREEPDB1 pluggable database, then @@ the real numbered scripts
-- unmodified from /sql (mounted read-only from ../sql) so there is a single
-- source of truth for the schema -- this wrapper never duplicates their
-- content. SYS has DBA privileges in FREEPDB1, so the scripts' own
-- `ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;` lines work exactly as
-- they do against the real Autonomous DB connected as ADMIN.
--
-- sql/INSIGHT_06 (ORDS REST module) and sql/ADMIN_reference_export.sql /
-- INSIGHT_ADMIN_cleanup_old_objects.sql are intentionally NOT run here --
-- this container has no ORDS, and the ADMIN scripts aren't part of the
-- INSIGHT app's own deploy sequence.

ALTER SESSION SET CONTAINER = FREEPDB1;

@@/sql/INSIGHT_01_schema_a_nodes_26.sql
@@/sql/INSIGHT_02_schema_b_edl_rules.sql
@@/sql/INSIGHT_03_pkg_insight_board_engine_spec.sql
@@/sql/INSIGHT_04_pkg_insight_board_engine_body.sql
@@/sql/INSIGHT_05_seed_initial_data.sql

EXIT
