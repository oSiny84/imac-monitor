(() => {
  "use strict";

  const state = { csrfToken: "", liveLoaded: false };
  const loginPanel = document.querySelector("#login-panel");
  const app = document.querySelector("#app");
  const connection = document.querySelector("#connection");
  const loginForm = document.querySelector("#login-form");
  const loginError = document.querySelector("#login-error");
  const livePlayer = document.querySelector("#live-player");
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
    if (!response.ok) throw new Error(body?.error || `요청 실패 (${response.status})`);
    return body;
  }

  function showAuthenticated(session) {
    state.csrfToken = session.csrfToken;
    loginPanel.hidden = true;
    app.hidden = false;
    connection.textContent = "인증됨";
    connection.classList.add("online");
    loadLive();
    refreshStatus();
  }

  function showLogin() {
    state.csrfToken = "";
    state.liveLoaded = false;
    livePlayer.removeAttribute("src");
    app.hidden = true;
    loginPanel.hidden = false;
    connection.textContent = "로그인 필요";
    connection.classList.remove("online");
  }

  function loadLive() {
    livePlayer.src = `/live/live/?controls=true&muted=true&autoplay=true&t=${Date.now()}`;
    state.liveLoaded = true;
  }

  async function refreshStatus() {
    try {
      const status = await request("/api/status");
      mediaStatus.textContent = status.mediaReachable ? "영상 서버 연결됨" : "영상 서버 응답 없음";
      mediaStatus.classList.toggle("online", status.mediaReachable);
    } catch (error) {
      mediaStatus.textContent = error.message;
      mediaStatus.classList.remove("online");
    }
  }

  async function refreshRecordings() {
    recordingsContainer.replaceChildren();
    recordingsEmpty.hidden = true;
    try {
      const result = await request("/api/recordings");
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
  document.querySelector("#reload-live").addEventListener("click", () => { loadLive(); refreshStatus(); });
  document.querySelector("#refresh-recordings").addEventListener("click", refreshRecordings);

  for (const tab of document.querySelectorAll(".tab")) {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((item) => item.classList.toggle("active", item === tab));
      const live = tab.dataset.view === "live";
      document.querySelector("#live-view").hidden = !live;
      document.querySelector("#recordings-view").hidden = live;
      if (!live) refreshRecordings();
    });
  }

  request("/api/session").then((session) => {
    if (session.authenticated) showAuthenticated(session); else showLogin();
  }).catch(() => showLogin());
})();
