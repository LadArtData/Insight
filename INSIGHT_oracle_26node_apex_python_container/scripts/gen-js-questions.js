#!/usr/bin/env node
"use strict";

// Generates the ALL_QUESTIONS array literal from questions/insight_questions.json
// and splices it into INSIGHT_app.html (repo root) between the
// GENERATED:QUESTIONS marker comments, then copies the result to
// web/index.html so the two stay in sync the same way they always have.
//
// Run with --check instead of writing to fail (exit 1) if regenerating
// would change either file -- this is what ci.yml uses to catch the
// question set drifting from questions/insight_questions.json.

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const JSON_PATH = path.join(ROOT, "questions", "insight_questions.json");
const APP_HTML_PATH = path.join(ROOT, "..", "INSIGHT_app.html");
const WEB_HTML_PATH = path.join(ROOT, "web", "index.html");

const START_MARKER = "  // GENERATED:QUESTIONS:START -- do not hand-edit; regenerate via\n  // scripts/gen-js-questions.js from questions/insight_questions.json\n  var ALL_QUESTIONS = [\n";
const END_MARKER = "\n  ];\n  // GENERATED:QUESTIONS:END\n";

function jsStringLiteral(s) {
  // Matches the existing file's convention: single-quoted, only escaping
  // the single quotes that need it (backslash-apostrophe, as already
  // used for e.g. "client\'s").
  return "'" + s.replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'";
}

function renderQuestion(q) {
  const parts = [
    `id: "${q.question_id}"`,
    `module: "${q.module_code}"`,
    `phase: "${q.phase}"`,
    `eyebrow: ${jsStringLiteral(q.eyebrow)}`,
    `text: ${jsStringLiteral(q.question_text)}`,
    `type: "${q.answer_type}"`,
    `answer: ${q.is_locked ? '"Yes"' : "null"}`,
    `required: ${q.is_required ? "true" : "false"}`,
  ];
  if (q.is_locked) parts.push("locked: true");
  return "    { " + parts.join(", ") + " },";
}

function main() {
  const check = process.argv.includes("--check");
  const questions = JSON.parse(fs.readFileSync(JSON_PATH, "utf8"));
  questions.sort((a, b) => a.display_order - b.display_order);
  const body = questions.map(renderQuestion).join("\n");
  const block = START_MARKER + body + END_MARKER;

  const current = fs.readFileSync(APP_HTML_PATH, "utf8");
  const markerRe = /  \/\/ GENERATED:QUESTIONS:START[\s\S]*?\/\/ GENERATED:QUESTIONS:END\n/;
  if (!markerRe.test(current)) {
    console.error("GENERATED:QUESTIONS markers not found in " + APP_HTML_PATH);
    process.exit(1);
  }
  const updated = current.replace(markerRe, block);

  if (check) {
    let dirty = false;
    if (updated !== current) {
      console.error("INSIGHT_app.html is out of sync with questions/insight_questions.json");
      dirty = true;
    }
    const webCurrent = fs.readFileSync(WEB_HTML_PATH, "utf8");
    if (webCurrent !== updated) {
      console.error("web/index.html is out of sync with the regenerated INSIGHT_app.html");
      dirty = true;
    }
    process.exit(dirty ? 1 : 0);
  }

  fs.writeFileSync(APP_HTML_PATH, updated);
  fs.writeFileSync(WEB_HTML_PATH, updated);
  console.log("Regenerated INSIGHT_app.html and web/index.html from questions/insight_questions.json");
}

main();
