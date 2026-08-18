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

// Boots a fresh app instance and advances past the loading screen to
// Client Records -- every test starts from here.
async function bootApp() {
  const dom = new JSDOM(HTML, { url: "http://localhost/", runScripts: "dangerously" });
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

// Answers all 10 Phase 1 intake questions with non-blank text.
async function fillIntake(win) {
  for (let i = 0; i < 10; i++) {
    fillText(win, "answer " + i);
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
  // Loop, bounded well above the largest possible deck (91), so a stuck
  // loop fails fast instead of hanging the suite.
  for (let i = 0; i < 100; i++) {
    if (byId(win, "screen-chat").classList.contains("active")) return;
    const ynButtons = win.document.querySelectorAll(".yn-btn");
    if (ynButtons.length) clickYn(win, "Yes");
    else fillText(win, "answer");
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
  assert.equal(progressLabel(win), "1 / 42");
});

test("phase 1 intake progresses 1/42 -> 11/42 into phase 2 qualifiers", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  assert.equal(progressLabel(win), "11 / 42");
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
  const before = 42;
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
  // All optional modules declined -- deck should be back to the GL-only baseline (42)
  const [, denom] = progressLabel(win).split(" / ");
  assert.equal(Number(denom), 42);
  assert.match(byId(win, "q-eyebrow").textContent, /GL Discovery/);
});

test("skipped required question resurfaces in AI Follow-Up chat, then clears the gap", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win);
  await answerQualifiers(win); // GL-only deck, 42 total
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

test("persistence: saved record shape has answers/skipped/companyName and round-trips through resume", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  fillText(win, "Acme Corp, Acme");
  await clickNext(win);
  const keys = Object.keys(win.localStorage).filter((k) => k.startsWith("insight:client:"));
  assert.equal(keys.length, 1);
  const record = JSON.parse(win.localStorage.getItem(keys[0]));
  assert.ok(record.answers && typeof record.answers === "object");
  assert.ok(record.skipped && typeof record.skipped === "object");
  assert.equal(record.companyName, "Acme Corp");
  assert.equal(record.answers["INTAKE-001"], "Acme Corp, Acme");
});

test("resume: reopening a saved client restores position at the first unanswered question", async () => {
  const dom = await bootApp();
  const win = dom.window;
  byId(win, "btn-new-client").click();
  await fillIntake(win); // now on QUAL-GL (index 10); it's locked with a valid
  // default answer already, so it isn't a "gap" -- the real first unanswered
  // question is QUAL-AP (index 11), which is where resume should land.
  byId(win, "nav-clients").click();
  await wait(10);
  byId(win, "records-list-area").querySelector('[data-open]').click();
  await wait(10);
  assert.equal(progressLabel(win), "12 / 42");
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
  assert.equal(progressLabel(win), "11 / 42");
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

  assert.equal(alertCalled, false, "export must not fall back to the old mockup alert");
  assert.ok(clickedAnchor, "export should trigger a download anchor click");
  assert.match(clickedAnchor.download, /-export\.json$/);
});
