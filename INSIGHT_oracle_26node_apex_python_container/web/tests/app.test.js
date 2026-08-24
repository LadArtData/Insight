"use strict";

// Regression suite for index.html, driven end-to-end through a real DOM
// (jsdom) rather than unit-testing internals -- the app has no exposed
// module boundary (single IIFE), so this is the only way to exercise it.
// Each test boots a fresh JSDOM instance (its own window/localStorage) so
// tests don't leak state into each other.

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { JSDOM } = require("jsdom");

const HTML_PATH = path.join(__dirname, "..", "index.html");
const HTML = fs.readFileSync(HTML_PATH, "utf8");

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function countModuleQuestions(moduleCode) {
  var re = new RegExp('module: "' + moduleCode + '", phase: "3"', "g");
  return (HTML.match(re) || []).length;
}

// Derived from the source, never hardcoded: the deck changes whenever a
// question is split or added, and a test that asserts a literal count just
// breaks noisily without saying anything useful.
function countPhase(phase) {
  return (HTML.match(new RegExp('phase: "' + phase + '"', "g")) || []).length;
}
const INTAKE_COUNT = countPhase(1);
const QUALIFIER_COUNT = countPhase(2);
// GL is always in scope, so a client declining every optional module still
// sees intake + qualifiers + GL.
const GL_ONLY_DECK = INTAKE_COUNT + QUALIFIER_COUNT + countModuleQuestions("GL");

// A value that satisfies whatever the rendered field accepts. Typed fields
// (number, currency, email, phone) reject prose, so the old "answer N"
// placeholder no longer works for all of them.
function validValueFor(win) {
  const el = win.document.querySelector(".q-input");
  if (!el || el.tagName === "TEXTAREA") return null; // caller uses its own text
  switch (el.getAttribute("inputmode")) {
    case "numeric": return "12";
    case "decimal": return "5000";
    case "email":   return "test@example.com";
    case "tel":     return "+1 555 123 4567";
    default:        return null;
  }
}

// Boots a fresh app instance and advances past the loading screen to
// Client Records -- every test starts from here.
async function bootApp(beforeParse) {
  const dom = new JSDOM(HTML, {
    url: "http://localhost/",
    runScripts: "dangerously",
    // Lets a test install a fake fetch before the app script runs, which is
    // the only window in which the storage-mode probe can be influenced.
    beforeParse: typeof beforeParse === "function" ? beforeParse : undefined,
  });
  const { window } = dom;
  // jsdom doesn't implement the Blob/URL download path (used by D2's
  // export) -- polyfill so the app's own click-download wiring can be
  // tested without fighting jsdom's unrelated gaps.
  if (!window.URL.createObjectURL) window.URL.createObjectURL = function () { return "blob:test"; };
  if (!window.URL.revokeObjectURL) window.URL.revokeObjectURL = function () {};
  // Poll readyState rather than awaiting the "load" event. Under Node's
  // test runner (node --test) a listener attached here never fires, so
  // awaiting "load" hangs every test forever -- the suite emits
  // "TAP version 13" and nothing else. Polling is runner-agnostic.
  for (let i = 0; i < 300 && window.document.readyState !== "complete"; i++) {
    await wait(10);
  }
  await wait(1450); // loading screen's own 1400ms "ready" timer
  byId(window, "btn-start").click();
  return dom;
}

function byId(win, id) {
  return win.document.getElementById(id);
}

function progressLabel(win) {
  return byId(win, "q-progress-label").textContent;
}

function fillText(win, value) {
  const ta = win.document.querySelector(".q-input");
  ta.value = value;
  ta.dispatchEvent(new win.Event("input"));
}

// Fills the current question with something its type will accept.
function fillValid(win, fallbackText) {
  const typed = validValueFor(win);
  fillText(win, typed !== null ? typed : fallbackText);
}

function clickYn(win, value) {
  const buttons = Array.from(win.document.querySelectorAll(".yn-btn"));
  const btn = buttons.find((b) => b.textContent === value);
  btn.click();
}

async function clickNext(win) {
  byId(win, "q-next").click();
  await wait(10); // let advanceQuestionnaire()'s save/render microtasks settle
}

async function clickSkip(win) {
  byId(win, "q-skip").click();
  await wait(10);
}

// Answers every Phase 1 intake question with a value its type accepts.
async function fillIntake(win) {
  for (let i = 0; i < INTAKE_COUNT; i++) {
    fillValid(win, "answer " + i);
    await clickNext(win);
  }
}

// From the first Phase 2 qualifier (QUAL-GL, locked) through the last
// (QUAL-MULTI), answering AP/AR/FA/CM/MULTI as given.
async function answerQualifiers(win, { AP = "No", AR = "No", FA = "No", CM = "No", MULTI = "No" } = {}) {
  await clickNext(win); // QUAL-GL is locked Yes -- Next just advances
  clickYn(win, AP); await clickNext(win);
  clickYn(win, AR); await clickNext(win);
  clickYn(win, FA); await clickNext(win);
  clickYn(win, CM); await clickNext(win);
  clickYn(win, MULTI); await clickNext(win);
}

// Answers every remaining active question with placeholder text/Yes until
// the questionnaire hands off to chat. Used by tests that only care about
// what happens after the deck is complete (chat/summary/export).
async function finishRemainingQuestions(win) {
  // Loop, bounded well above the largest possible deck, so a stuck
  // loop fails fast instead of hanging the suite.
  for (let i = 0; i < 100; i++) {
    if (byId(win, "screen-chat").classList.contains("active")) return;
    const ynButtons = win.document.querySelectorAll(".yn-btn");
    if (ynButtons.length) clickYn(win, "Yes");
    else fillValid(win, "answer");
    await clickNext(win);
  }
  throw new Error("finishRemainingQuestions: never reached chat screen");
}

test("validation gate rejects an empty required answer", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await clickNext(win); // INTAKE-001 required, left blank
  assert.match(byId(win, "q-field-error").textContent, /required/i);
  assert.equal(progressLabel(win), "1 / " + GL_ONLY_DECK);
});

test("phase 1 intake advances through every intake question into phase 2 qualifiers", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  assert.equal(progressLabel(win), (INTAKE_COUNT + 1) + " / " + GL_ONLY_DECK);
  assert.match(byId(win, "q-eyebrow").textContent, /Phase 2/);
});

test("QUAL-GL renders locked: Yes pre-selected, both buttons disabled, skip hidden", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  const buttons = win.document.querySelectorAll(".yn-btn");
  assert.equal(buttons.length, 2);
  assert.ok(Array.from(buttons).every((b) => b.disabled));
  const yesBtn = Array.from(buttons).find((b) => b.textContent === "Yes");
  assert.ok(yesBtn.classList.contains("selected"));
  assert.equal(byId(win, "q-skip").style.display, "none");
});

