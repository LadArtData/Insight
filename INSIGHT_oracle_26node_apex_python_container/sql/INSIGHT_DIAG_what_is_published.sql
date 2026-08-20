-- ============================================================================
-- What does ORDS actually have published right now?
--
-- Run as ADMIN in Database Actions. Read-only.
--
-- Expected after INSIGHT_06 applies cleanly: one module, five templates,
-- seven handlers.
--
--   insight  health                   GET
--   insight  matrix/:board_id         GET
--   insight  nodes/:node_id/trigger   POST
--   insight  clients                  GET
--   insight  clients/:client_id       GET
--   insight  clients/:client_id       PUT
--   insight  clients/:client_id       DELETE
--
-- A short list means only part of the script ran. Anything still named
-- insight-hooks or insight-questionnaire means the DELETE_MODULE calls
-- did not take.
-- ============================================================================

SELECT m.name        AS module_name,
       m.uri_prefix  AS base_path,
       m.status,
       t.uri_template AS pattern,
       h.method
  FROM user_ords_modules   m
  LEFT JOIN user_ords_templates t ON t.module_id   = m.id
  LEFT JOIN user_ords_handlers  h ON h.template_id = t.id
 WHERE LOWER(m.name) LIKE '%insight%'
 ORDER BY m.name, t.uri_template, h.method;
