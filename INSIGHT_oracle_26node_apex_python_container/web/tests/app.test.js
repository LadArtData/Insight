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
//
// The placeholder is a full sentence on purpose. Two-word stubs like
// "answer 3" now trip the thin-answer warning, which is the point of that
// check -- so a helper that used them would spend its life clicking Next
// twice and hiding the behaviour it was meant to exercise.
async function fillIntake(win) {
  for (let i = 0; i < INTAKE_COUNT; i++) {
    fillValid(win, "A considered answer for intake question " + i + ".");
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
    else fillValid(win, "A considered answer for this discovery question.");
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

test("quality check: a bracket-containing answer is refused, not merely warned", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "[piuo8ytru");
  byId(win, "q-next").click();
  await wait(30);
  // Stray characters could not be a good-faith answer from anyone, so this
  // is refused outright rather than warned about. Compare the test above:
  // "ewdrefvebrn" is only suspicious, and a person gets to overrule that.
  assert.match(byId(win, "q-field-error").textContent, /doesn't look like an answer/i);
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
  await fillIntake(win); // full sentences, the shape a real answer takes -- none should ever warn
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

    // /clients/:id/changes -- mirrors the review handlers. Only AI_ASSIST
    // proposals ever land here after V25.
    const chgMatch = path.match(/^\/clients\/([^/]+)\/changes$/);
    if (chgMatch) {
      const cid = decodeURIComponent(chgMatch[1]);
      const client = clients.get(cid);
      if (!client) return respond(404, { ok: false, error: "client not found" });
      client.changes = client.changes || [];
      if (method === "GET") return respond(200, client.changes.filter((c) => c.status === "PENDING"));
      if (method === "PUT") {
        const body = JSON.parse(opts.body);
        if (!["approve", "reject"].includes(body.decision)) {
          return respond(400, { ok: false, error: "decision must be approve or reject" });
        }
        const targets = client.changes.filter((c) => c.status === "PENDING" &&
          (body.requestId === undefined || String(c.id) === String(body.requestId)));
        if (!targets.length) return respond(404, { ok: false, error: "nothing pending to review" });
        targets.forEach((c) => {
          if (body.decision === "approve") {
            client.answers[c.questionId] = c.proposedValue;
            c.status = "APPROVED";
          } else {
            c.status = "REJECTED";
          }
        });
        client.updatedAt = now;
        return respond(200, { ok: true, [body.decision + "d"]: targets.length });
      }
      return respond(404, { ok: false, error: "no route" });
    }

    // /clients/:id/updates -- append-only, exactly like the real handler:
    // there is no PUT, because an update is a record of something that
    // happened.
    const updMatch = path.match(/^\/clients\/([^/]+)\/updates$/);
    if (updMatch) {
      const uid = decodeURIComponent(updMatch[1]);
      const client = clients.get(uid);
      if (!client) return respond(404, { ok: false, error: "client not found" });
      client.configUpdates = client.configUpdates || [];
      if (method === "GET") return respond(200, client.configUpdates);
      if (method === "POST") {
        const body = JSON.parse(opts.body);
        if (!body.summary) {
          return respond(400, { ok: false, error: "a summary of what changed is required" });
        }
        const entry = {
          id: nextNoteId++, summary: body.summary, requestedBy: "insight-app",
          answersChanged: body.answersChanged || 0, createdAt: now,
        };
        client.configUpdates.unshift(entry);
        client.updatedAt = now;
        return respond(201, { ok: true, updateId: entry.id });
      }
      return respond(404, { ok: false, error: "no route" });
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
        configUpdates: c.configUpdates || [],
        answers: c.answers, skipped: c.skipped, createdAt: c.createdAt, updatedAt: c.updatedAt });
    }
    if (method === "PUT") {
      const body = JSON.parse(opts.body);
      const existing = clients.get(id) || { companyName: "Unnamed client", answers: {}, skipped: {}, createdAt: now };
      let saved = 0, pendingApproval = 0;
      const answers = Object.assign({}, existing.answers);
      existing.changes = existing.changes || [];
      Object.keys(body.answers || {}).forEach((qid) => {
        const newVal = body.answers[qid];
        const hadValue = existing.answers[qid] !== undefined && existing.answers[qid] !== null && existing.answers[qid] !== "";
        if (!hadValue) {
          answers[qid] = newVal; saved++;
        } else if (existing.answers[qid] === newVal) {
          // unchanged -- neither saved nor pending
        } else if (body.source === "AI_ASSIST") {
          // V25: only the assistant's proposals wait for a person.
          existing.changes.push({
            id: nextNoteId++, questionId: qid, questionText: qid,
            previousValue: existing.answers[qid], proposedValue: newVal,
            submittedBy: "assistant", submittedAt: now, status: "PENDING",
          });
          pendingApproval++;
        } else {
          answers[qid] = newVal; saved++;
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
        configUpdates: existing.configUpdates || [],
        changes: existing.changes || [],
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

test("editing an already-answered question applies it, and says nothing about approval", async () => {
  // Was the reverse until V25. Gating a consultant's own edit protected
  // nothing -- there is no second reviewer -- while filling a queue nothing
  // could display, so a nearly-complete client accumulated a hundred and
  // thirty-three proposals and kept showing its first-pass answers. Only
  // the assistant's proposals wait now.
  const server = statefulFakeOrds();
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Original Answer");
  await clickNext(win);
  await wait(60);
  const id = Array.from(server.clients.keys())[0];

  byId(win, "q-back").click();
  await wait(30);
  fillText(win, "Changed Answer");
  await clickNext(win);
  await wait(60);

  assert.equal(server.clients.get(id).answers["INTAKE-001"], "Changed Answer",
    "a consultant's edit belongs on the record, not in a queue");
  assert.equal(byId(win, "pending-approval-banner").classList.contains("show"), false,
    "and there is nothing pending to announce");
  win.close();
});

test("editing an already-answered question still records what it replaced", async () => {
  // The audit trail is the reason the workflow existed. Dropping the
  // approval step must not drop that.
  const server = statefulFakeOrds();
  seedClient(server, "c-audit", { answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-audit");
  const sent = [];
  const original = win.fetch;
  win.fetch = (url, opts) => {
    if ((opts || {}).method === "PUT") sent.push(JSON.parse(opts.body));
    return original(url, opts);
  };

  typeInto(win, "INTAKE-003", "CFO, Controller and IT Director");
  byId(win, "client-info-save").click();
  await wait(100);

  // The front end's part of that contract: say who is making the change,
  // so the database can tell a consultant's edit from the assistant's.
  assert.equal(sent[0].source, "CONSULTANT");
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
  assert.ok(btn, "the client row should offer a client-file button");
  assert.equal(btn.textContent, "Client file", "labelled, not a glyph");
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
    if (yn.length) clickYn(win, "Yes");
    else fillValid(win, "A considered answer for question " + i + ".");
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

test("client info: the sheet still reports a queue honestly when there is one", async () => {
  // A consultant's edit applies after V25, so the only way to see this is
  // with something the assistant proposed. The sheet must never claim an
  // edit is saved while it is waiting for a person.
  const server = statefulFakeOrds();
  seedClient(server, "c-pend", { answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-pend");

  // Stand in for an assistant proposal by answering as one.
  await server.fetchImpl("/ords/admin/insight/clients/c-pend", {
    method: "PUT", body: JSON.stringify({
      companyName: "Meridian County", source: "AI_ASSIST",
      answers: { "INTAKE-003": "CFO, Controller, IT Director" } }),
  });
  await openInfoSheet(win, "c-pend");

  assert.equal(server.clients.get("c-pend").answers["INTAKE-003"], "CFO and Controller",
    "an assistant proposal must not reach the record on its own");
  assert.match(byId(win, "client-info-changes").textContent, /IT Director/,
    "and it must be visible, or it is indistinguishable from a lost answer");
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

// ---------------------------------------------------------------------------
// Answer quality: the reviewer decides when it can be reached, a local check
// decides when it cannot, and neither is ever allowed to be a dead end.
// ---------------------------------------------------------------------------

// Fake fetch that answers /api/review with a fixed verdict and everything
// else the way an absent backend would.
function reviewerFetch(verdict, calls) {
  return function (url, opts) {
    const u = String(url);
    if (u.includes("/api/review")) {
      if (calls) calls.push(JSON.parse(opts.body));
      if (verdict === "down") {
        return Promise.resolve({ ok: false, status: 502, json: () => Promise.resolve({}) });
      }
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve(verdict),
        text: () => Promise.resolve(JSON.stringify(verdict)),
      });
    }
    return Promise.reject(new Error("offline"));
  };
}

test("quality: keyboard mash is refused outright, with no override", async () => {
  const dom = await bootApp();          // no fetch at all -- local check only
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(20);
  const before = progressLabel(win);

  fillText(win, "asdfghjkl");
  await clickNext(win);
  await wait(40);
  assert.equal(progressLabel(win), before, "should not advance");
  // and clicking again must not let it through, unlike the thin-answer warning
  await clickNext(win);
  await wait(40);
  assert.equal(progressLabel(win), before, "a second click must not override a refusal");
  assert.match(byId(win, "q-field-error").textContent, /doesn't look like an answer/i);
  win.close();
});

test("quality: a refused answer still leaves Skip and Not known yet open", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(20);
  const before = progressLabel(win);

  fillText(win, "{{{{}}}}");
  await clickNext(win);
  await wait(40);
  assert.equal(progressLabel(win), before);

  // Refusing an answer must never trap someone with nothing they can do.
  await clickSkip(win);
  await wait(40);
  assert.notEqual(progressLabel(win), before, "Skip must still work");
  win.close();
});

test("quality: the reviewer's verdict wins over the local check", async () => {
  const sent = [];
  const dom = await bootApp((win) => {
    win.fetch = reviewerFetch({ verdict: "nonsense", reason: "That doesn't answer what was asked." }, sent);
  });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(20);
  const before = progressLabel(win);

  // Well-formed English that no pattern would ever catch.
  fillText(win, "Who cares about any of this");
  await clickNext(win);
  await wait(60);

  assert.equal(progressLabel(win), before, "the reviewer refused it, so it must not advance");
  assert.match(byId(win, "q-field-error").textContent, /That doesn't answer what was asked/);
  assert.equal(sent.length, 1, "one review call per attempt");
  assert.ok(sent[0].questionText && sent[0].answer, "the question and the answer are both sent");
  win.close();
});

test("quality: an 'unclear' verdict warns once and then proceeds", async () => {
  const dom = await bootApp((win) => {
    win.fetch = reviewerFetch({ verdict: "unclear", reason: "That's a bit vague." });
  });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(20);
  const before = progressLabel(win);

  fillText(win, "Meridian County Government, Meridian");
  await clickNext(win);
  await wait(60);
  assert.equal(progressLabel(win), before, "first click warns");
  assert.match(byId(win, "q-quality-warning").textContent, /a bit vague/i);

  await clickNext(win);
  await wait(60);
  assert.notEqual(progressLabel(win), before, "second click proceeds -- the person decides");
  win.close();
});

test("quality: a good answer passes straight through", async () => {
  const dom = await bootApp((win) => { win.fetch = reviewerFetch({ verdict: "ok", reason: "" }); });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(20);
  const before = progressLabel(win);

  fillText(win, "Meridian County Government, known informally as Meridian.");
  await clickNext(win);
  await wait(60);
  assert.notEqual(progressLabel(win), before);
  win.close();
});

test("quality: a reviewer that is down does not block the questionnaire", async () => {
  const dom = await bootApp((win) => { win.fetch = reviewerFetch("down"); });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(20);
  const before = progressLabel(win);

  // An outage in a quality check must not become an outage in the app.
  fillText(win, "Meridian County Government, Meridian");
  await clickNext(win);
  await wait(60);
  assert.notEqual(progressLabel(win), before, "a 502 from the reviewer must not stop anyone");
  win.close();
});

test("quality: the reviewer is asked once, then left alone while it is down", async () => {
  let reviewCalls = 0;
  const dom = await bootApp((win) => {
    win.fetch = (url, opts) => {
      if (String(url).includes("/api/review")) {
        reviewCalls += 1;
        return Promise.resolve({ ok: false, status: 502, json: () => Promise.resolve({}) });
      }
      return Promise.reject(new Error("offline"));
    };
  });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(20);

  for (let i = 0; i < 3; i++) {
    fillValid(win, "A considered answer for question " + i + ".");
    await clickNext(win);
    await wait(40);
  }
  // Making every Next wait on a service known to be down would be its own
  // kind of broken.
  assert.equal(reviewCalls, 1, "should stop asking after the first failure");
  win.close();
});

test("quality: the chat holds answers to the same bar", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win);
  await clickSkip(win);                // one gap, a GL text question
  await finishRemainingQuestions(win);
  await wait(1300);

  byId(win, "chat-input").value = "asdfghjkl";
  byId(win, "chat-send").click();
  await wait(900);

  const body = byId(win, "chat-body").textContent;
  assert.doesNotMatch(body, /covers the required gaps/,
    "nonsense in the chat must not count as filling the gap");
  win.close();
});

// ---------------------------------------------------------------------------
// Configuration updates: why a client's configuration was regenerated.
// ---------------------------------------------------------------------------

// jsdom has no download machinery and its Blob has no text(), so capture
// the JSON on its way into the Blob rather than trying to read it back out.
function captureDownloads(win) {
  const files = [];
  const OriginalBlob = win.Blob;
  win.Blob = function (parts, opts) {
    files.push(String(parts[0]));
    return new OriginalBlob(parts, opts);
  };
  win.URL.createObjectURL = () => "blob:mock";
  win.URL.revokeObjectURL = () => {};
  win.HTMLAnchorElement.prototype.click = function () {};
  return files;
}

test("config update: recording one requires saying what changed", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-cfg");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-cfg");

  byId(win, "client-info-regenerate").click();
  await wait(60);

  assert.equal((server.clients.get("c-cfg").configUpdates || []).length, 0,
    "an update with no stated reason is the thing this prevents");
  assert.match(byId(win, "client-info-update-status").textContent, /what changed/i);
  win.close();
});

test("config update: recording one stores it and exports a configuration", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-cfg");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  const files = captureDownloads(win);
  await openInfoSheet(win, "c-cfg");

  byId(win, "client-info-change-summary").value = "Acquired a subsidiary in Ohio; adding Accounts Receivable.";
  byId(win, "client-info-regenerate").click();
  await wait(120);

  const updates = server.clients.get("c-cfg").configUpdates;
  assert.equal(updates.length, 1);
  assert.match(updates[0].summary, /Acquired a subsidiary/);
  assert.equal(files.length, 1, "a configuration should have been exported");
  assert.match(byId(win, "client-info-update-status").textContent, /recorded and .*exported/i);
  assert.equal(byId(win, "client-info-change-summary").value, "", "the box clears after recording");
  win.close();
});

test("config update: the exported file carries the reason and the previous configuration date", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-cfg");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  const files = captureDownloads(win);
  await openInfoSheet(win, "c-cfg");

  byId(win, "client-info-change-summary").value = "Replaced their ERP with EBS 12.2.";
  byId(win, "client-info-regenerate").click();
  await wait(120);

  const payload = JSON.parse(files[0]);
  assert.match(payload.configurationUpdate.summary, /Replaced their ERP/);
  assert.ok(payload.configurationUpdate.recordedAt, "when it was recorded");
  assert.ok("previousConfigurationAt" in payload.configurationUpdate,
    "which configuration this one supersedes");
  // The answers still travel: this is a configuration, not just a note.
  assert.ok(payload.answers, "the client's answers are the configuration");
  win.close();
});

test("config update: counts the answers actually edited, not the whole record", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-cfg", { answers: { "QUAL-GL": "Yes", "INTAKE-001": "Meridian County Government" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  captureDownloads(win);
  await openInfoSheet(win, "c-cfg");

  typeInto(win, "INTAKE-002", "D. Okafor");
  byId(win, "client-info-save").click();
  await wait(100);

  byId(win, "client-info-change-summary").value = "New primary contact.";
  byId(win, "client-info-regenerate").click();
  await wait(120);

  const updates = server.clients.get("c-cfg").configUpdates;
  assert.equal(updates[0].answersChanged, 1,
    "one answer was edited -- an update that reshapes a client must look different from this");
  win.close();
});

test("config update: history shows previous updates, newest first", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-cfg", {
    configUpdates: [
      { id: 2, summary: "Added Cash Management.", requestedBy: "insight-app", answersChanged: 6, createdAt: "2026-07-01T10:00:00Z" },
      { id: 1, summary: "Initial configuration.", requestedBy: "insight-app", answersChanged: 40, createdAt: "2026-03-01T10:00:00Z" },
    ],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-cfg");

  const rows = byId(win, "client-info-updates").querySelectorAll(".note-row");
  assert.equal(rows.length, 2);
  assert.match(rows[0].textContent, /Added Cash Management/);
  assert.match(rows[0].textContent, /6 answers changed/);
  assert.match(rows[1].textContent, /Initial configuration/);
  win.close();
});

test("config update: works with no backend", async () => {
  const dom = await bootApp((win) => { win.fetch = () => Promise.reject(new Error("offline")); });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Harbor Freight Logistics, Harbor");
  await clickNext(win);
  await wait(40);
  captureDownloads(win);

  await openInfoSheet(win, null);
  byId(win, "client-info-change-summary").value = "Adding Fixed Assets next quarter.";
  byId(win, "client-info-regenerate").click();
  await wait(120);

  assert.match(byId(win, "client-info-updates").textContent, /Adding Fixed Assets/,
    "the in-memory store should keep the history on the record");
  win.close();
});

// ---------------------------------------------------------------------------
// Update runs: a consultant changing something should not be walked back
// through decisions an update cannot change.
// ---------------------------------------------------------------------------
const INTAKE_ONLY_COUNT = (HTML.match(/intakeOnly: true/g) || []).length;

test("update run: asks fewer questions than intake, and says why", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-upd", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-upd");
  byId(win, "client-info-start-update").click();
  await wait(80);

  assert.ok(byId(win, "screen-questionnaire").classList.contains("active"));
  const shown = Number(progressLabel(win).split("/")[1].trim());
  assert.ok(shown < GL_ONLY_DECK, `update deck (${shown}) should be shorter than intake (${GL_ONLY_DECK})`);
  // A shorter deck with no explanation reads as a bug.
  assert.ok(byId(win, "q-mode-note").classList.contains("show"));
  assert.match(byId(win, "q-mode-note").textContent, /not asked again/i);
  win.close();
});

test("update run: the questions it skips are exactly the intake-only ones", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-upd", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-upd");
  byId(win, "client-info-start-update").click();
  await wait(80);

  const shown = Number(progressLabel(win).split("/")[1].trim());
  // GL-only scope: the intake-only questions in it are the 11 client-profile
  // ones plus GL-002/004/008/009 and the three conversion questions.
  const heldInScope = INTAKE_ONLY_COUNT;   // none of them belong to AP/AR/FA/CM
  assert.equal(shown, GL_ONLY_DECK - heldInScope);
  win.close();
});

