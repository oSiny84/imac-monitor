// Deterministic WebRTC/DOM doubles: no network, camera, sleep or media processes.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

function fixture(mode = "auto", options = {}) {
  let now = 100000, nextID = 1, postCount = 0;
  const intervals = new Map(), timeouts = new Map(), requests = [], peers = [];
  const api = { authenticated: true, postStatus: 201, location: null, blockPost: false, releasePost: null,
    blockSession: false, releaseSessions: [], report: new Map(), ...options.api };
  const windowEvents = new Map(), documentEvents = new Map();
  const listen = (events, type, callback) => { if (!events.has(type)) events.set(type, []); events.get(type).push(callback); };
  const dispatch = (events, type, event = {}) => { for (const callback of events.get(type) || []) callback(event); };
  const video = { paused: true, currentTime: 0, srcObject: null, pause() { this.paused = true; }, play() { this.paused = false; return Promise.resolve(); } };
  const status = {}, metrics = {};
  const document = { hidden: Boolean(options.hidden),
    querySelector: (selector) => options.auto ? ({ "#remote-video": video, "#player-status": status, "#player-metrics": metrics }[selector] || null) : null,
    addEventListener: (type, callback) => listen(documentEvents, type, callback) };
  class Peer {
    constructor(options) { this.options = options; this.iceGatheringState = "complete"; this.connectionState = "new"; peers.push(this); }
    addTransceiver(kind, options) { this.transceiver = { kind, options }; }
    async createOffer() { return { type: "offer", sdp: "test offer with gathered ICE" }; }
    async setLocalDescription(value) { this.localDescription = value; }
    async setRemoteDescription(value) { this.remoteDescription = value; this.connectionState = "connected"; this.ontrack?.({ streams: [{}], track: {} }); }
    async getStats() { return api.report; }
    close() { this.closed = true; }
    addEventListener() {}
    removeEventListener() {}
  }
  const response = (status, body, location = null) => ({ status, ok: status < 400,
    headers: { get: () => location }, json: async () => body, text: async () => "test SDP answer" });
  const context = vm.createContext({ console, document, URL, URLSearchParams, AbortController,
    location: { origin: "https://camera.example", search: `?quality=${mode}` }, RTCPeerConnection: Peer,
    addEventListener: (type, callback) => listen(windowEvents, type, callback),
    Date: class extends Date { static now() { return now; } },
    setInterval: (callback) => { const id = nextID++; intervals.set(id, callback); return id; },
    clearInterval: (id) => intervals.delete(id),
    setTimeout: (callback, delay) => { const id = nextID++; timeouts.set(id, { callback, delay }); return id; },
    clearTimeout: (id) => timeouts.delete(id),
    fetch: async (url, options = {}) => {
      requests.push({ url, options });
      if (url === "/api/session") {
        const result = response(200, { authenticated: api.authenticated });
        if (api.blockSession) return new Promise((resolve) => api.releaseSessions.push(() => resolve(result)));
        return result;
      }
      if (options.method === "DELETE") return response(204, null);
      if (options.method === "POST") {
        const pathName = new URL(url).pathname;
        const result = response(api.postStatus, null, api.location || `${pathName}/session-${++postCount}`);
        if (api.blockPost) return new Promise((resolve) => { api.releasePost = () => resolve(result); });
        return result;
      }
      throw new Error(`unexpected request ${url}`);
    },
  });
  for (const file of ["live-quality.js", "live-player.js"]) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, "../gateway/internal/server/web/assets", file), "utf8"), context);
  }
  const player = options.auto ? null : new context.MacMonitorLivePlayer(video, status, metrics, mode);
  return { context, player, api, video, status, metrics, requests, peers, intervals, timeouts,
    event: (type, event) => dispatch(windowEvents, type, event),
    visibility: (hidden) => { document.hidden = hidden; dispatch(documentEvents, "visibilitychange"); },
    advance: (milliseconds) => { now += milliseconds; },
    now: () => now,
    retry: async () => { const item = [...timeouts.entries()].find(([, value]) => value.delay <= 8000); if (item) { timeouts.delete(item[0]); await item[1].callback(); } },
  };
}
async function flush() { await new Promise(setImmediate); }
function report(timestamp, bytes, frames, packets = 100, lost = 0) {
  return new Map([["video", { type: "inbound-rtp", kind: "video", timestamp, bytesReceived: bytes, framesDecoded: frames,
    packetsReceived: packets, packetsLost: lost, framesDropped: 0 }], ["transport", { type: "transport", selectedCandidatePairId: "pair" }],
  ["pair", { type: "candidate-pair", currentRoundTripTime: 0.04 }]]);
}