test("answering a qualifier Yes grows the active deck by that module's question count (dynamic scope recalculation)", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await clickNext(win); // QUAL-GL locked, advance
  const before = GL_ONLY_DECK;
  const apCount = countModuleQuestions("AP");
  assert.ok(apCount > 0, "sanity: AP question count should be discoverable from source");
  clickYn(win, "Yes"); // QUAL-AP = Yes
  await clickNext(win);
  // now on QUAL-AR; jump back to check total via the progress denominator,
  // which is active.length and updates on every render
  const [, denom] = progressLabel(win).split(" / ");
  assert.equal(Number(denom), before + apCount);
});

test("declining a module excludes its questions from the active deck (scope branching)", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win, { AP: "No", AR: "No", FA: "No", CM: "No", MULTI: "No" });
  // All optional modules declined -- deck should be the GL-only baseline
  const [, denom] = progressLabel(win).split(" / ");
  assert.equal(Number(denom), GL_ONLY_DECK);
  assert.match(byId(win, "q-eyebrow").textContent, /GL Discovery/);
});

test("skipped required question resurfaces in AI Follow-Up chat, then clears the gap", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win); // GL-only deck
  // First GL question (GL-001, required, text) -- skip it to create exactly one gap
  await clickSkip(win);
  assert.match(byId(win, "q-eyebrow").textContent, /GL Discovery/);
  // finish the remaining GL questions normally
  await finishRemainingQuestions(win);
  assert.ok(byId(win, "screen-chat").classList.contains("active"));
  await wait(1300); // startChat()'s 700ms typing delay + message render
  const chatText = byId(win, "chat-body").textContent;
  assert.match(chatText, /1 required question/);
  // answer the gap via chat
  byId(win, "chat-input").value = "answering the skipped GL question";
  byId(win, "chat-send").click();
  await wait(900); // sendChat's 600ms typing delay + askNext's own render
  assert.match(byId(win, "chat-body").textContent, /covers the required gaps/);
});

test("summary module badges reflect each qualifier's answer", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win, { AP: "Yes", AR: "No", FA: "Yes", CM: "No", MULTI: "No" });
  await finishRemainingQuestions(win); // now on chat, no gaps (all required GL/AP/FA questions still need answers though)
  // finishRemainingQuestions stops as soon as chat is reached; AP/FA text
  // questions were answered "Yes" or "answer" by the loop already since it
  // fills every active question until handoff -- confirm no gaps remain
  await wait(1300);
  assert.match(byId(win, "chat-body").textContent, /no gaps to fill in|Everything required is already captured/);
  await wait(1100); // no-gaps branch's 1000ms auto-advance to summary
  assert.ok(byId(win, "screen-summary").classList.contains("active"));
  const win2 = win; // renderSummaryModules() already ran as part of the auto-advance
  assert.equal(byId(win2, "mod-status-ap").textContent, "Included");
  assert.equal(byId(win2, "mod-status-ar").textContent, "Not in scope");
  assert.equal(byId(win2, "mod-status-fa").textContent, "Included");
  assert.equal(byId(win2, "mod-status-cm").textContent, "Not in scope");
});

test("persistence: saved record shape has answers/skipped/companyName", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "Acme Corp, Acme");
  await clickNext(win);
  // Goes through window.storage (the public contract), not a specific
  // backing store -- storage is in-memory-per-session now (see the
  // "no client data survives a reload" test below), not localStorage.
  const indexRes = await win.storage.get("clients-index");
  const index = JSON.parse(indexRes.value);
  assert.equal(index.length, 1);
  const recordRes = await win.storage.get("client:" + index[0].id);
  const record = JSON.parse(recordRes.value);
  assert.ok(record.answers && typeof record.answers === "object");
  assert.ok(record.skipped && typeof record.skipped === "object");
  assert.equal(record.companyName, "Acme Corp");
  assert.equal(record.answers["INTAKE-001"], "Acme Corp, Acme");
});

test("no client data survives a reload (in-memory storage only, not localStorage)", async () => {
  const dom1 = await bootApp();
  const win1 = dom1.window;
  byId(win1, "btn-new-client").click();
  fillText(win1, "Acme Corp, Acme");
  await clickNext(win1);
  const index1 = JSON.parse((await win1.storage.get("clients-index")).value);
  assert.equal(index1.length, 1, "sanity: the client was actually saved in this session");

  // A fresh JSDOM instance is the closest equivalent to a real reload --
  // a brand new window, so the in-memory store from dom1 cannot leak in.
  const dom2 = await bootApp();
  const win2 = dom2.window;
  byId(win2, "nav-clients").click();
  await wait(10);
  assert.match(byId(win2, "records-list-area").textContent, /No clients yet/);
});

test("resume: reopening a saved client restores position at the first unanswered question", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win); // now on QUAL-GL (index 10); it's locked with a valid
  // default answer already, so it isn't a "gap" -- the real first unanswered
  // question is the first qualifier, which is where resume should land.
  byId(win, "nav-clients").click();
  await wait(10);
  byId(win, "records-list-area").querySelector('[data-open]').click();
  await wait(10);
  assert.equal(progressLabel(win), (INTAKE_COUNT + 2) + " / " + GL_ONLY_DECK);
  assert.match(byId(win, "q-eyebrow").textContent, /Phase 2/);
});

test("crumb navigation: clicking the Questionnaire crumb re-renders the in-progress question", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  win.document.querySelector('.crumb[data-crumb="chat"]').click();
  await wait(50);
  win.document.querySelector('.crumb[data-crumb="questionnaire"]').click();
  await wait(10);
  assert.ok(byId(win, "screen-questionnaire").classList.contains("active"));
  assert.equal(progressLabel(win), (INTAKE_COUNT + 1) + " / " + GL_ONLY_DECK);
});

test("D1 regression: leaving chat before the auto-advance timer fires does not force-navigate back to Summary", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win); // GL-only, no other modules in scope
  await finishRemainingQuestions(win); // all GL answered -> chat entered at T=0
  await wait(50); // T=50ms -- well before the 700ms typing delay even fires
  byId(win, "nav-clients").click(); // navigate away long before the hijack timer fires
  await wait(10);
  assert.ok(byId(win, "screen-records").classList.contains("active"));
  // The hijack timer fires at T=700ms (typing delay) + 1000ms (no-gaps
  // auto-advance) = T=1700ms. Wait past that with margin before asserting.
  await wait(1900);
  assert.ok(byId(win, "screen-records").classList.contains("active"), "should still be on Records");
  assert.ok(!byId(win, "screen-summary").classList.contains("active"), "must not have been hijacked to Summary");
});