test("update run: an intake run still asks everything", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-upd", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  byId(win, "nav-clients").click();
  await wait(40);
  byId(win, "records-list-area").querySelector('[data-open="c-upd"]').click();
  await wait(60);

  assert.equal(Number(progressLabel(win).split("/")[1].trim()), GL_ONLY_DECK,
    "opening a client normally is still an intake run");
  assert.equal(byId(win, "q-mode-note").classList.contains("show"), false);
  win.close();
});

test("update run: starts at the first question, not at the first gap", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-upd", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-upd");
  byId(win, "client-info-start-update").click();
  await wait(80);

  // The point of an update is to walk what might have changed, so it starts
  // at the top with the existing answers in the fields.
  assert.match(progressLabel(win), /^1 \//);
  win.close();
});

test("update run: finishing returns to the configuration update section", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-upd", {
    answers: { "QUAL-GL": "Yes", "QUAL-AP": "No", "QUAL-AR": "No", "QUAL-FA": "No", "QUAL-CM": "No" },
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-upd");
  byId(win, "client-info-start-update").click();
  await wait(80);

  for (let i = 0; i < 120; i++) {
    if (byId(win, "client-info").classList.contains("show")) break;
    if (byId(win, "screen-chat").classList.contains("active")) break;
    const yn = win.document.querySelectorAll(".yn-btn");
    if (yn.length) clickYn(win, "Yes");
    else fillValid(win, "A considered answer for this update.");
    await clickNext(win);
    await wait(15);
  }
  await wait(150);

  // Not the follow-up chat: that exists to chase what an intake missed.
  assert.equal(byId(win, "screen-chat").classList.contains("active"), false);
  assert.ok(byId(win, "client-info").classList.contains("show"),
    "an update should end where the configuration is produced");
  assert.match(byId(win, "client-info-update-status").textContent, /say what changed/i);
  win.close();
});