test("automatic policy steps down after sustained degradation, not one spike", () => {
  const { context } = fixture();
  const policy = new context.MacMonitorQuality.AdaptiveQuality("auto", 0);
  assert.equal(policy.profile.id, "balanced");
  assert.equal(policy.sample({ loss: 0.2, fps: 10 }, 12000), null);
  assert.equal(policy.sample({ loss: 0.2, fps: 10 }, 14000).id, "low");
  assert.equal(policy.sample({ loss: 0.2, fps: 8 }, 16000), null);
});

test("automatic quality probes upwards after a full stable minute and missing stats do not upgrade", () => {
  const { context } = fixture();
  const policy = new context.MacMonitorQuality.AdaptiveQuality("auto", 0);
  for (let i = 1; i < 30; i++) assert.equal(policy.sample({ loss: 0, fps: 10, rtt: 0.04 }, i * 2000), null);
  assert.equal(policy.sample({ loss: 0, fps: 10, rtt: 0.04 }, 60000).id, "original");
  const unknown = new context.MacMonitorQuality.AdaptiveQuality("auto", 0);
  for (let i = 1; i < 60; i++) assert.equal(unknown.sample({}, i * 2000), null);
  assert.equal(unknown.profile.id, "balanced");
});

test("manual profiles never silently change quality, including retries", () => {
  const { context } = fixture();
  const policy = new context.MacMonitorQuality.AdaptiveQuality("original", 0);
  for (let i = 1; i < 8; i++) { assert.equal(policy.sample({ stalled: true, loss: 0.9 }, i * 20000), null); policy.failure(i * 20000); }
  assert.equal(policy.profile.id, "original");
});

test("video stats use interval deltas and do not treat counter resets as bandwidth", () => {
  const { context } = fixture();
  const { videoStats } = context.MacMonitorQuality;
  const first = videoStats(report(1000, 1000, 10, 100, 2), null);
  const next = videoStats(report(3000, 101000, 30, 200, 7), first.current);
  assert.equal(next.kbps, 400);
  assert.equal(next.fps, 10);
  assert.equal(next.loss, 5 / 105);
  assert.equal(next.rtt, 0.04);
  assert.equal(videoStats(report(4000, 500, 1, 1, 0), next.current).kbps, undefined);
});

test("player gathers ICE in its authenticated SDP POST, uses no relay and closes old resources", async () => {
  const { player, requests, peers, video, intervals } = fixture("low");
  await player.connect();
  assert.equal(peers.length, 1);
  assert.equal(peers[0].options.iceServers.length, 0);
  const post = requests.find((r) => r.options.method === "POST");
  assert.equal(post.url, "https://camera.example/live/live-low/whep");
  assert.equal(post.options.credentials, "same-origin");
  assert.equal(post.options.headers["Content-Type"], "application/sdp");
  assert.equal(peers[0].remoteDescription.type, "answer");
  assert.ok(video.srcObject);
  player.close();
  assert.equal(peers[0].closed, true);
  assert.equal(video.srcObject, null);
  assert.equal(intervals.size, 0);
  assert.equal(requests.filter((r) => r.options.method === "DELETE").length, 1);
});

test("untrusted WHEP locations cannot cause requests outside the authenticated namespace", async () => {
  for (const location of ["https://evil.example/live/live/whep/id", "/api/logout", "/live/live/whep/id?secret=1"]) {
    const { player, api, requests, peers } = fixture();
    api.location = location;
    await player.connect();
    assert.equal(peers[0].closed, true);
    assert.equal(requests.some((r) => r.url.includes("evil.example")), false);
    assert.equal(requests.some((r) => r.url === "/api/logout"), false);
  }
});

test("a WHEP response after close is deleted without attaching media or reopening the player", async () => {
  const { player, api, video, intervals, requests } = fixture();
  api.blockPost = true;
  const pending = player.connect();
  await flush();
  player.close(); api.releasePost(); await pending;
  assert.equal(video.srcObject, null);
  assert.equal(intervals.size, 0);
  assert.equal(requests.filter((r) => r.options.method === "DELETE").length, 1);
});

