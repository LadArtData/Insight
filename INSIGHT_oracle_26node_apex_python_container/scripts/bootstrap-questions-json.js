#!/usr/bin/env node
"use strict";

// One-time (and re-runnable-as-a-diagnostic) bootstrap: extracts the
// ALL_QUESTIONS array straight out of the live INSIGHT_app.html and
// cross-checks it field-by-field against sql/V12's MERGE source rows,
// before ever trusting either as the seed for questions/insight_questions.json.
//
// This is NOT part of the ongoing generate flow (that's
// gen-sql-seed.js / gen-js-questions.js, which both read *from*
// insight_questions.json). This script only exists to (a) have produced
// that file honestly the first time, from the actual current sources
// rather than transcribed by hand, and (b) be re-run later if anyone
// ever suspects the two might have drifted again before this tooling
// existed to prevent it.

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const APP_HTML_PATH = path.join(ROOT, "..", "INSIGHT_app.html");
const SQL_SEED_PATH = path.join(ROOT, "sql", "V12__questionnaire_seed_questions.sql");
const OUT_PATH = path.join(ROOT, "questions", "insight_questions.json");

function extractFromAppHtml() {
  const html = fs.readFileSync(APP_HTML_PATH, "utf8");
  const start = html.indexOf("var ALL_QUESTIONS = [");
  if (start === -1) throw new Error("ALL_QUESTIONS not found in " + APP_HTML_PATH);
  const arrayStart = html.indexOf("[", start);
  // Find the matching closing bracket by simple depth counting -- the
  // array contains no nested [] of its own, so this is safe.
  let depth = 0, end = -1;
  for (let i = arrayStart; i < html.length; i++) {
    if (html[i] === "[") depth++;
    else if (html[i] === "]") { depth--; if (depth === 0) { end = i; break; } }
  }
  if (end === -1) throw new Error("Could not find closing bracket for ALL_QUESTIONS");
  const literal = html.slice(arrayStart, end + 1);
  // Trusted, controlled source (this repo's own app.html) -- safe to
  // evaluate as a JS literal rather than hand-writing a parser for it.
  const arr = new Function("return " + literal)();
  return arr.map((q, i) => ({
    question_id: q.id,
    module_code: q.module,
    phase: Number(q.phase),
    eyebrow: q.eyebrow,
    question_text: q.text,
    answer_type: q.type,
    is_required: q.required ? 1 : 0,
    is_locked: q.locked ? 1 : 0,
    display_order: i + 1,
  }));
}

function extractFromSql() {
  const sql = fs.readFileSync(SQL_SEED_PATH, "utf8");
  const rowRe =
    /SELECT\s+'([^']+)'\s+AS question_id,\s+'([^']+)'\s+AS module_code,\s+(\d+)\s+AS phase,\s+'((?:[^']|'')*)'\s+AS eyebrow,\s+'((?:[^']|'')*)'\s+AS question_text,\s+'([^']+)'\s+AS answer_type,\s+(\d)\s+AS is_required,\s+(\d)\s+AS is_locked,\s+(\d+)\s+AS display_order\s+FROM dual/g;
  const unescape = (s) => s.replace(/''/g, "'");
  const rows = [];
  let m;
  while ((m = rowRe.exec(sql))) {
    rows.push({
      question_id: m[1],
      module_code: m[2],
      phase: Number(m[3]),
      eyebrow: unescape(m[4]),
      question_text: unescape(m[5]),
      answer_type: m[6],
      is_required: Number(m[7]),
      is_locked: Number(m[8]),
      display_order: Number(m[9]),
    });
  }
  return rows;
}

function diffRows(fromHtml, fromSql) {
  const byId = new Map(fromSql.map((r) => [r.question_id, r]));
  const mismatches = [];
  for (const h of fromHtml) {
    const s = byId.get(h.question_id);
    if (!s) { mismatches.push(`${h.question_id}: present in HTML, missing in SQL`); continue; }
    for (const key of Object.keys(h)) {
      if (h[key] !== s[key]) {
        mismatches.push(`${h.question_id}.${key}: HTML="${h[key]}" SQL="${s[key]}"`);
      }
    }
    byId.delete(h.question_id);
  }
  for (const id of byId.keys()) mismatches.push(`${id}: present in SQL, missing in HTML`);
  return mismatches;
}

const fromHtml = extractFromAppHtml();
const fromSql = extractFromSql();
console.log(`Extracted ${fromHtml.length} questions from INSIGHT_app.html, ${fromSql.length} from V12 SQL.`);

const mismatches = diffRows(fromHtml, fromSql);
if (mismatches.length) {
  console.error(`\n${mismatches.length} mismatch(es) found -- resolve before trusting either source:`);
  mismatches.forEach((m) => console.error("  " + m));
  process.exit(1);
}
console.log("HTML and SQL agree on every field for all 91 questions. Writing questions.json from the HTML source.");

fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
fs.writeFileSync(OUT_PATH, JSON.stringify(fromHtml, null, 2) + "\n");
console.log("Wrote " + OUT_PATH);