// ---------------------------------------------------------------------------
// The guidance panel. Reference material first, model second: a consultant
// running their first intake needs to know what a question means far more
// often than they need something generated.
// ---------------------------------------------------------------------------

test("guidance: the panel explains the question on screen", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(30);

  const panel = byId(win, "guide");
  assert.equal(panel.classList.contains("empty"), false, "INTAKE-001 has guidance");
  assert.match(byId(win, "guide-body").textContent, /Why it is asked/);
  win.close();
});

test("guidance: it carries the workbook's own numbers, not a paraphrase", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win);
  // Walk to GL-004, the chart of accounts structure question.
  for (let i = 0; i < 40; i++) {
    if (/segment structure/i.test(byId(win, "q-text").textContent)) break;
    const yn = win.document.querySelectorAll(".yn-btn");
    if (yn.length) clickYn(win, "Yes");
    else fillValid(win, "A considered answer for this question.");
    await clickNext(win);
  }
  const text = byId(win, "guide-body").textContent;
  assert.match(text, /Fund\(5\)/, "the real segment lengths from the workbook");
  assert.match(text, /11010\.000000/, "and a real account combination as the worked example");
  win.close();
});

test("guidance: a question with no guidance hides the panel rather than showing an empty box", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  // AP is in scope, and AP has no guidance yet -- there is no configuration
  // workbook for it, and invented Fusion advice is what a first-timer
  // cannot evaluate.
  await answerQualifiers(win, { AP: "Yes" });
  for (let i = 0; i < 40; i++) {
    if (/Phase 3 · AP/.test(byId(win, "q-eyebrow").textContent)) break;
    const yn = win.document.querySelectorAll(".yn-btn");
    if (yn.length) clickYn(win, "Yes");
    else fillValid(win, "A considered answer for this question.");
    await clickNext(win);
  }
  assert.match(byId(win, "q-eyebrow").textContent, /Phase 3 · AP/);
  assert.ok(byId(win, "guide").classList.contains("empty"));
  win.close();
});

