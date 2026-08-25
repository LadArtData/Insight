#!/usr/bin/env node
"use strict";

// Generates two blocks from questions/ and splices them into
// INSIGHT_app.html (repo root) between marker comments, then copies the
// result to web/index.html so the two stay in sync the same way they always
// have:
//
//   GENERATED:QUESTIONS   ALL_QUESTIONS, from insight_questions.json
//   GENERATED:GUIDANCE    QUESTION_GUIDANCE, from insight_question_guidance.json
//
// The guidance is generated INTO the page rather than fetched at runtime so
// the app stays a single self-contained file -- it still works opened
// straight off disk, with no server and no second request.
//
// Run with --check instead of writing to fail (exit 1) if regenerating
// would change either file -- this is what ci.yml uses to catch the
// question set drifting from questions/insight_questions.json.

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const JSON_PATH = path.join(ROOT, "questions", "insight_questions.json");
const GUIDANCE_PATH = path.join(ROOT, "questions", "insight_question_guidance.json");
const APP_HTML_PATH = path.join(ROOT, "..", "INSIGHT_app.html");
const WEB_HTML_PATH = path.join(ROOT, "web", "index.html");

const START_MARKER = "  // GENERATED:QUESTIONS:START -- do not hand-edit; regenerate via\n  // scripts/gen-js-questions.js from questions/insight_questions.json\n  var ALL_QUESTIONS = [\n";
const END_MARKER = "\n  ];\n  // GENERATED:QUESTIONS:END\n";

const G_START_MARKER = "  // GENERATED:GUIDANCE:START -- do not hand-edit; regenerate via\n  // scripts/gen-js-questions.js from questions/insight_question_guidance.json\n  var QUESTION_GUIDANCE = ";
const G_END_MARKER = ";\n  // GENERATED:GUIDANCE:END\n";

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
  // Only the exception is emitted. Almost every question is revisited on an
  // update, so writing askOnUpdate on all hundred would be noise around the
  // eighteen that matter.
  if (!q.ask_on_update) parts.push("intakeOnly: true");
  // Owned by the client file: asked once, during a new client's first
  // intake, then edited there and never asked again.
  if (q.client_file) parts.push("clientFile: true");
  return "    { " + parts.join(", ") + " },";
}

function renderGuidance() {
  const raw = JSON.parse(fs.readFileSync(GUIDANCE_PATH, "utf8"));
  // _about documents the file for whoever edits it. It is not shipped: the
  // page has no use for it and it would only bloat every download.
  const entries = Object.keys(raw)
    .filter((k) => !k.startsWith("_"))
    .sort()
    .map((k) => "    " + JSON.stringify(k) + ": " + JSON.stringify(raw[k]));
  return "{\n" + entries.join(",\n") + "\n  }";
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
  let updated = current.replace(markerRe, block);

  const gMarkerRe = /  \/\/ GENERATED:GUIDANCE:START[\s\S]*?\/\/ GENERATED:GUIDANCE:END\n/;
  if (!gMarkerRe.test(updated)) {
    console.error("GENERATED:GUIDANCE markers not found in " + APP_HTML_PATH);
    process.exit(1);
  }
  updated = updated.replace(gMarkerRe, G_START_MARKER + renderGuidance() + G_END_MARKER);

  if (check) {
    let dirty = false;
    if (updated !== current) {
      console.error("INSIGHT_app.html is out of sync with questions/");
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
  console.log("Regenerated INSIGHT_app.html and web/index.html from questions/");
}

main();
