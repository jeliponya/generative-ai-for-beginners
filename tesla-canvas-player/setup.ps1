# TeslaPlay Kurulum Scripti - Windows PowerShell
# Kullanim: ./setup.ps1 -RepoUrl https://github.com/KULLANICI_ADI/tesla-canvas-player.git

param(
    [string]$RepoUrl = ""
)

Write-Host ""
Write-Host "=== TeslaPlay Kurulum Scripti ===" -ForegroundColor Cyan
Write-Host ""

# Klasor olustur
$projectDir = "tesla-canvas-player"
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
New-Item -ItemType Directory -Force -Path "$projectDir\public" | Out-Null
Set-Location $projectDir

Write-Host "[1/5] Dosyalar olusturuluyor..." -ForegroundColor Yellow

# ── package.json ──────────────────────────────────────────────────────────────
@'
{
  "name": "tesla-canvas-player",
  "version": "1.0.0",
  "description": "Tesla surusu halinde Canvas ile YouTube oynatici",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "ws": "^8.16.0"
  },
  "engines": {
    "node": ">=18"
  }
}
'@ | Set-Content package.json -Encoding UTF8

# ── .gitignore ─────────────────────────────────────────────────────────────────
@'
node_modules/
.env
*.log
'@ | Set-Content .gitignore -Encoding UTF8

# ── server.js ─────────────────────────────────────────────────────────────────
@'
const express = require("express");
const { WebSocketServer, WebSocket } = require("ws");
const { spawn } = require("child_process");
const http = require("http");
const https = require("https");
const path = require("path");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws/video" });

app.use(express.static(path.join(__dirname, "public")));
app.use(express.json());

// Bagimlilik kontrolu
// ffmpeg: -version (tek tire), yt-dlp: --version (cift tire)
function checkDependency(cmd, args) {
  return new Promise((resolve) => {
    const proc = spawn(cmd, args, { shell: true });
    proc.on("close", (code) => resolve(code === 0));
    proc.on("error", () => resolve(false));
  });
}

app.get("/api/check", async (req, res) => {
  const [ytdlp, ffmpeg] = await Promise.all([
    checkDependency("yt-dlp", ["--version"]),
    checkDependency("ffmpeg", ["-version"]),
  ]);
  res.json({ ytdlp, ffmpeg, ok: ytdlp && ffmpeg });
});

// Ses proxy - <audio> Tesla drive modunda calismaya devam eder
app.get("/api/audio", (req, res) => {
  const youtubeUrl = req.query.url;
  if (!youtubeUrl) return res.status(400).json({ error: "URL eksik" });

  const ytDlp = spawn("yt-dlp", [
    "-f", "bestaudio[ext=m4a]/bestaudio",
    "--get-url",
    "--no-playlist",
    youtubeUrl,
  ], { shell: true });

  let audioUrl = "";
  ytDlp.stdout.on("data", (d) => (audioUrl += d.toString()));
  ytDlp.stderr.on("data", () => {});

  ytDlp.on("close", (code) => {
    audioUrl = audioUrl.trim().split("\n")[0];
    if (code !== 0 || !audioUrl) {
      return res.status(500).json({ error: "Ses URL alinamadi" });
    }
    const lib = audioUrl.startsWith("https") ? https : http;
    lib.get(audioUrl, { headers: { "User-Agent": "Mozilla/5.0" } }, (audioRes) => {
      res.setHeader("Content-Type", audioRes.headers["content-type"] || "audio/mp4");
      res.setHeader("Cache-Control", "no-cache");
      audioRes.pipe(res);
      res.on("close", () => audioRes.destroy());
    }).on("error", () => res.status(500).json({ error: "Ses proxy hatasi" }));
  });
});

// Video frame WebSocket
// Tesla <video> elementini bloklar ama <canvas> gecer.
// FFmpeg -> JPEG kareler -> WebSocket -> canvas.drawImage()
wss.on("connection", (ws, req) => {
  const params = new URL(req.url, "http://localhost").searchParams;
  const youtubeUrl = params.get("url");
  if (!youtubeUrl) return ws.close(1008, "URL eksik");

  console.log("[+] Yeni baglanti:", youtubeUrl);
  let ffmpegProc = null;

  const ytDlp = spawn("yt-dlp", [
    "-f", "best[height<=480][ext=mp4]/best[height<=480]/best",
    "--get-url",
    "--no-playlist",
    youtubeUrl,
  ], { shell: true });

  let videoUrl = "";
  ytDlp.stdout.on("data", (d) => (videoUrl += d.toString()));
  ytDlp.stderr.on("data", () => {});

  ytDlp.on("close", (code) => {
    videoUrl = videoUrl.trim().split("\n")[0];
    if (code !== 0 || !videoUrl) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "error", msg: "Video URL alinamadi" }));
        ws.close();
      }
      return;
    }

    console.log("[~] FFmpeg baslatiliyor...");
    ffmpegProc = spawn("ffmpeg", [
      "-i", videoUrl,
      "-vf", "fps=24,scale=640:-2",
      "-f", "image2pipe",
      "-vcodec", "mjpeg",
      "-q:v", "5",
      "-an",
      "pipe:1",
    ], { shell: true });

    let buf = Buffer.alloc(0);

    ffmpegProc.stdout.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      while (true) {
        const soi = buf.indexOf(Buffer.from([0xff, 0xd8]));
        if (soi === -1) { buf = Buffer.alloc(0); break; }
        const eoi = buf.indexOf(Buffer.from([0xff, 0xd9]), soi + 2);
        if (eoi === -1) break;
        const frame = buf.slice(soi, eoi + 2);
        buf = buf.slice(eoi + 2);
        if (ws.readyState === WebSocket.OPEN) ws.send(frame);
      }
    });

    ffmpegProc.stderr.on("data", () => {});
    ffmpegProc.on("close", () => {
      console.log("[-] FFmpeg kapandi");
      if (ws.readyState === WebSocket.OPEN) ws.close();
    });
  });

  ws.on("close", () => { if (ffmpegProc) ffmpegProc.kill(); });
  ws.on("error", () => { if (ffmpegProc) ffmpegProc.kill(); });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log("\n Tesla Canvas Player calisiyor");
  console.log("   Adres  : http://localhost:" + PORT);
  console.log("   Tesla  : Tarayicidan bu adrese gir ve YouTube URL yapistir\n");
});
'@ | Set-Content server.js -Encoding UTF8