test("guidance: the panel collapses and stays collapsed across questions", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await wait(30);

  byId(win, "guide-toggle").click();
  assert.ok(byId(win, "guide").classList.contains("collapsed"));
  fillValid(win, "Meridian County Government, known as Meridian.");
  await clickNext(win);
  await wait(30);
  assert.ok(byId(win, "guide").classList.contains("collapsed"),
    "a consultant who hid it should not have to hide it again every question");
  win.close();
});

test("guidance: asking the assistant sends the question and the reference material", async () => {
  const sent = [];
  const dom = await bootApp((win) => {
    win.fetch = (url, opts) => {
      if (String(url).includes("/api/explain")) {
        sent.push(JSON.parse(opts.body));
        return Promise.resolve({
          ok: true, status: 200,
          json: () => Promise.resolve({ answer: "A balancing segment is where Fusion enforces balance." }),
        });
      }
      return Promise.reject(new Error("offline"));
    };
  });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(30);

  byId(win, "guide-ask-input").value = "What is a balancing segment?";
  byId(win, "guide-ask-send").click();
  await wait(80);

  assert.equal(sent.length, 1);
  assert.ok(sent[0].questionText, "the questionnaire question travels");
  assert.ok(sent[0].guidance, "so does the reference material, so the reply builds on it");
  assert.match(byId(win, "guide-answer").textContent, /enforces balance/);
  win.close();
});