test("D2 regression: Export Configuration downloads a record snapshot instead of alerting", async () => {
  const dom = await bootApp();
  const win = dom.window;
  let alertCalled = false;
  win.alert = () => { alertCalled = true; };
  // Record the click without invoking jsdom's real anchor-click behavior --
  // jsdom doesn't implement the `download` attribute's no-navigate
  // semantics, so calling through would throw "Not implemented:
  // navigation". Recording that click() was invoked (with the right
  // attributes already set on the element) is sufficient to verify the
  // app's own wiring without exercising jsdom's unrelated gap.
  let clickedAnchor = null;
  win.HTMLAnchorElement.prototype.click = function () {
    clickedAnchor = this;
  };

  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win);
  await finishRemainingQuestions(win);
  await wait(1200); // no-gaps chat message
  await wait(1100); // auto-advance to summary
  assert.ok(byId(win, "screen-summary").classList.contains("active"));

  byId(win, "btn-export").click();
  await wait(50); // export is async now -- it reads the committed record first

  assert.equal(alertCalled, false, "export must not fall back to the old mockup alert");
  assert.ok(clickedAnchor, "export should trigger a download anchor click");
  assert.match(clickedAnchor.download, /-export\.json$/);
});

test("quality check: keyboard-mashed text warns and blocks the first Next click", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "ewdrefvebrn"); // one unbroken 11-char token -- exactly the reported case
  byId(win, "q-next").click();
  await wait(10);
  assert.match(byId(win, "q-quality-warning").textContent, /looks short or unclear/i);
  assert.equal(progressLabel(win), "1 / " + GL_ONLY_DECK, "must not have advanced on the first click");
});

test("quality check: a bracket-containing answer also warns", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "[piuo8ytru");
  byId(win, "q-next").click();
  await wait(10);
  assert.match(byId(win, "q-quality-warning").textContent, /looks short or unclear/i);
  assert.equal(progressLabel(win), "1 / " + GL_ONLY_DECK);
});

test("quality check: clicking Next a second time proceeds anyway (human judgment wins)", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "ewdrefvebrn");
  await clickNext(win); // first click: warns, blocks
  await clickNext(win); // second click: same text, already acknowledged -- proceeds
  assert.equal(progressLabel(win), "2 / " + GL_ONLY_DECK);
});

test("quality check: editing the text after a warning re-checks it fresh", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "ewdrefvebrn");
  byId(win, "q-next").click();
  await wait(10);
  assert.equal(byId(win, "q-quality-warning").classList.contains("show"), true);
  fillText(win, "Meridian County Government"); // real multi-word answer
  assert.equal(byId(win, "q-quality-warning").classList.contains("show"), false, "warning should clear as soon as the text changes");
  await clickNext(win); // single click -- a normal answer never needed a second confirm
  assert.equal(progressLabel(win), "2 / " + GL_ONLY_DECK);
});

test("quality check: normal multi-word answers never trigger the warning", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win); // fillIntake's "answer 0".."answer 9" are all multi-word/short -- none should ever warn
  assert.equal(byId(win, "q-quality-warning").classList.contains("show"), false);
});

// ---------------------------------------------------------------------------
// ORDS-backed storage. The app probes /clients at startup and only upgrades
// off the in-memory store if that call returns JSON, so these tests install a
// fake fetch before the app script parses.
// ---------------------------------------------------------------------------

function fakeFetch(routes, calls) {
  return function (url, opts) {
    const method = (opts && opts.method) || "GET";
    calls.push({ method, url, body: opts && opts.body });
    const key = method + " " + String(url).replace("http://localhost", "");
    const handler = routes[key];
    if (!handler) return Promise.reject(new Error("no route for " + key));
    const payload = handler();
    return Promise.resolve({
      ok: true,
      status: 200,
      json: () => Promise.resolve(payload),
      text: () => Promise.resolve(JSON.stringify(payload)),
    });
  };
}

const API = "/ords/admin/insight";

test("storage: uses the ORDS backend when the probe succeeds", async () => {
  const calls = [];
  const dom = await bootApp((win) => {
    win.fetch = fakeFetch({
      [`GET ${API}/clients`]: () => ([
        { id: "c-1", companyName: "Meridian", updatedAt: "2026-08-19T10:00:00Z" },
      ]),
    }, calls);
  });
  const win = dom.window;
  await wait(60);

  assert.ok(calls.some((c) => c.method === "GET" && c.url.endsWith(`${API}/clients`)),
    "should have probed the clients endpoint");
  const note = byId(win, "records-note").textContent;
  assert.match(note, /Saved to the Insight database/,
    "records note should report the database is connected");
  assert.match(byId(win, "records-list-area").textContent, /Meridian/,
    "client list should render rows returned by the API");
  win.close();
});

test("storage: saving a client PUTs to the ORDS endpoint", async () => {
  const calls = [];
  const dom = await bootApp((win) => {
    win.fetch = fakeFetch({
      [`GET ${API}/clients`]: () => ([]),
      [`PUT ${API}/clients/anything`]: () => ({ ok: true }),
    }, calls);
  });
  const win = dom.window;
  await wait(60);

  // Route every PUT regardless of the generated client id.
  win.fetch = (url, opts) => {
    const method = (opts && opts.method) || "GET";
    calls.push({ method, url, body: opts && opts.body });
    return Promise.resolve({
      ok: true, status: 200,
      json: () => Promise.resolve({ ok: true }),
      text: () => Promise.resolve('{"ok":true}'),
    });
  };

  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Meridian County");
  await clickNext(win);
  await wait(60);

  const puts = calls.filter((c) => c.method === "PUT");
  assert.ok(puts.length > 0, "answering a question should PUT the client record");
  assert.match(puts[0].url, new RegExp(`${API}/clients/`), "PUT should target the clients resource");
  const sent = JSON.parse(puts[0].body);
  assert.equal(sent.answers["INTAKE-001"], "Meridian County",
    "the answer should be in the PUT body");
  assert.ok("skipped" in sent, "the PUT body should carry the skipped map");
  win.close();
});

test("storage: falls back to memory when the backend is unreachable", async () => {
  const dom = await bootApp((win) => {
    win.fetch = () => Promise.reject(new Error("connection refused"));
  });
  const win = dom.window;
  await wait(60);

  assert.match(byId(win, "records-note").textContent, /Not connected to the records database/,
    "records note should say it is not connected");
  // And the app must still work rather than erroring out.
  byId(win, "btn-new-client").click();
  await wait(30);
  assert.ok(byId(win, "screen-questionnaire").classList.contains("active"),
    "questionnaire should still start when the backend is down");
  win.close();
});