test("failed connections downgrade in automatic mode and stop after four retries", async () => {
  const { player, api, retry, status, timeouts } = fixture();
  api.postStatus = 503;
  await player.connect();
  assert.equal(player.policy.profile.id, "low");
  for (let i = 0; i < 4; i++) await retry();
  assert.equal(player.failures, 5);
  assert.match(status.textContent, /복구하지 못했습니다/);
  assert.equal(timeouts.size, 0);
});

test("auth expiry closes a standalone player and never retries an unauthorized SDP request", async () => {
  const f = fixture();
  await f.player.connect();
  f.api.authenticated = false;
  for (let i = 0; i < 5; i++) await f.player.sample(f.player.generation);
  assert.equal(f.player.closed, true);
  assert.equal(f.video.srcObject, null);
  const other = fixture(); other.api.postStatus = 401;
  await other.player.connect();
  assert.equal(other.player.closed, true);
  assert.equal(other.timeouts.size, 0);
});

test("a paused video is not a network stall; a frozen playing video triggers recovery", async () => {
  const f = fixture();
  await f.player.connect();
  f.api.report = report(1000, 10000, 10);
  await f.player.sample(f.player.generation);
  f.video.paused = true; f.advance(20000);
  await f.player.sample(f.player.generation);
  assert.equal(f.player.failures, 0);
  f.video.paused = false; f.advance(13000);
  await f.player.sample(f.player.generation);
  assert.equal(f.player.failures, 1);
  assert.equal(f.player.policy.profile.id, "low");
});

test("a successful SDP exchange without a first frame has a bounded startup timeout", async () => {
  const f = fixture();
  await f.player.connect();
  f.player.hasPlayed = false; f.video.paused = true;
  f.advance(16000);
  await f.player.sample(f.player.generation);
  assert.equal(f.player.failures, 1);
  assert.match(f.status.textContent, /첫 영상/);
});

test("background suspension closes the peer and resumes only after rechecking the session", async () => {
  const f = fixture();
  await f.player.connect();
  f.player.suspend();
  assert.equal(f.video.srcObject, null);
  assert.equal(f.peers[0].closed, true);
  const count = f.requests.length;
  await f.player.connect();
  assert.equal(f.requests.length, count);
  f.api.authenticated = false;
  f.player.resume(); await flush();
  assert.equal(f.player.closed, true);
  assert.equal(f.peers.length, 1);
});

test("BFCache lifecycle releases resources and restores only after one fresh authentication check", async () => {
  const f = fixture("low", { auto: true });
  await flush();
  assert.equal(f.peers.length, 1);
  assert.match(f.requests.find((r) => r.options.method === "POST").url, /live-low/);
  f.event("pagehide", { persisted: true });
  assert.equal(f.peers[0].closed, true);
  assert.equal(f.video.srcObject, null);
  assert.equal(f.intervals.size, 0);
  assert.equal(f.requests.filter((r) => r.options.method === "DELETE").length, 1);
  const before = f.requests.length;
  // A visible event before pageshow must not start a connection from the cached page.
  f.visibility(false);
  assert.equal(f.requests.length, before);
  f.api.blockSession = true;
  f.event("pageshow", { persisted: true });
  f.visibility(false);
  f.event("pageshow", { persisted: true });
  assert.equal(f.requests.length, before + 1);
  assert.equal(f.requests.at(-1).url, "/api/session");
  assert.equal(f.peers.length, 1);
  f.api.releaseSessions.shift()(); await flush();
  assert.equal(f.peers.length, 2);
  assert.equal(f.peers[1].closed, undefined);
  assert.equal(f.requests.filter((r) => r.options.method === "POST").length, 2);
  assert.equal(f.intervals.size, 1);
});

test("a hidden BFCache restore waits for visibility before authentication and reconnect", async () => {
  const f = fixture("auto", { auto: true });
  await flush();
  f.visibility(true);
  f.event("pagehide", { persisted: true });
  const count = f.requests.length;
  f.event("pageshow", { persisted: true }); await flush();
  assert.equal(f.requests.length, count);
  f.visibility(false); await flush();
  assert.equal(f.requests[count].url, "/api/session");
  assert.equal(f.peers.length, 2);
});