test("guidance: an unreachable assistant says so and leaves the reference material standing", async () => {
  const dom = await bootApp((win) => {
    win.fetch = (url) => String(url).includes("/api/explain")
      ? Promise.resolve({ ok: false, status: 502, json: () => Promise.resolve({}) })
      : Promise.reject(new Error("offline"));
  });
  const win = dom.window;
  await wait(40);
  byId(win, "btn-new-client").click();
  await wait(30);

  byId(win, "guide-ask-input").value = "What is a balancing segment?";
  byId(win, "guide-ask-send").click();
  await wait(80);

  const answer = byId(win, "guide-answer").textContent;
  assert.match(answer, /isn't reachable/i, "and says which of the two it is");
  assert.match(byId(win, "guide-body").textContent, /Why it is asked/,
    "the reference material does not depend on the model");
  win.close();
});

// ---------------------------------------------------------------------------
// Approval is for the assistant, not for the consultant -- and whatever does
// queue has to be visible, or it is indistinguishable from a lost answer.
// ---------------------------------------------------------------------------

test("approval: a consultant editing an answer applies it directly", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-appr", { answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-appr");

  typeInto(win, "INTAKE-003", "CFO, Controller and IT Director");
  byId(win, "client-info-save").click();
  await wait(100);

  assert.equal(server.clients.get("c-appr").answers["INTAKE-003"], "CFO, Controller and IT Director",
    "the edit should be on the record, not in a queue");
  assert.doesNotMatch(byId(win, "client-info-status").textContent, /pending/i);
  win.close();
});

