(() => {
  "use strict";
  class LivePlayer {
    constructor(video, status, metrics, mode) {
      this.video = video; this.status = status; this.metrics = metrics;
      this.policy = new MacMonitorQuality.AdaptiveQuality(mode, Date.now());
      this.generation = 0; this.closed = false; this.failures = 0;
      this.pc = null; this.resource = null; this.timer = null; this.retry = null; this.abort = null;
      this.previous = null; this.progress = null; this.lastProgress = 0; this.goodTicks = 0; this.ticks = 0;
      this.hasPlayed = false; this.autoplayBlocked = false; this.startedAt = 0;
      this.suspended = false;
    }
    async start() {
      if (typeof RTCPeerConnection === "undefined") { this.status.textContent = "이 브라우저는 WebRTC를 지원하지 않습니다."; return; }
      const generation = this.generation;
      const authAbort = new AbortController();
      const timeout = setTimeout(() => authAbort.abort(), 5000);
      try {
        const response = await fetch("/api/session", { credentials: "same-origin", signal: authAbort.signal });
        const session = response.ok ? await response.json() : null;
        if (this.closed || this.suspended || generation !== this.generation) return;
        if (!session?.authenticated) { this.close(); this.status.textContent = "로그인이 필요합니다."; return; }
        if (!this.closed) this.connect();
      } catch { if (!this.closed && generation === this.generation) this.status.textContent = "인증 확인 실패 · 상위 화면에서 다시 연결하세요."; }
      finally { clearTimeout(timeout); }
    }
    sessionURL(location, endpoint) {
      if (!location) throw new Error("영상 세션 주소가 없습니다.");
      const url = new URL(location, endpoint);
      if (url.origin !== globalThis.location.origin || !/^\/live\/(live|live-balanced|live-low)\/whep\/[a-zA-Z0-9-]+$/.test(url.pathname) || url.search || url.hash) {
        throw new Error("허용되지 않은 영상 세션 주소입니다.");
      }
      return url.href;
    }
    removeSession(resource) {
      if (resource) fetch(resource, { method: "DELETE", credentials: "same-origin", keepalive: true }).catch(() => {});
    }
    clearCurrent() {
      if (this.timer) clearInterval(this.timer); this.timer = null;
      if (this.retry) clearTimeout(this.retry); this.retry = null;
      this.abort?.abort(); this.abort = null;
      if (this.pc) { this.pc.ontrack = null; this.pc.onconnectionstatechange = null; this.pc.close(); this.pc = null; }
      this.removeSession(this.resource); this.resource = null;
      this.video.pause(); this.video.srcObject = null;
      this.previous = null; this.progress = null; this.goodTicks = 0; this.ticks = 0;
      this.hasPlayed = false; this.autoplayBlocked = false;
    }
    close() { this.closed = true; this.generation++; this.clearCurrent(); }
    suspend() { this.suspended = true; this.generation++; this.clearCurrent(); this.status.textContent = "백그라운드 · 영상 수신 일시 중단"; }
    resume() { if (!this.closed && this.suspended) { this.suspended = false; this.policy.changed(Date.now()); if (this.failures <= 4) this.start(); } }
    async gather(pc, signal) {
      if (pc.iceGatheringState === "complete") return;
      await new Promise((resolve, reject) => {
        const done = (error) => {
          clearTimeout(timeout); pc.removeEventListener("icegatheringstatechange", change); signal.removeEventListener("abort", abort);
          error ? reject(error) : resolve();
        };
        const change = () => { if (pc.iceGatheringState === "complete") done(); };
        const abort = () => done(new Error("연결 취소"));
        const timeout = setTimeout(() => done(new Error("ICE 후보 수집 시간 초과")), 6000);
        pc.addEventListener("icegatheringstatechange", change); signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) abort(); else change();
      });
    }
    async connect() {
      if (this.closed || this.suspended) return;
      const generation = ++this.generation;
      this.clearCurrent();
      const profile = this.policy.profile;
      this.status.textContent = `${this.policy.automatic ? "자동 · " : ""}${profile.label} 연결 중…`;
      this.metrics.textContent = "화질 전환은 원본 녹화에 영향을 주지 않습니다.";
      const abort = new AbortController(); this.abort = abort;
      abort.signal.addEventListener("abort", () => {
        if (!this.closed && generation === this.generation) this.failed(generation, new Error("영상 연결 시간 초과"));
      }, { once: true });
      const deadline = setTimeout(() => abort.abort(), 25000);
      try {
        const pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: "max-bundle" }); this.pc = pc;
        pc.addTransceiver("video", { direction: "recvonly" });
        pc.ontrack = (event) => {
          if (this.closed || generation !== this.generation) return;
          this.video.srcObject = event.streams[0] || new MediaStream([event.track]);
          this.video.play().then(() => { if (generation === this.generation) this.hasPlayed = true; }).catch(() => {
            if (generation === this.generation) { this.autoplayBlocked = true; this.status.textContent = "영상의 재생 버튼을 눌러주세요."; }
          });
        };
        pc.onconnectionstatechange = () => {
          if (generation === this.generation && pc.connectionState === "failed") this.failed(generation, new Error("직접 영상 연결 실패"));
        };
        await pc.setLocalDescription(await pc.createOffer());
        await this.gather(pc, abort.signal);
        if (generation !== this.generation || this.closed) return;
        const endpoint = new URL(`/live/${profile.path}/whep`, globalThis.location.origin).href;
        const response = await fetch(endpoint, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/sdp" },
          body: pc.localDescription.sdp, signal: abort.signal });
        if (response.status === 401) { this.close(); this.status.textContent = "로그인이 만료되었습니다."; return; }
        if (response.status !== 201) throw new Error(`영상 연결 응답 ${response.status}`);
        const resource = this.sessionURL(response.headers.get("Location"), endpoint);
        if (generation !== this.generation || this.closed) { this.removeSession(resource); return; }
        this.resource = resource;
        const answer = await response.text();
        if (generation !== this.generation || this.closed) return;
        await pc.setRemoteDescription({ type: "answer", sdp: answer });
        if (generation !== this.generation || this.closed) return;
        this.lastProgress = Date.now();
        this.startedAt = Date.now();
        this.status.textContent = `${this.policy.automatic ? "자동 · " : ""}${profile.label} · 수신 대기`;
        let sampling = false;
        this.timer = setInterval(async () => {
          if (sampling || generation !== this.generation) return;
          sampling = true;
          try { await this.sample(generation); } finally { sampling = false; }
        }, 2000);
      } catch (error) {
        if (!this.closed && generation === this.generation) this.failed(generation, error);
      } finally { clearTimeout(deadline); }
    }
    failed(generation, error) {
      if (this.closed || generation !== this.generation) return;
      this.generation++; this.clearCurrent(); this.failures++;
      if (this.failures > 4) { this.status.textContent = "영상 연결을 복구하지 못했습니다. 주소·포트·카메라 상태를 확인하고 다시 연결하세요."; return; }
      this.policy.failure(Date.now());
      this.status.textContent = `${error.message} · ${this.policy.profile.label} 재시도 ${this.failures}/4`;
      this.retry = setTimeout(() => this.connect(), Math.min(1000 * 2 ** this.failures, 8000));
    }
    async sample(generation) {
      if (this.closed || generation !== this.generation || !this.pc) return;
      // Standalone player tabs also revalidate authentication, not only their parent.
      if (++this.ticks % 5 === 0) {
        try {
          const authAbort = new AbortController();
          const timeout = setTimeout(() => authAbort.abort(), 5000);
          let response;
          try { response = await fetch("/api/session", { credentials: "same-origin", signal: authAbort.signal }); }
          finally { clearTimeout(timeout); }
          const session = response.ok ? await response.json() : null;
          if (generation !== this.generation) return;
          if (!session?.authenticated) { this.close(); this.status.textContent = "로그인이 만료되었습니다."; return; }
        } catch { this.failed(generation, new Error("인증 상태 확인 실패")); return; }
      }
      let measurement = null;
      try { measurement = MacMonitorQuality.videoStats(await this.pc.getStats(), this.previous); } catch { /* Progress timeout still detects a frozen player. */ }
      if (generation !== this.generation || this.closed) return;
      if (measurement) this.previous = measurement.current;
      if (!this.hasPlayed && !this.autoplayBlocked) {
        if (Date.now() - this.startedAt >= 15000) this.failed(generation, new Error("첫 영상 수신 시간 초과"));
        else this.status.textContent = `${this.policy.profile.label} · 첫 영상 대기 중`;
        return;
      }
      const progress = Number.isFinite(measurement?.current.frames) ? measurement.current.frames : this.video.currentTime;
      const playing = !this.video.paused;
      if (!playing || progress !== this.progress && Number.isFinite(progress)) { this.lastProgress = Date.now(); this.progress = progress; }
      const stalled = playing && Date.now() - this.lastProgress >= 12000;
      if (!playing) { this.policy.resetEvidence(); this.goodTicks = 0; this.status.textContent = "재생 대기 또는 일시정지 · 재생 버튼을 눌러주세요."; return; }
      const fmt = (value, suffix) => Number.isFinite(value) ? `${value.toFixed(1)}${suffix}` : "—";
      const profile = this.policy.profile;
      this.status.textContent = `${this.policy.automatic ? "자동 · " : ""}${profile.label}${stalled ? " · 수신 정지" : " · 재생 중"}`;
      this.metrics.textContent = `수신 ${fmt(measurement?.kbps, " kbps")} · ${fmt(measurement?.fps, " fps")} · 손실 ${fmt(measurement?.loss * 100, "%")} · RTT ${fmt(measurement?.rtt * 1000, " ms")}`;
      const next = this.policy.sample({ ...measurement, stalled }, Date.now());
      if (next) { this.connect(); return; }
      if (stalled) { this.failed(generation, new Error("새 영상 프레임 없음")); return; }
      if (Number.isFinite(measurement?.fps) && measurement.fps > 0) this.goodTicks++; else this.goodTicks = 0;
      if (this.goodTicks >= 8) this.failures = 0;
    }
  }
  globalThis.MacMonitorLivePlayer = LivePlayer;
  const video = document.querySelector("#remote-video");
  if (video) {
    const requested = new URLSearchParams(globalThis.location.search).get("quality");
    const mode = ["auto", "original", "balanced", "low"].includes(requested) ? requested : "auto";
    const player = new LivePlayer(video, document.querySelector("#player-status"), document.querySelector("#player-metrics"), mode);
    globalThis.addEventListener("pagehide", () => player.close());
    document.addEventListener("visibilitychange", () => { if (document.hidden) player.suspend(); else player.resume(); });
    if (document.hidden) player.suspend(); else player.start();
  }
})();
