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
    this.checked = false;
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
    "previous-recordings", "next-recordings", "recording-page", "protected-only", "protection-summary",
    "protection-warning", "protection-message", "retention-warning", "live-quality"];
  const elements = Object.fromEntries(ids.map((id) => [id, new Element()]));
  elements["recording-template"].content = { firstElementChild: { cloneNode() {
    const card = new Element();
    card.video = new Element();
    const fields = Object.fromEntries([".recording-date", ".recording-size", ".recording-summary", ".recording-thumbnail", ".thumbnail-placeholder", ".recording-download", ".recording-protect", ".recording-protection-state"]
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
    confirmUnprotect: true, protectionRequests: [], blockProtection: false, finishProtection: null, failProtection: false,
    recordingRequests: [], blockRecordings: false, pendingRecordings: [], recordings: [
      { id: "example.mp4", startedAt: "2026-10-20T03:00:00Z", sizeBytes: 1024, url: "/recordings/example.mp4",
        protected: false, protectionSupported: true, protectionAvailable: true,
        thumbnailURL: "/api/recordings/example.mp4/thumbnail", downloadURL: "/recordings/example.mp4?download=1" },
    ] };
  const response = (body, status = 200) => ({ ok: status < 400, status, headers: { get: () => "application/json" }, json: async () => body });
  const fetch = async (url, options = {}) => {
    if (url === "/api/session") return response({ authenticated: true, csrfToken: "session-one" });
    if (url === "/api/logout") return response({ authenticated: false });
    if (url.startsWith("/api/recordings?")) {
      api.recordingRequests.push(url);
      const query = new URL(url, "https://camera.example").searchParams;
      const items = api.recordings.filter((item) => (!query.has("from") || item.startedAt >= query.get("from")) &&
        (!query.has("to") || item.startedAt < query.get("to")) && (!query.has("protected") || item.protected));
      const offset = Number(query.get("offset"));
      const limit = Number(query.get("limit"));
      const protectedItems = api.recordings.filter((item) => item.protected);
      const result = { recordings: items.slice(offset, offset + limit), total: items.length, hasMore: offset + limit < items.length,
        protectedCount: protectedItems.length, protectedBytes: protectedItems.reduce((sum, item) => sum + item.sizeBytes, 0) };
      if (api.blockRecordings) return new Promise((resolve) => api.pendingRecordings.push(() => resolve(response(result))));
      return response(result);
    }
    if (url.endsWith("/protection")) {
      api.protectionRequests.push({ url, options });
      const finish = () => {
        if (api.failProtection) return response({ error: "보호 저장 실패" }, 503);
        const value = JSON.parse(options.body).protected;
        const id = decodeURIComponent(url.split("/")[3]);
        api.recordings.find((item) => item.id === id).protected = value;
        return response({ protected: value });
      };
      if (api.blockProtection) return new Promise((resolve) => { api.finishProtection = () => resolve(finish()); });
      return finish();
    }
    if (url === "/api/status") {
      if (api.blocked) return new Promise((resolve) => { api.release = () => resolve(response({ mediaReachable: api.mediaOnline, monitoring: api.monitoring })); });
      return response({ mediaReachable: api.mediaOnline, monitoring: api.monitoring });
    }
    throw new Error(`unexpected request ${url}`);
  };
  const context = vm.createContext({ document, fetch, Headers, Intl, Date, URLSearchParams,
    confirm: () => api.confirmUnprotect,
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

test("protect writes explicit state with CSRF, prevents duplicate clicks and survives list refresh", async () => {
  const { elements, api } = await fixture(false);
  api.blockProtection = true;
  let button = elements.recordings.children[0].querySelector(".recording-protect");
  assert.equal(button.disabled, false);
  const saving = button.listeners.click();
  button.listeners.click();
  await flush();
  assert.equal(api.protectionRequests.length, 1);
  const write = api.protectionRequests[0];
  assert.equal(write.options.method, "PUT");
  assert.equal(write.options.headers.get("X-CSRF-Token"), "session-one");
  assert.deepEqual(JSON.parse(write.options.body), { protected: true });
  elements["refresh-recordings"].listeners.click();
  await flush();
  button = elements.recordings.children[0].querySelector(".recording-protect");
  assert.equal(button.disabled, true);
  api.finishProtection();
  await saving;
  await flush();
  button = elements.recordings.children[0].querySelector(".recording-protect");
  assert.equal(button.textContent, "보호 해제");
  assert.equal(button.disabled, false);
  assert.match(elements.recordings.children[0].querySelector(".recording-protection-state").textContent, /보호 중/);
  assert.match(elements["protection-summary"].textContent, /1개 · 1.0 KB/);
});

test("protected-only search and confirmation guard unprotect; cancel never writes", async () => {
  const { elements, api } = await fixture(false);
  await elements.recordings.children[0].querySelector(".recording-protect").listeners.click();
  await flush();
  elements["protected-only"].checked = true;
  elements["recording-filter"].listeners.submit({ preventDefault() {} });
  await flush();
  assert.equal(new URL(api.recordingRequests.at(-1), "https://camera.example").searchParams.get("protected"), "1");
  api.confirmUnprotect = false;
  const count = api.protectionRequests.length;
  await elements.recordings.children[0].querySelector(".recording-protect").listeners.click();
  assert.equal(api.protectionRequests.length, count);
  api.confirmUnprotect = true;
  await elements.recordings.children[0].querySelector(".recording-protect").listeners.click();
  await flush();
  assert.equal(elements.recordings.children.length, 0);
  assert.match(elements["protection-message"].textContent, /해제했습니다/);
  elements["clear-recording-filter"].listeners.click();
  await flush();
  assert.equal(elements["protected-only"].checked, false);
  assert.equal(elements.recordings.children.length, 1);
});

test("failed protection stays unprotected and pending write after logout cannot restore private UI", async () => {
  const { elements, api } = await fixture(false);
  api.failProtection = true;
  await elements.recordings.children[0].querySelector(".recording-protect").listeners.click();
  await flush();
  assert.match(elements["protection-message"].textContent, /저장 실패/);
  assert.equal(elements.recordings.children[0].querySelector(".recording-protect").textContent, "중요 녹화로 보호");
  api.failProtection = false;
  api.blockProtection = true;
  const pending = elements.recordings.children[0].querySelector(".recording-protect").listeners.click();
  await flush();
  await elements.logout.listeners.click();
  api.finishProtection();
  await pending;
  await flush();
  assert.equal(elements.app.hidden, true);
  assert.equal(elements.recordings.children.length, 0);
  assert.equal(elements["protection-message"].textContent, "");
});

test("pending or unreadable protection state disables edits and retention warnings distinguish stale reports", async () => {
  const { elements, api, tick } = await fixture(false);
  api.recordings[0].protectionSupported = false;
  elements["refresh-recordings"].listeners.click();
  await flush();
  assert.equal(elements.recordings.children[0].querySelector(".recording-protect").disabled, true);
  api.recordings[0].protectionSupported = true;
  api.recordings[0].protectionAvailable = false;
  elements["refresh-recordings"].listeners.click();
  await flush();
  assert.equal(elements.recordings.children[0].querySelector(".recording-protect").disabled, true);
  assert.match(elements.recordings.children[0].querySelector(".recording-protection-state").textContent, /확인 불가/);
  api.monitoring = { available: true, fresh: true, state: "stopped", retentionWarning: "공간 부족" };
  await tick();
  assert.equal(elements["retention-warning"].hidden, false);
  assert.match(elements["retention-warning"].textContent, /공간 부족/);
  api.monitoring.fresh = false;
  await tick();
  assert.match(elements["retention-warning"].textContent, /갱신 지연/);
  api.monitoring.retentionWarning = "";
  await tick();
  assert.equal(elements["retention-warning"].hidden, true);
});

test("capture stop switches to archive; capture resume leaves archive playback undisturbed", async () => {
  const { elements, api, tick, tab } = await fixture(true);
  assert.match(elements["live-player"].src, /^\/assets\/live\.html\?quality=/);
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
  assert.match(elements["live-player"].src, /^\/assets\/live\.html\?quality=/);
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

test("quality choices reconnect only the live view and cannot load media after logout", async () => {
  const { elements, tab } = await fixture(true);
  elements["live-quality"].value = "low";
  elements["live-quality"].listeners.change();
  await flush();
  assert.match(elements["live-player"].src, /quality=low/);
  await tab("recordings");
  elements["live-quality"].value = "original";
  elements["live-quality"].listeners.change();
  await flush();
  assert.equal(elements["live-player"].src, undefined);
  await tab("live");
  assert.match(elements["live-player"].src, /quality=original/);
  await elements.logout.listeners.click();
  elements["live-quality"].listeners.change();
  await flush();
  assert.equal(elements["live-player"].src, undefined);
});