test("approval: an assistant proposal waits, and is shown with what it replaces", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-appr", {
    answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" },
    changes: [{ id: 5, questionId: "INTAKE-003", questionText: "Who else is a key stakeholder?",
                previousValue: "CFO and Controller", proposedValue: "CFO, Controller, IT Director",
                submittedBy: "assistant", submittedAt: "2026-08-24T10:00:00Z", status: "PENDING" }],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-appr");

  const section = byId(win, "client-info-changes");
  assert.match(section.textContent, /Who else is a key stakeholder/);
  // Both values, because a reviewer cannot decide on the new one alone.
  assert.match(section.textContent, /CFO and Controller/);
  assert.match(section.textContent, /IT Director/);
  assert.equal(byId(win, "client-info-changes-label").classList.contains("hidden-section"), false);
  win.close();
});

test("approval: approving one applies it and updates the fields above", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-appr", {
    answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" },
    changes: [{ id: 5, questionId: "INTAKE-003", questionText: "Who else is a key stakeholder?",
                previousValue: "CFO and Controller", proposedValue: "CFO, Controller, IT Director",
                submittedBy: "assistant", submittedAt: "2026-08-24T10:00:00Z", status: "PENDING" }],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-appr");

  byId(win, "client-info-changes").querySelector("[data-approve]").click();
  await wait(120);

  assert.equal(server.clients.get("c-appr").answers["INTAKE-003"], "CFO, Controller, IT Director");
  assert.equal(qfField(win, "INTAKE-003").value, "CFO, Controller, IT Director",
    "leaving the field showing the old value would contradict what was just done");
  assert.ok(byId(win, "client-info-changes-label").classList.contains("hidden-section"),
    "an empty queue hides rather than sitting there empty");
  win.close();
});

