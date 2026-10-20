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
    this.value = "";
    this.disabled = false;
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
  querySelectorAll(selector) { return selector === "video" ? this.children.map((card) => card.video) : selector === "img" ? this.children.map((card) => card.image) : []; }
  pause() { this.paused = true; }
  load() {}
}

async function flush() { await new Promise(setImmediate); }

async function fixture(mediaOnline) {
  const ids = ["login-panel", "app", "connection", "login-form", "login-error", "live-player",
    "live-unavailable", "media-status", "recordings", "recordings-empty", "recording-template",
    "logout", "reload-live", "refresh-recordings", "live-view", "recordings-view", "monitor-state", "monitor-detail",
    "capture-fps", "last-frame", "last-motion", "last-recording", "disk-free", "watchdog-count",
    "recording-from", "recording-to", "recording-filter", "clear-recording-filter", "recording-results", "recording-timezone",
    "previous-recordings", "next-recordings", "recording-page"];
  const elements = Object.fromEntries(ids.map((id) => [id, new Element()]));
  elements["recording-template"].content = { firstElementChild: { cloneNode() {
    const card = new Element();
    card.video = new Element();
    const fields = Object.fromEntries([".recording-date", ".recording-size", ".recording-summary", ".recording-thumbnail", ".thumbnail-placeholder", ".recording-download"]
      .map((selector) => [selector, new Element()]));
    card.image = fields[".recording-thumbnail"];
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
  const api = { mediaOnline, blocked: false, release: null, interval: null, monitoring: null,
    recordingRequests: [], blockRecordings: false, pendingRecordings: [], recordings: [
      { id: "example.mp4", startedAt: "2026-10-20T03:00:00Z", sizeBytes: 1024, url: "/recordings/example.mp4",
        thumbnailURL: "/api/recordings/example.mp4/thumbnail", downloadURL: "/recordings/example.mp4?download=1" },
    ] };
  const response = (body) => ({ ok: true, headers: { get: () => "application/json" }, json: async () => body });
  const fetch = async (url) => {
    if (url === "/api/session") return response({ authenticated: true, csrfToken: "session-one" });
    if (url === "/api/logout") return response({ authenticated: false });
    if (url.startsWith("/api/recordings?")) {
      api.recordingRequests.push(url);
      const query = new URL(url, "https://camera.example").searchParams;
      const items = api.recordings.filter((item) => (!query.has("from") || item.startedAt >= query.get("from")) &&
        (!query.has("to") || item.startedAt < query.get("to")));
      const offset = Number(query.get("offset"));
      const limit = Number(query.get("limit"));
      const result = { recordings: items.slice(offset, offset + limit), total: items.length, hasMore: offset + limit < items.length };
      if (api.blockRecordings) return new Promise((resolve) => api.pendingRecordings.push(() => resolve(response(result))));
      return response(result);
    }
    if (url === "/api/status") {
      if (api.blocked) return new Promise((resolve) => { api.release = () => resolve(response({ mediaReachable: api.mediaOnline, monitoring: api.monitoring })); });
      return response({ mediaReachable: api.mediaOnline, monitoring: api.monitoring });
    }
    throw new Error(`unexpected request ${url}`);
  };
  const context = vm.createContext({ document, fetch, Headers, Intl, Date, URLSearchParams,
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

test("archive cards load small previews, keep MP4 unloaded and offer direct authenticated downloads", async () => {
  const { elements, tab } = await fixture(false);
  const card = elements.recordings.children[0];
  assert.equal(card.video.src, undefined);
  assert.equal(card.image.src, "/api/recordings/example.mp4/thumbnail");
  assert.equal(card.querySelector(".recording-download").href, "/recordings/example.mp4?download=1");
  assert.equal(card.querySelector(".recording-download").download, "example.mp4");
  card.image.listeners.error();
  assert.equal(card.image.hidden, true);
  assert.match(card.querySelector(".thumbnail-placeholder").textContent, /재생 가능/);
  card.querySelector(".recording-summary").listeners.click();
  assert.equal(card.video.src, "/recordings/example.mp4");
  await tab("live");
  assert.equal(card.video.paused, true);
});

test("date search uses inclusive local calendar days, clear resets it, reversed range is rejected", async () => {
  const { elements, api } = await fixture(false);
  elements["recording-from"].value = "2026-03-08";
  elements["recording-to"].value = "2026-03-08";
  elements["recording-filter"].listeners.submit({ preventDefault() {} });
  await flush();
  const query = new URL(api.recordingRequests.at(-1), "https://camera.example").searchParams;
  assert.equal(query.get("from"), new Date("2026-03-08T00:00:00").toISOString());
  assert.equal(query.get("to"), new Date("2026-03-09T00:00:00").toISOString());
  if (Intl.DateTimeFormat().resolvedOptions().timeZone === "America/New_York") {
    assert.equal(new Date(query.get("to")) - new Date(query.get("from")), 23 * 3600000);
  }
  const requests = api.recordingRequests.length;
  elements["recording-from"].value = "2026-03-10";
  elements["recording-filter"].listeners.submit({ preventDefault() {} });
  await flush();
  assert.equal(api.recordingRequests.length, requests);
  assert.match(elements["recording-results"].textContent, /늦습니다/);
  elements["recording-from"].value = "2026-02-30";
  elements["recording-to"].value = "";
  elements["recording-filter"].listeners.submit({ preventDefault() {} });
  await flush();
  assert.equal(api.recordingRequests.length, requests);
  assert.match(elements["recording-results"].textContent, /날짜를 확인/);
  elements["clear-recording-filter"].listeners.click();
  await flush();
  assert.equal(elements["recording-from"].value, "");
  assert.equal(new URL(api.recordingRequests.at(-1), "https://camera.example").searchParams.has("from"), false);
});

test("archive pagination is bounded and a late page response cannot overwrite newer search", async () => {
  const { elements, api } = await fixture(false);
  api.recordings = Array.from({ length: 51 }, (_, i) => ({ ...api.recordings[0], id: `recording-${i}.mp4` }));
  elements["refresh-recordings"].listeners.click();
  await flush();
  assert.equal(elements.recordings.children.length, 50);
  assert.equal(elements["previous-recordings"].disabled, true);
  assert.equal(elements["next-recordings"].disabled, false);
  elements["next-recordings"].listeners.click();
  await flush();
  assert.equal(elements.recordings.children.length, 1);
  assert.equal(elements["next-recordings"].disabled, true);
  assert.equal(elements["previous-recordings"].disabled, false);
  assert.match(elements["recording-page"].textContent, /^2 /);
  api.blockRecordings = true;
  elements["previous-recordings"].listeners.click();
  await flush();
  assert.equal(elements["next-recordings"].disabled, true);
  api.blockRecordings = false;
  elements["recording-from"].value = "2027-01-01";
  elements["recording-filter"].listeners.submit({ preventDefault() {} });
  await flush();
  assert.equal(elements.recordings.children.length, 0);
  api.pendingRecordings[0]();
  await flush();
  assert.equal(elements.recordings.children.length, 0);
  assert.equal(elements["next-recordings"].disabled, true);
  assert.match(elements["recording-results"].textContent, /총 0개/);
});

test("logout releases media and a late archive response cannot restore private cards", async () => {
  const { elements, api } = await fixture(false);
  const old = elements.recordings.children[0];
  old.querySelector(".recording-summary").listeners.click();
  api.blockRecordings = true;
  elements["refresh-recordings"].listeners.click();
  await flush();
  assert.equal(old.video.paused, true);
  assert.equal(old.video.src, undefined);
  assert.equal(old.image.src, undefined);
  await elements.logout.listeners.click();
  api.pendingRecordings[0]();
  await flush();
  assert.equal(elements.recordings.children.length, 0);
  assert.equal(elements.app.hidden, true);
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

test("health distinguishes real frames, planned rest, stalls and stale app data", async () => {
  const { elements, api, tick } = await fixture(true);
  assert.equal(elements["monitor-state"].textContent, "상태 확인 불가");
  api.monitoring = { available: true, fresh: true, state: "running", frameState: "receiving", expectingFrames: true,
    detail: "감시 중", captureFPS: 14.9, lastFrameAt: "2026-10-20T05:00:00Z", diskFreeBytes: 1073741824,
    watchdogRecoveries: 0 };
  await tick();
  assert.equal(elements["monitor-state"].textContent, "새 프레임 수신 중");
  assert.equal(elements["capture-fps"].textContent, "14.9 fps");
  assert.equal(elements["disk-free"].textContent, "1.0 GB");
  assert.notEqual(elements["last-frame"].textContent, "—");
  api.monitoring.state = "scheduledRest";
  api.monitoring.frameState = "inactive";
  api.monitoring.expectingFrames = false;
  await tick();
  assert.equal(elements["monitor-state"].textContent, "예약 휴식 중");
  assert.equal(elements["capture-fps"].textContent, "—");
  api.monitoring.state = "running";
  api.monitoring.expectingFrames = true;
  api.monitoring.frameState = "stalled";
  await tick();
  assert.match(elements["monitor-state"].textContent, /프레임 정지/);
  api.monitoring.fresh = false;
  await tick();
  assert.equal(elements["monitor-state"].textContent, "상태 갱신 지연");
  assert.equal(elements["capture-fps"].textContent, "—");
});
