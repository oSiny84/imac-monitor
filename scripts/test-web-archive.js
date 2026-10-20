// Browser-controller regression tests using Node's built-in modules and a small
// DOM double. No browser or production services are started by this test.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

class Element {
  constructor() {
    this.hidden = false;
    this.textContent = "";
    this.children = [];
    this.listeners = {};
    const classes = new Set();
    this.classList = {
      add: (value) => classes.add(value), remove: (value) => classes.delete(value),
      toggle: (value, on) => on ? classes.add(value) : classes.delete(value),
    };
  }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  removeAttribute(name) { delete this[name]; }
  replaceChildren(...children) { this.children = children; }
  append(child) { this.children.push(child); }
  querySelectorAll(selector) { return selector === "video" ? this.children.map((card) => card.video) : []; }
  pause() { this.paused = true; }
  load() {}
}

async function flush() { await new Promise(setImmediate); }

async function fixture(mediaOnline) {
  const ids = ["login-panel", "app", "connection", "login-form", "login-error", "live-player",
    "live-unavailable", "media-status", "recordings", "recordings-empty", "recording-template",
    "logout", "reload-live", "refresh-recordings", "live-view", "recordings-view"];
  const elements = Object.fromEntries(ids.map((id) => [id, new Element()]));
  elements["recording-template"].content = { firstElementChild: { cloneNode() {
    const card = new Element();
    card.video = new Element();
    const fields = Object.fromEntries([".recording-date", ".recording-size", ".recording-summary"]
      .map((selector) => [selector, new Element()]));
    card.querySelector = (selector) => selector === "video" ? card.video : fields[selector];
    return card;
  } } };
  const tabs = ["live", "recordings"].map((view) => Object.assign(new Element(), { dataset: { view } }));
  const document = {
    hidden: false,
    querySelector: (selector) => elements[selector.slice(1)],
    querySelectorAll: () => tabs,
    addEventListener() {},
  };
  const api = { mediaOnline, blocked: false, release: null, interval: null };
  const response = (body) => ({ ok: true, headers: { get: () => "application/json" }, json: async () => body });
  const fetch = async (url) => {
    if (url === "/api/session") return response({ authenticated: true, csrfToken: "session-one" });
    if (url === "/api/logout") return response({ authenticated: false });
    if (url === "/api/recordings") return response({ recordings: [
      { startedAt: "2026-10-20T03:00:00Z", sizeBytes: 1024, url: "/recordings/example.mp4" },
    ] });
    if (url === "/api/status") {
      if (api.blocked) return new Promise((resolve) => { api.release = () => resolve(response({ mediaReachable: api.mediaOnline })); });
      return response({ mediaReachable: api.mediaOnline });
    }
    throw new Error(`unexpected request ${url}`);
  };
  const context = vm.createContext({ document, fetch, Headers, Intl, Date,
    setInterval: (callback) => { api.interval = callback; },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../gateway/internal/server/web/assets/app.js"), "utf8"), context);
  await flush();
  return {
    elements, api,
    tick: async () => { api.interval(); await flush(); },
    tab: async (view) => { tabs.find((tab) => tab.dataset.view === view).listeners.click(); await flush(); },
  };
}

test("login with capture stopped opens playable recordings, without a broken live iframe", async () => {
  const { elements } = await fixture(false);
  assert.equal(elements.app.hidden, false);
  assert.equal(elements["live-view"].hidden, true);
  assert.equal(elements["recordings-view"].hidden, false);
  assert.equal(elements["live-unavailable"].hidden, false);
  assert.equal(elements["live-player"].src, undefined);
  assert.equal(elements.recordings.children.length, 1);
  const card = elements.recordings.children[0];
  card.querySelector(".recording-summary").listeners.click();
  assert.equal(card.video.src, "/recordings/example.mp4");
});

test("capture stop switches to archive; capture resume leaves archive playback undisturbed", async () => {
  const { elements, api, tick, tab } = await fixture(true);
  assert.match(elements["live-player"].src, /^\/live\/live\//);
  api.mediaOnline = false;
  await tick();
  assert.equal(elements["recordings-view"].hidden, false);
  assert.equal(elements["live-player"].src, undefined);
  api.mediaOnline = true;
  await tick();
  assert.equal(elements["recordings-view"].hidden, false);
  assert.equal(elements["live-unavailable"].hidden, true);
  assert.equal(elements["live-player"].src, undefined);
  await tab("live");
  assert.match(elements["live-player"].src, /^\/live\/live\//);
});

test("opening recordings stops the live iframe and polling does not reopen it", async () => {
  const { elements, tab, tick } = await fixture(true);
  await tab("recordings");
  await tick();
  assert.equal(elements["live-player"].src, undefined);
  assert.equal(elements["recordings-view"].hidden, false);
});

test("a status response arriving after logout cannot restart live video", async () => {
  const { elements, api, tick } = await fixture(true);
  api.blocked = true;
  await tick();
  assert.equal(typeof api.release, "function");
  await elements.logout.listeners.click();
  api.release();
  await flush();
  assert.equal(elements.app.hidden, true);
  assert.equal(elements["login-panel"].hidden, false);
  assert.equal(elements["live-player"].src, undefined);
});