test("approval: rejecting one leaves the record alone", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-appr", {
    answers: { "QUAL-GL": "Yes", "INTAKE-003": "CFO and Controller" },
    changes: [{ id: 5, questionId: "INTAKE-003", questionText: "Who else is a key stakeholder?",
                previousValue: "CFO and Controller", proposedValue: "Nonsense",
                submittedBy: "assistant", submittedAt: "2026-08-24T10:00:00Z", status: "PENDING" }],
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-appr");

  byId(win, "client-info-changes").querySelector("[data-reject]").click();
  await wait(120);

  assert.equal(server.clients.get("c-appr").answers["INTAKE-003"], "CFO and Controller");
  assert.equal(server.clients.get("c-appr").changes[0].status, "REJECTED");
  win.close();
});

test("approval: approve all clears a backlog in one action", async () => {
  const server = statefulFakeOrds();
  const changes = [1, 2, 3].map((i) => ({
    id: i, questionId: "INTAKE-00" + i, questionText: "Question " + i,
    previousValue: "old " + i, proposedValue: "new " + i,
    submittedBy: "assistant", submittedAt: "2026-08-24T10:00:0" + i + "Z", status: "PENDING",
  }));
  seedClient(server, "c-appr", {
    answers: { "QUAL-GL": "Yes", "INTAKE-001": "old 1", "INTAKE-002": "old 2", "INTAKE-003": "old 3" },
    changes,
  });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  win.confirm = () => true;
  await openInfoSheet(win, "c-appr");
  assert.equal(byId(win, "client-info-changes").querySelectorAll(".note-row").length, 3);

  byId(win, "client-info-approve-all").click();
  await wait(150);

  // A backlog that can only be cleared one click at a time is a backlog
  // nobody clears.
  assert.equal(server.clients.get("c-appr").changes.filter((c) => c.status === "PENDING").length, 0);
  assert.equal(server.clients.get("c-appr").answers["INTAKE-002"], "new 2");
  win.close();
});