// A stateful fake of the insight ORDS module -- not just
// canned responses, but an actual small in-memory store behind the same
// four routes, including the same approval-workflow rule the real
// pkg_insight_answers.record_answer enforces (V9): the first value written
// for a question saves directly; changing an already-set value does not
// overwrite it and counts toward pendingApproval instead. This is what
// makes the round-trip test below a genuine round-trip through something
// that behaves like the backend, not just an echo.
function statefulFakeOrds() {
  const clients = new Map(); // id -> { companyName, answers, skipped, createdAt, updatedAt }
  let nextNoteId = 1;
  function fetchImpl(url, opts) {
    const method = (opts && opts.method) || "GET";
    const path = String(url).replace("http://localhost", "").replace(API, "");
    const now = new Date().toISOString();

    if (method === "GET" && path === "/clients") {
      const list = Array.from(clients.entries())
        .map(([id, c]) => ({ id, companyName: c.companyName, primaryContact: c.primaryContact, updatedAt: c.updatedAt }));
      return respond(200, list);
    }

    // /clients/:id/notes -- mirrors the three handlers in
    // sql/INSIGHT_06_ords_module.sql, including their archive-not-delete
    // behaviour, so a test that passes here would pass against Oracle.
    const notesMatch = path.match(/^\/clients\/([^/]+)\/notes$/);
    if (notesMatch) {
      const nid = decodeURIComponent(notesMatch[1]);
      const client = clients.get(nid);
      if (!client) return respond(404, { ok: false, error: "client not found" });
      client.notes = client.notes || [];
      if (method === "GET") {
        return respond(200, client.notes.filter((x) => !x.archived));
      }
      if (method === "POST") {
        const body = JSON.parse(opts.body);
        if (!body.text) return respond(400, { ok: false, error: "note text is required" });
        const note = {
          id: nextNoteId++, text: body.text, source: body.source || "CONSULTANT",
          createdBy: "insight-app", createdAt: now, updatedAt: now, archived: false,
        };
        client.notes.push(note);
        client.updatedAt = now;
        return respond(201, { ok: true, noteId: note.id });
      }
      if (method === "PUT") {
        const body = JSON.parse(opts.body);
        const note = client.notes.find((x) => String(x.id) === String(body.noteId));
        if (!note) return respond(404, { ok: false, error: "note not found for this client" });
        if (body.text !== undefined) note.text = body.text;
        if (body.archived !== undefined) note.archived = !!body.archived;
        note.updatedAt = now;
        client.updatedAt = now;
        return respond(200, { ok: true, noteId: note.id });
      }
      return respond(404, { ok: false, error: "no route" });
    }

    const idMatch = path.match(/^\/clients\/([^/]+)$/);
    if (!idMatch) return respond(404, { ok: false, error: "no route" });
    const id = decodeURIComponent(idMatch[1]);

    if (method === "GET") {
      const c = clients.get(id);
      if (!c) return respond(404, { ok: false, error: "client not found" });
      return respond(200, { id, companyName: c.companyName, primaryContact: c.primaryContact,
        notes: (c.notes || []).filter((x) => !x.archived),
        answers: c.answers, skipped: c.skipped, createdAt: c.createdAt, updatedAt: c.updatedAt });
    }
    if (method === "PUT") {
      const body = JSON.parse(opts.body);
      const existing = clients.get(id) || { companyName: "Unnamed client", answers: {}, skipped: {}, createdAt: now };
      let saved = 0, pendingApproval = 0;
      const answers = Object.assign({}, existing.answers);
      Object.keys(body.answers || {}).forEach((qid) => {
        const newVal = body.answers[qid];
        const hadValue = existing.answers[qid] !== undefined && existing.answers[qid] !== null && existing.answers[qid] !== "";
        if (!hadValue) {
          answers[qid] = newVal; saved++;
        } else if (existing.answers[qid] === newVal) {
          // unchanged -- neither saved nor pending
        } else {
          pendingApproval++; // matches record_answer: edit to an existing answer does not overwrite
        }
      });
      // Presence decides, exactly as the handler does: a PUT carrying only
      // profile fields must not blank the answers, and one carrying only
      // answers must not blank the profile.
      clients.set(id, {
        companyName: Object.prototype.hasOwnProperty.call(body, "companyName")
          ? body.companyName : existing.companyName,
        primaryContact: Object.prototype.hasOwnProperty.call(body, "primaryContact")
          ? body.primaryContact : existing.primaryContact,
        notes: existing.notes || [],
        answers, skipped: body.skipped || existing.skipped,
        createdAt: existing.createdAt, updatedAt: now,
      });
      return respond(200, { ok: true, saved, pendingApproval, unknownQuestions: 0 });
    }
    if (method === "DELETE") {
      const existed = clients.delete(id);
      return respond(existed ? 200 : 404, existed ? { ok: true, archived: id } : { ok: false, error: "client not found" });
    }
    return respond(404, { ok: false, error: "no route" });
  }
  function respond(status, payload) {
    return Promise.resolve({
      ok: status >= 200 && status < 300, status,
      json: () => Promise.resolve(payload),
      text: () => Promise.resolve(JSON.stringify(payload)),
    });
  }
  return { fetchImpl, clients };
}

test("round trip: a client created in one session is retrievable from a fresh session via GET", async () => {
  const server = statefulFakeOrds();
  const dom1 = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win1 = dom1.window;
  await wait(60);
  byId(win1, "btn-new-client").click();
  await wait(30);
  fillText(win1, "Meridian County Government, Meridian");
  await clickNext(win1);
  await wait(60);
  win1.close();

  assert.equal(server.clients.size, 1, "sanity: the fake backend actually stored one client");

  // A second, completely separate window/session -- nothing shared with
  // dom1 except the fake server's Map, standing in for Oracle.
  const dom2 = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win2 = dom2.window;
  await wait(60);
  byId(win2, "nav-clients").click();
  await wait(30);
  assert.match(byId(win2, "records-list-area").textContent, /Meridian County Government/,
    "the second session's Records screen should list the client the first session created");

  const openBtn = byId(win2, "records-list-area").querySelector("[data-open]");
  openBtn.click();
  await wait(30);
  assert.ok(byId(win2, "screen-questionnaire").classList.contains("active"));
  const ta = win2.document.querySelector(".q-input, textarea");
  // resumed at the first unanswered question, not INTAKE-001 -- confirm via
  // the underlying stored answer instead of what's on screen right now
  const stored = server.clients.get(Array.from(server.clients.keys())[0]);
  assert.equal(stored.answers["INTAKE-001"], "Meridian County Government, Meridian");
  win2.close();
});

test("delete calls the DELETE endpoint and the client no longer lists", async () => {
  const server = statefulFakeOrds();
  server.clients.set("c-del", { companyName: "Test Co", answers: {}, skipped: {}, createdAt: "2026-08-19T10:00:00Z", updatedAt: "2026-08-19T10:00:00Z" });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "nav-clients").click();
  await wait(30);
  win.confirm = () => true; // jsdom's window.confirm is a no-op returning undefined by default
  byId(win, "records-list-area").querySelector("[data-delete]").click();
  await wait(30);

  assert.equal(server.clients.size, 0, "the fake backend should have received the DELETE");
  assert.match(byId(win, "records-list-area").textContent, /No clients yet/);
  win.close();
});