# ── public/index.html ─────────────────────────────────────────────────────────
@'
<!DOCTYPE html>
<html lang="tr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <title>TeslaPlay</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { background: #0a0a0a; color: #fff; font-family: -apple-system, sans-serif; height: 100vh; overflow: hidden; display: flex; align-items: center; justify-content: center; }
    #input-screen { display: flex; flex-direction: column; align-items: center; gap: 18px; width: 100%; max-width: 520px; padding: 32px 24px; }
    .logo { font-size: 28px; font-weight: 200; letter-spacing: 6px; color: #e82127; }
    .logo span { color: #fff; }
    .subtitle { font-size: 13px; color: #555; letter-spacing: 1px; text-transform: uppercase; }
    #url-input { width: 100%; padding: 15px 18px; font-size: 15px; background: #161616; border: 1px solid #2a2a2a; border-radius: 10px; color: #fff; outline: none; transition: border-color 0.2s; }
    #url-input::placeholder { color: #444; }
    #url-input:focus { border-color: #e82127; }
    #play-btn { width: 100%; padding: 15px; background: #e82127; color: #fff; border: none; border-radius: 10px; font-size: 17px; font-weight: 500; cursor: pointer; }
    #play-btn:disabled { background: #2a2a2a; color: #555; cursor: not-allowed; }
    #status { font-size: 13px; color: #666; min-height: 18px; text-align: center; }
    #status.error { color: #e82127; }
    #dep-warning { font-size: 12px; color: #aa6600; background: #1a1100; border: 1px solid #332200; border-radius: 8px; padding: 10px 14px; display: none; width: 100%; line-height: 1.5; }
    #player-screen { display: none; flex-direction: column; width: 100vw; height: 100vh; background: #000; position: fixed; top: 0; left: 0; }
    #canvas { flex: 1; width: 100%; display: block; background: #000; }
    #bottom-bar { display: flex; align-items: center; padding: 8px 16px; background: rgba(0,0,0,0.85); gap: 12px; height: 46px; }
    #back-btn { background: none; border: 1px solid #333; color: #ccc; padding: 6px 14px; border-radius: 6px; cursor: pointer; font-size: 13px; }
    #fps-badge { margin-left: auto; font-size: 11px; color: #444; }
    .spinner { display: inline-block; width: 14px; height: 14px; border: 2px solid #333; border-top-color: #e82127; border-radius: 50%; animation: spin 0.8s linear infinite; vertical-align: middle; margin-right: 6px; }
    @keyframes spin { to { transform: rotate(360deg); } }
    audio { display: none; }
  </style>
</head>
<body>
  <div id="input-screen">
    <div class="logo">TESLA<span>PLAY</span></div>
    <div class="subtitle">Canvas Video Oynatici</div>
    <div id="dep-warning"></div>
    <input id="url-input" type="url" placeholder="YouTube URL yapistir..." autocomplete="off" autocorrect="off" spellcheck="false" />
    <button id="play-btn">Oynat</button>
    <div id="status"></div>
  </div>
  <div id="player-screen">
    <canvas id="canvas"></canvas>
    <audio id="audio" autoplay></audio>
    <div id="bottom-bar">
      <button id="back-btn">Geri</button>
      <span id="loading-indicator"></span>
      <span id="fps-badge"></span>
    </div>
  </div>
  <script src="player.js"></script>
</body>
</html>
'@ | Set-Content public\index.html -Encoding UTF8

# ── public/player.js ─────────────────────────────────────────────────────────
@'
const inputScreen      = document.getElementById("input-screen");
const playerScreen     = document.getElementById("player-screen");
const canvas           = document.getElementById("canvas");
const ctx              = canvas.getContext("2d");
const audio            = document.getElementById("audio");
const urlInput         = document.getElementById("url-input");
const playBtn          = document.getElementById("play-btn");
const statusEl         = document.getElementById("status");
const backBtn          = document.getElementById("back-btn");
const loadingIndicator = document.getElementById("loading-indicator");
const fpsBadge         = document.getElementById("fps-badge");
const depWarning       = document.getElementById("dep-warning");

let ws = null, animFrameId = null;
const frameQueue = [];
let frameCount = 0, lastFpsCheck = Date.now(), firstFrame = true;

function setStatus(msg, type) { statusEl.textContent = msg; statusEl.className = type || ""; }
function setLoading(msg) { loadingIndicator.innerHTML = msg ? "<span class='spinner'></span>" + msg : ""; }

(async () => {
  try {
    const data = await fetch("/api/check").then(r => r.json());
    if (!data.ok) {
      const missing = [];
      if (!data.ytdlp) missing.push("yt-dlp");
      if (!data.ffmpeg) missing.push("ffmpeg");
      depWarning.style.display = "block";
      depWarning.textContent = "Eksik bagimlilik: " + missing.join(", ") + ". Lutfen yukleyin.";
      playBtn.disabled = true;
    }
  } catch {}
})();

function renderLoop() {
  animFrameId = requestAnimationFrame(renderLoop);
  if (!frameQueue.length) return;
  const bitmap = frameQueue.shift();
  if (firstFrame) {
    firstFrame = false;
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    inputScreen.style.display = "none";
    playerScreen.style.display = "flex";
    setLoading("");
    audio.play().catch(() => {});
  }
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  frameCount++;
  const now = Date.now();
  if (now - lastFpsCheck >= 1000) {
    fpsBadge.textContent = frameCount + " fps";
    frameCount = 0; lastFpsCheck = now;
  }
}

function startPlayer(youtubeUrl) {
  playBtn.disabled = true; firstFrame = true; frameQueue.length = 0;
  setStatus(""); setLoading("Baglanıyor...");
  audio.src = "/api/audio?url=" + encodeURIComponent(youtubeUrl);
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(proto + "//" + location.host + "/ws/video?url=" + encodeURIComponent(youtubeUrl));
  ws.binaryType = "arraybuffer";
  ws.onopen = () => setLoading("Video hazirlaniyor...");
  ws.onmessage = async (event) => {
    if (typeof event.data === "string") {
      try { const m = JSON.parse(event.data); if (m.type === "error") { setLoading(""); setStatus(m.msg, "error"); playBtn.disabled = false; } } catch {}
      return;
    }
    try {
      const bitmap = await createImageBitmap(new Blob([event.data], { type: "image/jpeg" }));
      if (frameQueue.length < 12) frameQueue.push(bitmap); else bitmap.close();
    } catch {}
  };
  ws.onerror = () => { setLoading(""); setStatus("Baglanti hatasi", "error"); playBtn.disabled = false; };
  ws.onclose = () => { setLoading(""); playBtn.disabled = false; };
  if (animFrameId) cancelAnimationFrame(animFrameId);
  renderLoop();
}

function stopPlayer() {
  if (ws) { ws.close(); ws = null; }
  if (animFrameId) { cancelAnimationFrame(animFrameId); animFrameId = null; }
  while (frameQueue.length) frameQueue.shift().close();
  audio.pause(); audio.src = "";
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  playerScreen.style.display = "none";
  inputScreen.style.display = "flex";
  playBtn.disabled = false; fpsBadge.textContent = "";
  setStatus(""); setLoading("");
}

playBtn.addEventListener("click", () => {
  const url = urlInput.value.trim();
  if (!url) return setStatus("Lutfen bir YouTube URL girin", "error");
  startPlayer(url);
});
backBtn.addEventListener("click", stopPlayer);
urlInput.addEventListener("keydown", e => { if (e.key === "Enter") playBtn.click(); });
'@ | Set-Content public\player.js -Encoding UTF8

Write-Host "[2/5] npm install yapiliyor..." -ForegroundColor Yellow
npm install --silent

Write-Host "[3/5] Git baslatiliyor..." -ForegroundColor Yellow
git init
git add .
git commit -m "ilk commit: TeslaPlay canvas video oynatici"

if ($RepoUrl -ne "") {
    Write-Host "[4/5] GitHub'a push yapiliyor..." -ForegroundColor Yellow
    git branch -M main
    git remote add origin $RepoUrl
    git push -u origin main
    Write-Host "[5/5] Tamamlandi!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Repo: $RepoUrl" -ForegroundColor Cyan
} else {
    Write-Host "[4/5] GitHub repo URL verilmedi, manual push gerekiyor:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  git branch -M main" -ForegroundColor White
    Write-Host "  git remote add origin https://github.com/KULLANICI_ADIN/tesla-canvas-player.git" -ForegroundColor White
    Write-Host "  git push -u origin main" -ForegroundColor White
}

Write-Host ""
Write-Host "Calistirmak icin: node server.js" -ForegroundColor Cyan
Write-Host "Tarayicida: http://localhost:3000" -ForegroundColor Cyan
Write-Host ""