test("approval: with nothing pending the whole section is hidden", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-appr", { answers: { "QUAL-GL": "Yes" } });
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);
  await openInfoSheet(win, "c-appr");

  ["client-info-changes-label", "client-info-changes-hint", "client-info-changes-actions"]
    .forEach((id) => assert.ok(byId(win, id).classList.contains("hidden-section"), id));
  win.close();
});

test("approval: no backend means nothing pending, not an error", async () => {
  const dom = await bootApp((win) => { win.fetch = () => Promise.reject(new Error("offline")); });
  const win = dom.window;
  await wait(60);
  byId(win, "btn-new-client").click();
  await wait(30);
  fillText(win, "Harbor Freight Logistics, Harbor");
  await clickNext(win);
  await wait(40);

  await openInfoSheet(win, null);
  assert.ok(byId(win, "client-info").classList.contains("show"));
  assert.ok(byId(win, "client-info-changes-label").classList.contains("hidden-section"),
    "the in-memory store has no approval workflow, so there is genuinely nothing pending");
  win.close();
});

test("roster: the two ways into a client are labelled, not two identical glyphs", async () => {
  const server = statefulFakeOrds();
  seedClient(server, "c-row");
  const dom = await bootApp((win) => { win.fetch = server.fetchImpl; });
  const win = dom.window;
  await wait(60);

  const row = byId(win, "records-list-area").querySelector(".client-row");
  assert.equal(row.querySelector("[data-info]").textContent, "Client file");
  assert.equal(row.querySelector("[data-open]").textContent, "Questions");
  // Both lead into the client's answers by different routes, so each says
  // which route it is on hover too.
  assert.match(row.querySelector("[data-info]").title, /whole record/i);
  assert.match(row.querySelector("[data-open]").title, /first unanswered/i);
  win.close();
});