test("BFCache restore with an expired session does not create another peer or SDP request", async () => {
  const f = fixture("auto", { auto: true });
  await flush();
  f.event("pagehide", { persisted: true });
  f.api.authenticated = false;
  f.event("pageshow", { persisted: true }); await flush();
  f.visibility(true); f.visibility(false); await flush();
  assert.match(f.status.textContent, /로그인이 필요/);
  assert.equal(f.peers.length, 1);
  assert.equal(f.requests.filter((r) => r.options.method === "POST").length, 1);
  assert.equal(f.intervals.size, 0);
  assert.equal(f.timeouts.size, 0);
});

test("ordinary unload remains permanent even if later lifecycle events are delivered", async () => {
  const f = fixture("auto", { auto: true });
  await flush();
  f.event("pagehide", { persisted: false });
  const count = f.requests.length;
  f.event("pageshow", { persisted: true });
  f.visibility(true); f.visibility(false); await flush();
  assert.equal(f.requests.length, count);
  assert.equal(f.peers.length, 1);
  assert.equal(f.video.srcObject, null);
  assert.equal(f.intervals.size, 0);
});

test("a stale authentication response after BFCache restore cannot close or reconnect the new session", async () => {
  const f = fixture("auto", { auto: true, api: { blockSession: true, authenticated: false } });
  const staleAuth = f.api.releaseSessions.shift();
  const oldRequest = f.requests[0];
  f.event("pagehide", { persisted: true });
  assert.equal(oldRequest.options.signal.aborted, true);
  f.api.blockSession = false; f.api.authenticated = true;
  f.event("pageshow", { persisted: true }); await flush();
  assert.equal(f.peers.length, 1);
  staleAuth(); await flush();
  assert.equal(f.peers.length, 1);
  assert.equal(f.peers[0].closed, undefined);
  assert.equal(f.intervals.size, 1);
  assert.doesNotMatch(f.status.textContent, /로그인이 필요/);
  assert.equal(f.timeouts.size, 0);
});

test("a late pre-cache SDP success deletes only its old session and cannot attach media", async () => {
  const f = fixture("auto", { auto: true, api: { blockPost: true } });
  await flush();
  const releaseOld = f.api.releasePost;
  f.event("pagehide", { persisted: true });
  f.api.blockPost = false;
  f.event("pageshow", { persisted: true }); await flush();
  const restoredMedia = f.video.srcObject;
  releaseOld(); await flush();
  assert.equal(f.video.srcObject, restoredMedia);
  assert.equal(f.peers[0].remoteDescription, undefined);
  assert.equal(f.peers[1].closed, undefined);
  const deletions = f.requests.filter((r) => r.options.method === "DELETE");
  assert.equal(deletions.length, 1);
  assert.match(deletions[0].url, /session-1$/);
  assert.equal(f.intervals.size, 1);
  assert.equal(f.timeouts.size, 0);
});

test("a late pre-cache unauthorized SDP response does not close the restored connection", async () => {
  const f = fixture("auto", { auto: true, api: { blockPost: true, postStatus: 401 } });
  await flush();
  const releaseOld = f.api.releasePost;
  f.event("pagehide", { persisted: true });
  f.api.blockPost = false; f.api.postStatus = 201;
  f.event("pageshow", { persisted: true }); await flush();
  releaseOld(); await flush();
  assert.equal(f.peers[1].closed, undefined);
  assert.ok(f.video.srcObject);
  assert.equal(f.intervals.size, 1);
  assert.doesNotMatch(f.status.textContent, /만료/);
});

test("BFCache lifecycle does not reset an exhausted retry budget", async () => {
  const f = fixture("auto", { auto: true, api: { postStatus: 503 } });
  await flush();
  for (let i = 0; i < 4; i++) { await f.retry(); await flush(); }
  assert.match(f.status.textContent, /복구하지 못했습니다/);
  const count = f.requests.length;
  f.event("pagehide", { persisted: true });
  f.event("pageshow", { persisted: true });
  f.visibility(true); f.visibility(false); await flush();
  assert.equal(f.requests.length, count);
  assert.equal(f.peers.length, 5);
  assert.equal(f.timeouts.size, 0);
  assert.match(f.status.textContent, /복구하지 못했습니다/);
});

test("concurrent startup calls share a single authentication check", async () => {
  const f = fixture();
  f.api.blockSession = true;
  const first = f.player.start(), second = f.player.start();
  assert.equal(f.requests.length, 1);
  f.api.releaseSessions.shift()();
  await Promise.all([first, second]); await flush();
  assert.equal(f.peers.length, 1);
  assert.equal(f.requests.filter((r) => r.options.method === "POST").length, 1);
});