test("editing an already-answered question surfaces the pending-approval count instead of silently doing nothing", async () => {
  const server = statefulFakeOrds();
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Original Answer");
  await clickNext(win); // first answer -- saves directly, no approval needed
  await wait(60);
  assert.equal(byId(win, "pending-approval-banner").classList.contains("show"), false,
    "a first-time answer must not trigger the pending-approval notice");

  byId(win, "q-back").click();
  await wait(30);
  fillText(win, "Changed Answer"); // editing a value that was already saved
  await clickNext(win);
  await wait(60);

  assert.equal(byId(win, "pending-approval-banner").classList.contains("show"), true,
    "editing an already-answered question should surface the pending-approval notice, not save silently");
  assert.match(byId(win, "pending-approval-banner-text").textContent, /1 edit is pending review/);
  win.close();
});

// ---------------------------------------------------------------------------
// Typed answers. Before these, every question was a free-text box, so
// "How many legal entities does the client operate?" accepted prose.
// ---------------------------------------------------------------------------

// Walks forward from the current question until the prompt matches, filling
// each one it passes with a value that question's own type accepts.
async function advanceTo(win, pattern) {
  for (let i = 0; i < 40; i++) {
    if (pattern.test(byId(win, "q-text").textContent)) return;
    const yn = win.document.querySelectorAll(".yn-btn");
    if (yn.length) clickYn(win, "Yes");
    else fillValid(win, "placeholder answer " + i);
    await clickNext(win);
  }
  throw new Error("advanceTo: never reached " + pattern);
}

test("typed answer: a 'how many' question rejects prose and accepts a number", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await advanceTo(win, /How many legal entities/i);

  const field = win.document.querySelector(".q-input");
  assert.equal(field.tagName, "INPUT", "a numeric question should render a single-line input");
  assert.equal(field.getAttribute("inputmode"), "numeric");

  const at = progressLabel(win);
  fillText(win, "dsarha gavrb"); // the exact value that used to be accepted
  await clickNext(win);
  assert.match(byId(win, "q-field-error").textContent, /number/i,
    "prose in a numeric field must be rejected");
  assert.equal(progressLabel(win), at, "must not advance on an invalid number");

  fillText(win, "14");
  await clickNext(win);
  assert.notEqual(progressLabel(win), at, "a valid number should advance");
});

test("typed answer: the email question rejects a non-address", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await advanceTo(win, /email address/i);

  assert.equal(win.document.querySelector(".q-input").getAttribute("inputmode"), "email");
  const at = progressLabel(win);
  fillText(win, "greenlantern");
  await clickNext(win);
  assert.match(byId(win, "q-field-error").textContent, /email/i);
  assert.equal(progressLabel(win), at);

  fillText(win, "greenlantern@latern.com");
  await clickNext(win);
  assert.notEqual(progressLabel(win), at);
});

test("typed answer: an optional typed field may be left blank but not filled with junk", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await advanceTo(win, /phone number/i);

  const at = progressLabel(win);
  // Junk is rejected even though the question is optional -- the rule is
  // about the format of what was typed, not about whether it was required.
  fillText(win, "call me maybe");
  await clickNext(win);
  assert.match(byId(win, "q-field-error").textContent, /phone/i);
  assert.equal(progressLabel(win), at);

  fillText(win, ""); // blank is fine on an optional question
  await clickNext(win);
  assert.notEqual(progressLabel(win), at, "an optional typed field should accept blank");
});

test("typed answer: free-text questions still take prose", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  const field = win.document.querySelector(".q-input");
  assert.equal(field.tagName, "TEXTAREA", "INTAKE-001 is free text");
  fillText(win, "Meridian County Government");
  await clickNext(win);
  assert.equal(byId(win, "q-field-error").textContent.trim(), "");
});

// ---------------------------------------------------------------------------
// Per-client scoping. Questionnaire, AI Follow-Up and Summary all render
// whatever client is loaded into ALL_QUESTIONS, so reaching them without a
// client showed the previously-opened client's data.
// ---------------------------------------------------------------------------

test("scoping: Summary cannot be opened without a client", async () => {
  const dom = await bootApp();
  const win = dom.window;
  assert.ok(byId(win, "screen-records").classList.contains("active"));
  const crumb = win.document.querySelector('.crumb[data-crumb="summary"]');
  assert.ok(crumb.classList.contains("disabled"), "crumbs should read as unavailable on the client list");
  crumb.click();
  await wait(60);
  assert.equal(byId(win, "screen-summary").classList.contains("active"), false,
    "Summary is a per-client view, not global navigation");
});

test("scoping: leaving a client to the list drops the active client", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(20);
  fillText(win, "Meridian County");
  await clickNext(win);
  assert.equal(win.document.querySelector('.crumb[data-crumb="summary"]').classList.contains("disabled"), false,
    "crumbs are available while a client is open");

  byId(win, "nav-clients").click();
  await wait(60);
  assert.equal(byId(win, "client-context-name").textContent, "",
    "the client context chip should clear");
  assert.ok(win.document.querySelector('.crumb[data-crumb="summary"]').classList.contains("disabled"),
    "and the per-client views should become unavailable again");
});

// ---------------------------------------------------------------------------
// "Not known yet" -- a deliberate answer, distinct from Skip. Skipped means
// come back to it and the chat chases it; unknown means it was considered
// and settled as not yet knowable, so it should stop being chased.
// ---------------------------------------------------------------------------

test("not-known: satisfies a required question without inventing a value", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(20);
  const at = progressLabel(win);
  // INTAKE-001 is required; Next alone is blocked.
  await clickNext(win);
  assert.match(byId(win, "q-field-error").textContent, /required/i);
  assert.equal(progressLabel(win), at);

  byId(win, "q-unknown").click();
  await wait(30);
  assert.notEqual(progressLabel(win), at, "'Not known yet' should advance a required question");
});

test("not-known: is not chased as a gap, unlike a skip", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win);      // GL-only deck
  // Both on Phase 3 questions: the chat does not chase Phase 1 any more,
  // since the client information sheet owns those.
  byId(win, "q-unknown").click();   // first GL question -> not known
  await wait(30);
  await clickSkip(win);             // second GL question -> skipped
  await wait(30);
  await finishRemainingQuestions(win);
  await wait(1400);
  const opening = byId(win, "chat-body").textContent;
  assert.match(opening, /1 required question/,
    "only the skipped question should be an open gap -- the unknown one is settled");
});

