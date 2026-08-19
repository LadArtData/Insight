#!/usr/bin/env node
"use strict";

// Generates sql/V12__questionnaire_seed_questions.sql from
// questions/insight_questions.json, using the same MERGE pattern the file
// already used (upsert by question_id, so re-running is safe -- this
// predates and is unrelated to Flyway's own once-per-environment guarantee).
//
// Run with --check to fail (exit 1) instead of writing if regenerating
// would change the file -- this is what ci.yml uses to catch the SQL seed
// drifting from questions/insight_questions.json.

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const JSON_PATH = path.join(ROOT, "questions", "insight_questions.json");
const SQL_PATH = path.join(ROOT, "sql", "V12__questionnaire_seed_questions.sql");

const HEADER = `ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- QUESTIONNAIRE BACKEND: SEED DATA FOR INSIGHT_QUESTIONS
-- Requires INSIGHT_07 (insight_questions table).
--
-- Generated from questions/insight_questions.json (scripts/gen-sql-seed.js)
-- -- the same source that generates INSIGHT_app.html's ALL_QUESTIONS array
-- (scripts/gen-js-questions.js), so the seeded rows can't drift from what
-- the front end asks. If a question is added/edited, edit
-- questions/insight_questions.json and regenerate both -- don't hand-edit
-- rows here.
-- ============================================================================

MERGE INTO insight_questions tgt
USING (
`;

const FOOTER = `
) src
ON (tgt.question_id = src.question_id)
WHEN MATCHED THEN UPDATE SET
    tgt.module_code   = src.module_code,
    tgt.phase         = src.phase,
    tgt.eyebrow       = src.eyebrow,
    tgt.question_text = src.question_text,
    tgt.answer_type   = src.answer_type,
    tgt.is_required   = src.is_required,
    tgt.is_locked     = src.is_locked,
    tgt.display_order = src.display_order
WHEN NOT MATCHED THEN INSERT (
    question_id, module_code, phase, eyebrow, question_text, answer_type, is_required, is_locked, display_order
) VALUES (
    src.question_id, src.module_code, src.phase, src.eyebrow, src.question_text, src.answer_type, src.is_required, src.is_locked, src.display_order
);

COMMIT;
`;

// Emits an Oracle string literal, with one wrinkle: an ampersand must never
// appear inside it.
//
// SQL*Plus, SQL Developer and Database Actions all treat "&" as the start of
// a substitution variable, so "Needs & Wants" makes the client stop and
// prompt for a value instead of running the script. The usual fix is a
// leading "SET DEFINE OFF", but that is a SQL*Plus directive, and Flyway
// rejects it unless flyway.oracle.sqlplus is enabled -- so these files have
// to be runnable without it.
//
// Splicing in CHR(38) sidesteps the whole problem: there is no literal "&"
// left in the file for any client to interpret, and it is plain SQL that
// Flyway, SQL*Plus and Database Actions all execute identically.
function sqlStringLiteral(s) {
  const escaped = s.replace(/'/g, "''");
  if (!escaped.includes("&")) return "'" + escaped + "'";
  return escaped
    .split("&")
    .map((part) => "'" + part + "'")
    .join(" || CHR(38) || ")
    .replace(/'' \|\| /g, "")        // drop empty literal if text starts with &
    .replace(/ \|\| ''$/g, "");      // drop empty literal if text ends with &
}

function renderRow(q) {
  return (
    "    SELECT " +
    `${sqlStringLiteral(q.question_id)} AS question_id, ` +
    `${sqlStringLiteral(q.module_code)} AS module_code, ` +
    `${q.phase} AS phase, ` +
    `${sqlStringLiteral(q.eyebrow)} AS eyebrow, ` +
    `${sqlStringLiteral(q.question_text)} AS question_text, ` +
    `${sqlStringLiteral(q.answer_type)} AS answer_type, ` +
    `${q.is_required} AS is_required, ` +
    `${q.is_locked} AS is_locked, ` +
    `${q.display_order} AS display_order FROM dual`
  );
}

function main() {
  const check = process.argv.includes("--check");
  const questions = JSON.parse(fs.readFileSync(JSON_PATH, "utf8"));
  questions.sort((a, b) => a.display_order - b.display_order);
  const rows = questions.map(renderRow).join("\n    UNION ALL\n");
  const content = HEADER + rows + FOOTER;

  if (check) {
    const current = fs.readFileSync(SQL_PATH, "utf8");
    if (current !== content) {
      console.error("sql/V12__questionnaire_seed_questions.sql is out of sync with questions/insight_questions.json");
      process.exit(1);
    }
    process.exit(0);
  }

  fs.writeFileSync(SQL_PATH, content);
  console.log("Regenerated " + SQL_PATH);
}

main();
