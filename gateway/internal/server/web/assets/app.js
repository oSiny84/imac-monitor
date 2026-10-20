(() => {
  "use strict";

  const state = { csrfToken: "", liveLoaded: false, view: "live", mediaReachable: null, statusCheck: 0, recordingsCheck: 0,
    recordingOffset: 0, recordingLimit: 50, recordingRange: {}, recordingsLoading: false, recordingHasMore: false,
    protectionWrites: new Set() };
  const loginPanel = document.querySelector("#login-panel");
  const app = document.querySelector("#app");
  const connection = document.querySelector("#connection");
  const loginForm = document.querySelector("#login-form");
  const loginError = document.querySelector("#login-error");
  const livePlayer = document.querySelector("#live-player");
  const liveUnavailable = document.querySelector("#live-unavailable");
  const mediaStatus = document.querySelector("#media-status");
  const monitorState = document.querySelector("#monitor-state");
  const monitorDetail = document.querySelector("#monitor-detail");
  const recordingsContainer = document.querySelector("#recordings");
  const recordingsEmpty = document.querySelector("#recordings-empty");
  const recordingTemplate = document.querySelector("#recording-template");
  const recordingFrom = document.querySelector("#recording-from");
  const recordingTo = document.querySelector("#recording-to");
  const recordingResults = document.querySelector("#recording-results");
  const previousRecordings = document.querySelector("#previous-recordings");
  const nextRecordings = document.querySelector("#next-recordings");
  const protectedOnly = document.querySelector("#protected-only");
  const protectionMessage = document.querySelector("#protection-message");
  document.querySelector("#recording-timezone").textContent = `날짜·시각 기준: 접속 기기 (${Intl.DateTimeFormat().resolvedOptions().timeZone}). 녹화 시작 시각으로 검색합니다.`;

  async function request(url, options = {}) {
    const headers = new Headers(options.headers || {});
    if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
    if (state.csrfToken && options.method && !["GET", "HEAD"].includes(options.method)) {
      headers.set("X-CSRF-Token", state.csrfToken);
    }
    const response = await fetch(url, { ...options, headers, credentials: "same-origin" });
    const type = response.headers.get("Content-Type") || "";
    const body = type.includes("application/json") ? await response.json() : null;
    if (!response.ok) {
      if (response.status === 401 && state.csrfToken) showLogin();
      throw new Error(body?.error || `요청 실패 (${response.status})`);
    }
    return body;
  }

  function showAuthenticated(session) {
    state.csrfToken = session.csrfToken;
    loginPanel.hidden = true;
    app.hidden = false;
    connection.textContent = "인증됨";
    connection.classList.add("online");
    state.mediaReachable = null;
    selectView("live");
    refreshStatus();
  }

  function showLogin() {
    state.csrfToken = "";
    state.statusCheck += 1;
    state.recordingsCheck += 1;
    state.mediaReachable = null;
    stopLive();
    liveUnavailable.hidden = true;
    renderHealth(null);
    clearRecordings();
    recordingFrom.value = "";
    recordingTo.value = "";
    protectedOnly.checked = false;
    state.protectionWrites = new Set();
    protectionMessage.textContent = "";
    document.querySelector("#protection-summary").textContent = "";
    document.querySelector("#protection-warning").hidden = true;
    state.recordingOffset = 0;
    state.recordingRange = {};
    state.recordingHasMore = false;
    state.recordingsLoading = false;
    recordingResults.textContent = "";
    updateRecordingPages();
    app.hidden = true;
    loginPanel.hidden = false;
    connection.textContent = "로그인 필요";
    connection.classList.remove("online");
  }

  function loadLive() {
    livePlayer.src = `/live/live/?controls=true&muted=true&autoplay=true&t=${Date.now()}`;
    state.liveLoaded = true;
  }

  function stopLive() {
    state.liveLoaded = false;
    livePlayer.removeAttribute("src");
  }

  function selectView(view) {
    state.view = view;
    document.querySelectorAll(".tab").forEach((item) => item.classList.toggle("active", item.dataset.view === view));
    document.querySelector("#live-view").hidden = view !== "live";
    document.querySelector("#recordings-view").hidden = view !== "recordings";
    if (view === "recordings") {
      stopLive();
      refreshRecordings();
    } else {
      for (const video of recordingsContainer.querySelectorAll("video")) video.pause();
    }
  }

  async function refreshStatus() {
    const session = state.csrfToken;
    if (!session) return;
    const check = ++state.statusCheck;
    try {
      const status = await request("/api/status");
      if (state.csrfToken !== session || check !== state.statusCheck) return;
      renderHealth(status.monitoring);
      const firstCheck = state.mediaReachable === null;
      const lostLive = state.mediaReachable === true && !status.mediaReachable;
      state.mediaReachable = Boolean(status.mediaReachable);
      liveUnavailable.hidden = state.mediaReachable;
      mediaStatus.textContent = status.mediaReachable ? "영상 서버 연결됨" : "실시간 연결 불가 · 저장된 녹화는 이용 가능";
      mediaStatus.classList.toggle("online", status.mediaReachable);
      if (status.mediaReachable) {
        if (state.view === "live" && !state.liveLoaded) loadLive();
      } else {
        stopLive();
        if (state.view === "live" && (firstCheck || lostLive)) selectView("recordings");
      }
    } catch (error) {
      if (state.csrfToken !== session || check !== state.statusCheck) return;
      mediaStatus.textContent = error.message;
      mediaStatus.classList.remove("online");
      renderHealth(null);
    }
  }

  function renderHealth(health) {
    const available = health?.available === true;
    const fresh = available && health.fresh === true;
    const receiving = fresh && health.state === "running" && health.frameState === "receiving";
    const labels = {
      starting: "감시 시작 중", stopped: "감시 중지", stopping: "감시 정리 중",
      scheduledRest: "예약 휴식 중", sleeping: "시스템 잠자기", recovering: "감시 복구 중", failed: "감시 오류",
    };
    let label = "상태 확인 불가";
    if (available && !fresh) label = "상태 갱신 지연";
    else if (fresh && health.state === "running") {
      label = receiving ? "새 프레임 수신 중" : health.frameState === "waiting" ? "첫 영상 대기 중" : "영상 프레임 정지 · 복구 확인 필요";
    } else if (fresh) label = labels[health.state] || label;
    monitorState.textContent = label;
    monitorState.classList.toggle("online", receiving);
    monitorState.classList.toggle("warning", !fresh || health?.frameState === "stalled" || health?.state === "failed");
    monitorDetail.textContent = available ? health.detail : "앱의 촬영 상태를 확인하지 못했습니다. 웹 접속 여부만으로 정상 촬영을 판단할 수 없습니다.";
    const fps = fresh && health.expectingFrames && Number.isFinite(health.captureFPS) ? `${health.captureFPS.toFixed(1)} fps` : "—";
    document.querySelector("#capture-fps").textContent = fps;
    document.querySelector("#last-frame").textContent = formatTime(health?.lastFrameAt);
    document.querySelector("#last-motion").textContent = formatTime(health?.lastMotionAt);
    document.querySelector("#last-recording").textContent = formatTime(health?.lastRecordingAt);
    document.querySelector("#disk-free").textContent = available && Number.isFinite(health.diskFreeBytes) ? formatBytes(health.diskFreeBytes) : "—";
    document.querySelector("#watchdog-count").textContent = available && Number.isInteger(health.watchdogRecoveries) ? `${health.watchdogRecoveries}회` : "—";
    const retentionWarning = document.querySelector("#retention-warning");
    retentionWarning.hidden = !available || !health.retentionWarning;
    retentionWarning.textContent = available && health.retentionWarning ? `${fresh ? "최근 보관 점검: " : "마지막 보고된 경고 (갱신 지연): "}${health.retentionWarning}` : "";
  }

  function formatTime(value) {
    if (!value) return "—";
    const date = new Date(value);
    if (!Number.isFinite(date.getTime())) return "—";
    return new Intl.DateTimeFormat("ko-KR", { dateStyle: "short", timeStyle: "medium" }).format(date);
  }

  async function refreshRecordings() {
    const session = state.csrfToken;
    if (!session) return;
    const check = ++state.recordingsCheck;
    clearRecordings();
    state.recordingsLoading = true;
    updateRecordingPages();
    recordingResults.textContent = "녹화 검색 중…";
    document.querySelector("#protection-summary").textContent = "보호 현황 확인 중…";
    recordingsEmpty.textContent = "조건에 맞는 녹화가 없습니다.";
    recordingsEmpty.hidden = true;
    try {
      const params = new URLSearchParams({ ...state.recordingRange, offset: state.recordingOffset, limit: state.recordingLimit });
      const result = await request(`/api/recordings?${params}`);
      if (state.csrfToken !== session || check !== state.recordingsCheck) return;
      recordingsEmpty.hidden = result.recordings.length !== 0;
      state.recordingHasMore = result.hasMore;
      document.querySelector("#protection-summary").textContent = `전체 보관함 보호: ${result.protectedCount}개 · ${formatBytes(result.protectedBytes)}`;
      const protectionWarning = document.querySelector("#protection-warning");
      protectionWarning.hidden = !result.protectionWarning;
      protectionWarning.textContent = result.protectionWarning || "";
      const start = result.recordings.length ? state.recordingOffset + 1 : 0;
      recordingResults.textContent = `총 ${result.total}개 · ${start}–${start ? state.recordingOffset + result.recordings.length : 0} 표시`;
      for (const recording of result.recordings) {
        const card = recordingTemplate.content.firstElementChild.cloneNode(true);
        card.querySelector(".recording-date").textContent = new Intl.DateTimeFormat("ko-KR", {
          dateStyle: "medium", timeStyle: "medium"
        }).format(new Date(recording.startedAt));
        card.querySelector(".recording-size").textContent = formatBytes(recording.sizeBytes);
        const video = card.querySelector("video");
        const download = card.querySelector(".recording-download");
        download.href = recording.downloadURL;
        download.download = recording.id;
        const protect = card.querySelector(".recording-protect");
        const protectionLabel = card.querySelector(".recording-protection-state");
        protect.textContent = recording.protected ? "보호 해제" : "중요 녹화로 보호";
        protect.disabled = !recording.protectionSupported || !recording.protectionAvailable || state.protectionWrites.has(recording.id);
        protectionLabel.textContent = !recording.protectionAvailable ? "보호 상태 확인 불가" :
          !recording.protectionSupported ? "정리 중 · 완성 후 보호 가능" : recording.protected ? "보호 중 · 자동 삭제 제외" : "보관 기준에 따라 자동 정리";
        protectionLabel.classList.toggle("protected", recording.protected && recording.protectionAvailable);
        protect.addEventListener("click", async () => {
          if (protect.disabled || state.protectionWrites.has(recording.id)) return;
          const targetProtected = !recording.protected;
          if (!targetProtected && !confirm("보호를 해제하면 다음 자동 정리에서 이 녹화가 삭제될 수 있습니다. 중요한 영상은 먼저 다운로드하세요. 보호를 해제할까요?")) return;
          const writes = state.protectionWrites;
          writes.add(recording.id);
          protect.disabled = true;
          protectionMessage.textContent = "보호 설정 저장 중…";
          try {
            await request(`/api/recordings/${encodeURIComponent(recording.id)}/protection`, {
              method: "PUT", body: JSON.stringify({ protected: targetProtected }),
            });
            if (state.csrfToken === session) protectionMessage.textContent = targetProtected ? "중요 녹화로 보호했습니다. 자동 삭제에서 제외됩니다." : "보호를 해제했습니다. 이제 자동 정리 대상입니다.";
          } catch (error) {
            if (state.csrfToken === session) protectionMessage.textContent = error.message;
          } finally {
            writes.delete(recording.id);
            if (state.csrfToken === session) refreshRecordings();
          }
        });
        const image = card.querySelector(".recording-thumbnail");
        const placeholder = card.querySelector(".thumbnail-placeholder");
        image.addEventListener("load", () => { placeholder.hidden = true; });
        image.addEventListener("error", () => {
          image.hidden = true;
          placeholder.hidden = false;
          placeholder.textContent = "미리보기 없음 · 재생 가능";
        });
        image.src = recording.thumbnailURL;
        card.querySelector(".recording-summary").addEventListener("click", () => {
          const opening = video.hidden;
          for (const other of recordingsContainer.querySelectorAll("video")) {
            if (other !== video) { other.pause(); other.hidden = true; other.removeAttribute("src"); other.load(); }
          }
          video.hidden = !opening;
          if (opening) video.src = recording.url;
          else { video.pause(); video.removeAttribute("src"); video.load(); }
        });
        video.hidden = true;
        recordingsContainer.append(card);
      }
    } catch (error) {
      if (state.csrfToken !== session || check !== state.recordingsCheck) return;
      recordingsEmpty.textContent = error.message;
      recordingsEmpty.hidden = false;
      recordingResults.textContent = "녹화 목록을 불러오지 못했습니다. 새로고침해 주세요.";
      document.querySelector("#protection-summary").textContent = "보호 현황 확인 불가";
      state.recordingHasMore = false;
    } finally {
      if (state.csrfToken === session && check === state.recordingsCheck) {
        state.recordingsLoading = false;
        updateRecordingPages();
      }
    }
  }

  function clearRecordings() {
    for (const video of recordingsContainer.querySelectorAll("video")) {
      video.pause(); video.removeAttribute("src"); video.load();
    }
    for (const image of recordingsContainer.querySelectorAll("img")) image.removeAttribute("src");
    recordingsContainer.replaceChildren();
  }

  function updateRecordingPages() {
    previousRecordings.disabled = state.recordingsLoading || state.recordingOffset === 0;
    nextRecordings.disabled = state.recordingsLoading || !state.recordingHasMore;
    document.querySelector("#recording-page").textContent = `${Math.floor(state.recordingOffset / state.recordingLimit) + 1} 페이지`;
  }

  function dateBoundary(value, nextDay) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("날짜를 확인해 주세요.");
    const date = new Date(`${value}T00:00:00`);
    const [year, month, day] = value.split("-").map(Number);
    if (!Number.isFinite(date.getTime()) || date.getFullYear() !== year || date.getMonth() + 1 !== month || date.getDate() !== day) throw new Error("날짜를 확인해 주세요.");
    if (nextDay) date.setDate(date.getDate() + 1); // Local calendar days, including DST.
    return date.toISOString();
  }

  document.querySelector("#recording-filter").addEventListener("submit", (event) => {
    event.preventDefault();
    try {
      if (recordingFrom.value && recordingTo.value && recordingFrom.value > recordingTo.value) throw new Error("시작 날짜가 끝 날짜보다 늦습니다.");
      const range = {};
      if (recordingFrom.value) range.from = dateBoundary(recordingFrom.value, false);
      if (recordingTo.value) range.to = dateBoundary(recordingTo.value, true);
      if (protectedOnly.checked) range.protected = "1";
      state.recordingRange = range;
      state.recordingOffset = 0;
      refreshRecordings();
    } catch (error) { recordingResults.textContent = error.message; }
  });
  document.querySelector("#clear-recording-filter").addEventListener("click", () => {
    recordingFrom.value = ""; recordingTo.value = ""; protectedOnly.checked = false;
    state.recordingRange = {}; state.recordingOffset = 0;
    refreshRecordings();
  });
  previousRecordings.addEventListener("click", () => {
    if (previousRecordings.disabled) return;
    state.recordingOffset = Math.max(0, state.recordingOffset - state.recordingLimit);
    refreshRecordings();
  });
  nextRecordings.addEventListener("click", () => {
    if (nextRecordings.disabled) return;
    state.recordingOffset += state.recordingLimit;
    refreshRecordings();
  });

  function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
    return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  }

  loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    loginError.textContent = "";
    const password = new FormData(loginForm).get("password");
    try {
      const session = await request("/api/login", { method: "POST", body: JSON.stringify({ password }) });
      loginForm.reset();
      showAuthenticated(session);
    } catch (error) {
      loginError.textContent = error.message;
    }
  });

  document.querySelector("#logout").addEventListener("click", async () => {
    try { await request("/api/logout", { method: "POST" }); } finally { showLogin(); }
  });
  document.querySelector("#reload-live").addEventListener("click", () => { stopLive(); refreshStatus(); });
  document.querySelector("#refresh-recordings").addEventListener("click", () => { state.recordingOffset = 0; refreshRecordings(); });

  for (const tab of document.querySelectorAll(".tab")) {
    tab.addEventListener("click", () => {
      selectView(tab.dataset.view);
      if (state.view === "live") refreshStatus();
    });
  }

  setInterval(() => {
    if (state.csrfToken && !document.hidden) refreshStatus();
  }, 5000);
  document.addEventListener("visibilitychange", () => {
    if (state.csrfToken && !document.hidden) refreshStatus();
  });

  request("/api/session").then((session) => {
    if (session.authenticated) showAuthenticated(session); else showLogin();
  }).catch(() => showLogin());
})();