test("not-known: typing a value clears it", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(20);
  byId(win, "q-unknown").click();
  await wait(30);
  // Back to the question we just marked.
  byId(win, "q-back").click();
  await wait(30);
  assert.match(byId(win, "q-unknown").textContent, /Marked not known/);
  fillText(win, "Meridian County Government");
  await wait(10);
  assert.match(byId(win, "q-unknown").textContent, /Not known yet/,
    "entering a value should clear the not-known state");
});

test("not-known: travels in the saved record as its own map", async () => {
  const calls = [];
  const dom = await bootApp((win) => {
    win.fetch = (url, opts) => {
      calls.push({ method: (opts && opts.method) || "GET", url, body: opts && opts.body });
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve([]),
        text: () => Promise.resolve("[]"),
      });
    };
  });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(20);
  byId(win, "q-unknown").click();
  await wait(80);

  const put = calls.filter((c) => c.method === "PUT").pop();
  assert.ok(put, "marking not-known should save");
  const sent = JSON.parse(put.body);
  assert.ok(sent.unknown && sent.unknown["INTAKE-001"] === true,
    "the unknown map should carry the question");
  assert.equal(sent.answers["INTAKE-001"], null, "and its value must be null");
  win.close();
});

// ---------------------------------------------------------------------------
// Client information sheet: company basics and additional information.
// ---------------------------------------------------------------------------
async function openInfoSheet(win, id) {
  byId(win, "nav-clients").click();
  await wait(40);
  const btn = byId(win, "records-list-area").querySelector(
    id ? `[data-info="${id}"]` : "[data-info]");
  assert.ok(btn, "the client row should offer a client-information button");
  btn.click();
  await wait(40);
  return btn;
}

function seedClient(server, id, extra) {
  server.clients.set(id, Object.assign({
    companyName: "Meridian County", primaryContact: "R. Alvarez",
    answers: { "INTAKE-001": "Meridian County Government" }, skipped: {}, notes: [],
    createdAt: "2026-08-19T10:00:00Z", updatedAt: "2026-08-19T10:00:00Z",
  }, extra || {}));
}

// Finds the editable row for a question id inside the sheet.
function qfRow(win, qid) {
  return byId(win, "client-info-fields").querySelector(`.qf[data-qid="${qid}"]`);
}
function qfField(win, qid) {
  const row = qfRow(win, qid);
  return row && row.querySelector("input, textarea");
}
function typeInto(win, qid, value) {
  const field = qfField(win, qid);
  assert.ok(field, `expected an editable field for ${qid}`);
  field.value = value;
  field.dispatchEvent(new win.Event("input"));
}

test("client info: the sheet opens populated with the saved name and answers", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  assert.ok(byId(win, "client-info").classList.contains("show"), "sheet should be visible");
  assert.equal(byId(win, "client-info-name").value, "Meridian County");
  assert.equal(qfField(win, "INTAKE-001").value, "Meridian County Government",
    "each question should render with its stored answer");
  win.close();
});

test("client info: every in-scope question is editable, out-of-scope modules are not shown", async () => {
  const server = statefulFakeOrds();
  // GL only: AP/AR/FA/CM declined, so their Phase 3 questions are out of scope.
  seedClient(server, "c-scope", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-scope");

  const rows = byId(win, "client-info-fields").querySelectorAll(".qf");
  assert.equal(rows.length, GL_ONLY_DECK,
    "the sheet should show exactly the client's own scope");
  assert.ok(qfRow(win, "GL-001"), "GL is always in scope");
  assert.equal(qfRow(win, "AP-001"), null, "a declined module's questions must not appear");
  win.close();
});

test("client info: saving sends only the answers that were touched", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info");
  const calls = [];
  const dom = await bootApp((win) => {
    win.fetch = (url, opts) => {
      calls.push({ method: (opts && opts.method) || "GET", url: String(url), body: opts && opts.body });
      return server.fetchImpl(url, opts);
    };
  });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  byId(win, "client-info-name").value = "Meridian County Water District";
  typeInto(win, "INTAKE-002", "D. Okafor");
  byId(win, "client-info-save").click();
  await wait(80);

  const put = calls.filter((c) => c.method === "PUT" && c.url.endsWith("/clients/c-info")).pop();
  assert.ok(put, "should PUT the client");
  const sent = JSON.parse(put.body);
  assert.equal(sent.companyName, "Meridian County Water District");
  assert.deepEqual(Object.keys(sent.answers), ["INTAKE-002"],
    "only the edited answer should be sent -- resending the rest would compare all of them");
  // An edit made deliberately on this screen is consultant work, not a
  // value captured mid sales call.
  assert.equal(sent.source, "CONSULTANT");
  // The roster's contact line follows the contact-name answer rather than
  // being typed twice.
  assert.equal(sent.primaryContact, "D. Okafor");

  const stored = server.clients.get("c-info");
  assert.equal(stored.companyName, "Meridian County Water District");
  assert.equal(stored.answers["INTAKE-002"], "D. Okafor");
  assert.equal(stored.answers["INTAKE-001"], "Meridian County Government",
    "untouched answers must survive the save");
  assert.match(byId(win, "client-info-status").textContent, /saved/i);
  win.close();
});

test("client info: an answer that fails its format is refused before anything is sent", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info", { answers: { "QUAL-GL": "Yes" } });
  const calls = [];
  const dom = await bootApp((win) => {
    win.fetch = (url, opts) => {
      calls.push({ method: (opts && opts.method) || "GET", url: String(url) });
      return server.fetchImpl(url, opts);
    };
  });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  const before = calls.filter((c) => c.method === "PUT").length;
  typeInto(win, "INTAKE-002C", "not-an-address");   // the contact email question
  byId(win, "client-info-save").click();
  await wait(60);

  assert.equal(calls.filter((c) => c.method === "PUT").length, before,
    "a badly formatted answer must not reach the database");
  assert.match(qfRow(win, "INTAKE-002C").querySelector(".qf-error").textContent, /email/i);
  assert.match(byId(win, "client-info-status").textContent, /needs fixing/i);
  win.close();
});

test("client info: an unanswered required question is flagged as still needed", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info", {
    answers: { "QUAL-GL": "Yes", "INTAKE-001": "Meridian County Government" },
    skipped: { "INTAKE-002C": true },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  const flag = qfRow(win, "INTAKE-002C").querySelector(".qf-flag");
  assert.ok(flag, "a blank required question should carry a flag");
  assert.match(flag.textContent, /Still needed/);
  // and one that was answered should not
  assert.equal(qfRow(win, "INTAKE-001").querySelector(".qf-flag"), null);
  win.close();
});

