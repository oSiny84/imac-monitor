(() => {
  "use strict";
  const profiles = [
    { id: "low", path: "live-low", label: "절약 360p / 8fps", fps: 8 },
    { id: "balanced", path: "live-balanced", label: "표준 480p / 10fps", fps: 10 },
    { id: "original", path: "live", label: "원본 스트림", fps: 15 },
  ];
  class AdaptiveQuality {
    constructor(mode = "auto", now = 0) {
      this.automatic = mode === "auto";
      this.level = this.automatic ? 1 : Math.max(0, profiles.findIndex((p) => p.id === mode));
      this.changedAt = now; this.bad = 0; this.good = 0;
    }
    get profile() { return profiles[this.level]; }
    resetEvidence() { this.bad = 0; this.good = 0; }
    changed(now) { this.changedAt = now; this.resetEvidence(); }
    failure(now) {
      if (this.automatic && this.level > 0) this.level--;
      this.changed(now);
      return this.profile;
    }
    sample(value, now) {
      if (!this.automatic || !value) return null;
      const bad = value.stalled || value.loss > 0.08 || value.rtt > 0.7 || value.drop > 0.2 ||
        Number.isFinite(value.fps) && value.fps < this.profile.fps * 0.5;
      const good = !bad && Number.isFinite(value.loss) && value.loss < 0.01 &&
        Number.isFinite(value.fps) && value.fps >= this.profile.fps * 0.8 &&
        (!Number.isFinite(value.rtt) || value.rtt < 0.3);
      this.bad = bad ? this.bad + 1 : 0;
      this.good = good ? this.good + 1 : 0;
      if (this.bad >= 2 && this.level > 0 && now - this.changedAt >= 10000) {
        this.level--; this.changed(now); return this.profile;
      }
      // Probe one step up only after ~60 seconds of good 2-second samples. A
      // healthy low-rate stream cannot prove spare bandwidth; a probe can fall back.
      if (this.good >= 30 && this.level < profiles.length - 1 && now - this.changedAt >= 60000) {
        this.level++; this.changed(now); return this.profile;
      }
      return null;
    }
  }
  function videoStats(report, previous) {
    let inbound = null, pair = null;
    report.forEach((value) => {
      if (value.type === "inbound-rtp" && (value.kind === "video" || value.mediaType === "video") && !value.isRemote &&
          (!inbound || value.bytesReceived > inbound.bytesReceived)) inbound = value;
      if (value.type === "transport" && value.selectedCandidatePairId) pair = report.get(value.selectedCandidatePairId) || pair;
      if (!pair && value.type === "candidate-pair" && value.nominated && value.state === "succeeded") pair = value;
    });
    if (!inbound) return null;
    const current = { timestamp: inbound.timestamp, bytes: inbound.bytesReceived, packets: inbound.packetsReceived,
      lost: inbound.packetsLost, frames: inbound.framesDecoded, dropped: inbound.framesDropped };
    const result = { current, rtt: pair?.currentRoundTripTime };
    const seconds = previous ? (current.timestamp - previous.timestamp) / 1000 : 0;
    if (!Number.isFinite(seconds) || seconds <= 0 || current.bytes < previous?.bytes || current.packets < previous?.packets) return result;
    const delta = (key) => Number.isFinite(current[key]) && Number.isFinite(previous[key]) ? Math.max(0, current[key] - previous[key]) : undefined;
    result.kbps = delta("bytes") * 8 / seconds / 1000;
    result.fps = delta("frames") / seconds;
    const packets = delta("packets"), lost = delta("lost"), frames = delta("frames"), dropped = delta("dropped");
    result.loss = Number.isFinite(packets) && Number.isFinite(lost) ? lost / Math.max(1, packets + lost) : undefined;
    result.drop = Number.isFinite(frames) && Number.isFinite(dropped) ? dropped / Math.max(1, frames + dropped) : undefined;
    return result;
  }
  globalThis.MacMonitorQuality = { profiles, AdaptiveQuality, videoStats };
})();
