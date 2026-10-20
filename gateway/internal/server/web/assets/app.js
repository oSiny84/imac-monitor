(() => {
  "use strict";

  const state = { csrfToken: "", liveLoaded: false, view: "live", mediaReachable: null, statusCheck: 0, recordingsCheck: 0 };
  const loginPanel = document.querySelector("#login-panel");
  const app = document.querySelector("#app");
  const connection = document.querySelector("#connection");
  const loginForm = document.querySelector("#login-form");
  const loginError = document.querySelector("#login-error");
  const livePlayer = document.querySelector("#live-player");
  const liveUnavailable = document.querySelector("#live-unavailable");
  const mediaStatus = document.querySelector("#media-status");
  const recordingsContainer = document.querySelector("#recordings");
  const recordingsEmpty = document.querySelector("#recordings-empty");
  const recordingTemplate = document.querySelector("#recording-template");

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
    for (const video of recordingsContainer.querySelectorAll("video")) {
      video.pause();
      video.removeAttribute("src");
      video.load();
    }
    recordingsContainer.replaceChildren();
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
    }
  }

  async function refreshStatus() {
    const session = state.csrfToken;
    if (!session) return;
    const check = ++state.statusCheck;
    try {
      const status = await request("/api/status");
      if (state.csrfToken !== session || check !== state.statusCheck) return;
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
    }
  }

  async function refreshRecordings() {
    const session = state.csrfToken;
    if (!session) return;
    const check = ++state.recordingsCheck;
    recordingsContainer.replaceChildren();
    recordingsEmpty.textContent = "저장된 움직임 녹화가 없습니다.";
    recordingsEmpty.hidden = true;
    try {
      const result = await request("/api/recordings");
      if (state.csrfToken !== session || check !== state.recordingsCheck) return;
      recordingsEmpty.hidden = result.recordings.length !== 0;
      for (const recording of result.recordings) {
        const card = recordingTemplate.content.firstElementChild.cloneNode(true);
        card.querySelector(".recording-date").textContent = new Intl.DateTimeFormat("ko-KR", {
          dateStyle: "medium", timeStyle: "medium"
        }).format(new Date(recording.startedAt));
        card.querySelector(".recording-size").textContent = formatBytes(recording.sizeBytes);
        const video = card.querySelector("video");
        card.querySelector(".recording-summary").addEventListener("click", () => {
          const opening = video.hidden;
          for (const other of recordingsContainer.querySelectorAll("video")) {
            if (other !== video) { other.pause(); other.hidden = true; other.removeAttribute("src"); }
          }
          video.hidden = !opening;
          if (opening) video.src = recording.url;
          else { video.pause(); video.removeAttribute("src"); }
        });
        video.hidden = true;
        recordingsContainer.append(card);
      }
    } catch (error) {
      if (state.csrfToken !== session || check !== state.recordingsCheck) return;
      recordingsEmpty.textContent = error.message;
      recordingsEmpty.hidden = false;
    }
  }

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
  document.querySelector("#refresh-recordings").addEventListener("click", refreshRecordings);

  for (const tab of document.querySelectorAll(".tab")) {
    tab.addEventListener("click", () => {
      selectView(tab.dataset.view);
      if (state.view === "live") refreshStatus();
    });
  }

  setInterval(() => {
    if (state.csrfToken && !document.hidden) refreshStatus();
  }, 10000);
  document.addEventListener("visibilitychange", () => {
    if (state.csrfToken && !document.hidden) refreshStatus();
  });

  request("/api/session").then((session) => {
    if (session.authenticated) showAuthenticated(session); else showLogin();
  }).catch(() => showLogin());
})();