test("client info: an empty company name is rejected before any request", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info");
  const calls = [];
  const dom = await bootApp((win) => {
    win.fetch = (url, opts) => {
      calls.push({ method: (opts && opts.method) || "GET", url: String(url) });
      return server.fetchImpl(url, opts);
    };
  });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  const before = calls.filter((c) => c.method === "PUT").length;
  byId(win, "client-info-name").value = "   ";
  byId(win, "client-info-save").click();
  await wait(40);

  assert.equal(calls.filter((c) => c.method === "PUT").length, before,
    "nothing should be sent for an empty name");
  assert.match(byId(win, "client-info-status").textContent, /required/i);
  win.close();
});

test("client info: adding a note POSTs it and it renders in the list", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  assert.match(byId(win, "client-info-notes").textContent, /Nothing recorded yet/);
  byId(win, "client-info-new-note").value = "Board meets quarterly; approvals wait on that cycle.";
  byId(win, "client-info-add-note").click();
  await wait(60);

  const stored = server.clients.get("c-info");
  assert.equal(stored.notes.length, 1);
  assert.equal(stored.notes[0].source, "CONSULTANT", "a typed note is not attributed to the assistant");
  assert.match(byId(win, "client-info-notes").textContent, /Board meets quarterly/);
  assert.equal(byId(win, "client-info-new-note").value, "", "the box should clear after adding");
  win.close();
});

test("client info: an empty note is refused", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  byId(win, "client-info-new-note").value = "   ";
  byId(win, "client-info-add-note").click();
  await wait(40);
  assert.equal((server.clients.get("c-info").notes || []).length, 0);
  win.close();
});

test("client info: removing a note archives the row rather than deleting it", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info", {
    notes: [{ id: 7, text: "Uses a shared services centre in Ohio.", source: "CONSULTANT",
              createdAt: "2026-08-20T09:00:00Z", updatedAt: "2026-08-20T09:00:00Z", archived: false }],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  win.confirm = () => true;
  await openInfoSheet(win, "c-info");
  assert.match(byId(win, "client-info-notes").textContent, /shared services centre/);

  byId(win, "client-info-notes").querySelector("[data-archive-note]").click();
  await wait(60);

  const notes = server.clients.get("c-info").notes;
  assert.equal(notes.length, 1, "the row is kept");
  assert.equal(notes[0].archived, true, "and marked archived");
  assert.match(byId(win, "client-info-notes").textContent, /Nothing recorded yet/);
  win.close();
});

test("client info: editing a note sends the new text and keeps the same note", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info", {
    notes: [{ id: 9, text: "Fiscal year ends in June.", source: "CONSULTANT",
              createdAt: "2026-08-20T09:00:00Z", updatedAt: "2026-08-20T09:00:00Z", archived: false }],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  byId(win, "client-info-notes").querySelector("[data-edit-note]").click();
  await wait(20);
  const box = byId(win, "client-info-notes").querySelector("textarea");
  assert.ok(box, "editing should swap the note text for a box");
  assert.equal(box.value, "Fiscal year ends in June.");
  box.value = "Fiscal year ends in September.";
  Array.from(byId(win, "client-info-notes").querySelectorAll("button"))
    .find((b) => b.textContent === "Save note").click();
  await wait(60);

  const notes = server.clients.get("c-info").notes;
  assert.equal(notes.length, 1, "editing must not create a second note");
  assert.equal(notes[0].text, "Fiscal year ends in September.");
  win.close();
});

test("client info: a note from the assistant is labelled as such", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-info", {
    notes: [{ id: 11, text: "Migrating from EBS 12.2 next year.", source: "AI_ASSIST",
              createdAt: "2026-08-20T09:00:00Z", updatedAt: "2026-08-20T09:00:00Z", archived: false }],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-info");

  const tag = byId(win, "client-info-notes").querySelector(".note-tag");
  assert.equal(tag.textContent, "Assistant");
  assert.ok(tag.classList.contains("ai"), "and is visually distinguished from a typed note");
  win.close();
});

test("client info: works with no backend, keeping notes on the in-memory record", async () => {
  const dom = await bootApp((win) => {
    win.fetch = () => Promise.reject(new Error("offline"));
  });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Harbor Freight Logistics, Harbor");
  await clickNext(win);
  await wait(40);

  await openInfoSheet(win, null);
  assert.ok(byId(win, "client-info").classList.contains("show"));
  byId(win, "client-info-new-note").value = "No ERP in place; spreadsheets only.";
  byId(win, "client-info-add-note").click();
  await wait(40);
  assert.match(byId(win, "client-info-notes").textContent, /spreadsheets only/,
    "the memory store should hold notes on the record");
  win.close();
});

test("client info: a name set in the sheet is not overwritten by INTAKE-001 on the next save", async () => {
  const server = statefulFakeOrds();
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Meridian County Government, Meridian");
  await clickNext(win);
  await wait(60);
  const id = Array.from(server.clients.keys())[0];

  await openInfoSheet(win, id);
  byId(win, "client-info-name").value = "Meridian County Water District";
  byId(win, "client-info-save").click();
  await wait(60);
  byId(win, "client-info-close").click();
  await wait(40);

  // Back into the questionnaire, answer another question, forcing a save.
  byId(win, "records-list-area").querySelector(`[data-open="${id}"]`).click();
  await wait(40);
  fillValid(win, "R. Alvarez");
  await clickNext(win);
  await wait(60);

  assert.equal(server.clients.get(id).companyName, "Meridian County Water District",
    "the deliberately set name must survive a questionnaire save");
  win.close();
});

// ---------------------------------------------------------------------------
// AI Follow-Up chat: answers have to reach the record, and have to obey the
// same format rules the questionnaire enforces.
// ---------------------------------------------------------------------------

// Walks the whole deck, skipping exactly one numeric question outside
// Phase 1, so the chat later has one gap and that gap is a typed one.
// Phase 1 is excluded deliberately: the chat no longer chases it, so a
// skipped intake question would produce no gap at all.
async function finishDeckSkippingOneNumeric(win) {
  let skipped = false;
  for (let i = 0; i < 120; i++) {
    if (byId(win, "screen-chat").classList.contains("active")) break;
    const el = win.document.querySelector(".q-input");
    const intake = /Client Intake/.test(byId(win, "q-eyebrow").textContent);
    if (!skipped && !intake && el && el.getAttribute("inputmode") === "numeric") {
      skipped = true;
      await clickSkip(win);
      continue;
    }
    const yn = win.document.querySelectorAll(".yn-btn");
    if (yn.length) clickYn(win, "Yes"); else fillValid(win, "answer " + i);
    await clickNext(win);
  }
  assert.ok(skipped, "expected a numeric question outside Phase 1");
}

test("chat: each answer is saved as it is given, not only when the chat ends", async () => {
  const server = statefulFakeOrds();
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win);
  await clickSkip(win);                  // one gap: the first GL question
  await finishRemainingQuestions(win);
  await wait(1300);
  assert.ok(byId(win, "screen-chat").classList.contains("active"));

  const id = Array.from(server.clients.keys())[0];
  byId(win, "chat-input").value = "Two ledgers, both in USD.";
  byId(win, "chat-send").click();
  await wait(200);   // deliberately shorter than the 600ms typing delay:
                     // the save must not wait for the chat to finish

  const stored = server.clients.get(id).answers;
  const landed = Object.keys(stored).some((k) => stored[k] === "Two ledgers, both in USD.");
  assert.ok(landed, "the chat answer should already be in the record");
  win.close();
});

test("chat: a gap answer lands as a real answer, not a pending change request", async () => {
  const server = statefulFakeOrds();
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win);
  await clickSkip(win);
  await finishRemainingQuestions(win);
  await wait(1300);

  const id = Array.from(server.clients.keys())[0];
  const before = server.clients.get(id).answers;
  const gapId = Object.keys(before).find((k) => before[k] === null || before[k] === undefined || before[k] === "");

  byId(win, "chat-input").value = "Filled in during follow-up.";
  byId(win, "chat-send").click();
  await wait(300);

  // Skipping stores a row with no value. The record must now hold the value
  // itself -- the failure this guards against is the answer going to the
  // approval queue instead, where it is not an answer at all.
  const after = server.clients.get(id).answers;
  assert.equal(after[gapId], "Filled in during follow-up.",
    "filling a blank answer must apply directly, not queue for approval");
  win.close();
});

test("chat: an answer that breaks the question's format is refused and re-asked", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  // Every module in scope, so the numeric questions in AP/AR/FA/CM/GL are
  // all on the deck and one of them can be left as the gap.
  await answerQualifiers(win, { AP: "Yes", AR: "Yes", FA: "Yes", CM: "Yes", MULTI: "Yes" });
  await finishDeckSkippingOneNumeric(win);
  await wait(1300);
  assert.ok(byId(win, "screen-chat").classList.contains("active"));

  byId(win, "chat-input").value = "quite a few";
  byId(win, "chat-send").click();
  await wait(700);

  const body = byId(win, "chat-body").textContent;
  assert.match(body, /digits only/, "the reply should carry the question's own format guidance");
  assert.doesNotMatch(body, /covers the required gaps/,
    "and must not treat the gap as filled");

  // The same question, answered properly, advances.
  byId(win, "chat-input").value = "14";
  byId(win, "chat-send").click();
  await wait(900);
  assert.match(byId(win, "chat-body").textContent, /covers the required gaps/);
  win.close();
});

test("chat: a yes/no gap still accepts a conversational yes", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  // Skip QUAL-AP rather than answering it, making a yn question the gap.
  await clickNext(win);          // QUAL-GL, locked
  await clickSkip(win);          // QUAL-AP skipped
  clickYn(win, "No"); await clickNext(win);   // AR
  clickYn(win, "No"); await clickNext(win);   // FA
  clickYn(win, "No"); await clickNext(win);   // CM
  clickYn(win, "No"); await clickNext(win);   // MULTI
  await finishRemainingQuestions(win);
  await wait(1300);

  byId(win, "chat-input").value = "yes, they do";
  byId(win, "chat-send").click();
  await wait(900);
  assert.match(byId(win, "chat-body").textContent, /covers the required gaps|still blank/,
    "a conversational yes should be accepted, not bounced");
  win.close();
});

test("client info: the follow-up chat no longer chases client-identification questions", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  // Skip every Phase 1 question: the sheet owns those now.
  for (let i = 0; i < INTAKE_COUNT; i++) await clickSkip(win);
  await answerQualifiers(win);
  await finishRemainingQuestions(win);
  await wait(1300);

  const chatText = byId(win, "chat-body").textContent;
  assert.match(chatText, /no gaps to fill in|All caught up/,
    "skipped intake questions must not be raised in the chat");
  assert.doesNotMatch(chatText, /primary contact/i);
  win.close();
});

test("client info: skipped intake questions still show in the sheet as outstanding", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-out", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
    skipped: { "INTAKE-002B": true, "INTAKE-002C": true, "INTAKE-002D": true },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-out");

  // Not chased in the chat, but not lost either -- the sheet is where they
  // are now visible and fixable.
  ["INTAKE-002B", "INTAKE-002C"].forEach((qid) => {
    const flag = qfRow(win, qid).querySelector(".qf-flag");
    assert.ok(flag && /Still needed/.test(flag.textContent), qid + " should read as outstanding");
  });
  win.close();
});

test("client info: an edit to an answer that already has a value reports as pending review", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-pend", { answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-pend");

  typeInto(win, "INTAKE-003", "CFO, Controller and IT Director");
  byId(win, "client-info-save").click();
  await wait(80);

  // The fake backend mirrors record_answer: changing a value that exists
  // raises a change request instead of overwriting.
  assert.match(byId(win, "client-info-status").textContent, /pending review/i,
    "the sheet must not claim an edit is saved while it is queued");
  win.close();
});

test("client info: filling a blank answer applies straight away", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-fill", { answers: { "QUAL-GL": "Yes" }, skipped: { "INTAKE-002B": true } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-fill");

  typeInto(win, "INTAKE-002B", "Director of Finance");
  byId(win, "client-info-save").click();
  await wait(80);

  assert.equal(server.clients.get("c-fill").answers["INTAKE-002B"], "Director of Finance");
  assert.doesNotMatch(byId(win, "client-info-status").textContent, /pending/i,
    "filling a blank is not an edit and must not queue");
  win.close();
});

test("client info: a yes/no question edits through its buttons", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-yn", { answers: { "QUAL-GL": "Yes", "QUAL-AP": "No" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-yn");

  const row = qfRow(win, "QUAL-AP");
  const yes = Array.from(row.querySelectorAll(".qf-yn button")).find((b) => b.textContent === "Yes");
  yes.click();
  byId(win, "client-info-save").click();
  await wait(80);

  const sent = server.clients.get("c-yn").answers;
  assert.ok(sent["QUAL-AP"] === "Yes" || byId(win, "client-info-status").textContent.match(/pending/i),
    "the qualifier should either flip or be queued, not be ignored");
  win.close();
});

test("client info: with no backend, editing an answer keeps the rest of the record", async () => {
  const dom = await bootApp((win) => { win.fetch = () => Promise.reject(new Error("offline")); });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Harbor Freight Logistics, Harbor");
  await clickNext(win);
  fillValid(win, "R. Alvarez");
  await clickNext(win);
  await wait(40);

  await openInfoSheet(win, null);
  typeInto(win, "INTAKE-002", "D. Okafor");
  byId(win, "client-info-save").click();
  await wait(60);

  assert.equal(qfField(win, "INTAKE-002").value, "D. Okafor");
  assert.equal(qfField(win, "INTAKE-001").value, "Harbor Freight Logistics, Harbor",
    "the in-memory store must merge the edit, not replace the record with it");
  win.close();
});
