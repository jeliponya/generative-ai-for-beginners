/**
 * TeslaPlay - Canvas Tabanlı YouTube Oynatıcı
 *
 * Tesla tarayıcısı seyir halinde <video> elementini bloklar.
 * Biz ise videoyu şöyle kandırıyoruz:
 *   Sunucu → FFmpeg → JPEG kareler → WebSocket → <canvas>.drawImage()
 *
 * Tesla "video yok" sanıyor, kullanıcı video izliyor.
 */

// ── DOM Referansları ──────────────────────────────────────────────────────────
const inputScreen      = document.getElementById('input-screen');
const playerScreen     = document.getElementById('player-screen');
const canvas           = document.getElementById('canvas');
const ctx              = canvas.getContext('2d');
const audio            = document.getElementById('audio');
const urlInput         = document.getElementById('url-input');
const playBtn          = document.getElementById('play-btn');
const statusEl         = document.getElementById('status');
const backBtn          = document.getElementById('back-btn');
const loadingIndicator = document.getElementById('loading-indicator');
const fpsBadge         = document.getElementById('fps-badge');
const depWarning       = document.getElementById('dep-warning');

// ── State ─────────────────────────────────────────────────────────────────────
let ws            = null;
let animFrameId   = null;
const frameQueue  = [];     // createImageBitmap ile çözülmüş kareler
let frameCount    = 0;
let lastFpsCheck  = Date.now();
let firstFrame    = true;

// ── Yardımcılar ───────────────────────────────────────────────────────────────
function setStatus(msg, type = '') {
  statusEl.textContent = msg;
  statusEl.className = type;
}

function setLoading(msg) {
  loadingIndicator.innerHTML = msg
    ? `<span class="spinner"></span>${msg}`
    : '';
}

// ── Başlangıç: Bağımlılık Kontrolü ───────────────────────────────────────────
(async () => {
  try {
    const res  = await fetch('/api/check');
    const data = await res.json();
    if (!data.ok) {
      const missing = [];
      if (!data.ytdlp)  missing.push('yt-dlp');
      if (!data.ffmpeg) missing.push('ffmpeg');
      depWarning.style.display = 'block';
      depWarning.textContent =
        `⚠ Eksik bağımlılık: ${missing.join(', ')}. ` +
        `Lütfen sunucuya yükleyin ve tekrar başlatın.`;
      playBtn.disabled = true;
    }
  } catch {
    // Sunucu henüz cevap vermiyorsa sessizce geç
  }
})();

// ── Canvas Render Döngüsü ─────────────────────────────────────────────────────
// requestAnimationFrame ile tarayıcı refresh hızında çizer.
// Kare kuyruğu doluysa bir sonraki hazır kareyi çizer.
function renderLoop() {
  animFrameId = requestAnimationFrame(renderLoop);

  if (frameQueue.length === 0) return;

  const bitmap = frameQueue.shift();

  // İlk karede canvas boyutunu ayarla ve ekrana geç
  if (firstFrame) {
    firstFrame = false;
    canvas.width  = bitmap.width;
    canvas.height = bitmap.height;

    inputScreen.style.display  = 'none';
    playerScreen.style.display = 'flex';
    setLoading('');
    setStatus('');

    // Sesi başlat (ilk kare gelince sync)
    audio.play().catch(() => {});
  }

  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close(); // Belleği serbest bırak

  // FPS hesapla
  frameCount++;
  const now = Date.now();
  if (now - lastFpsCheck >= 1000) {
    fpsBadge.textContent = `${frameCount} fps`;
    frameCount   = 0;
    lastFpsCheck = now;
  }
}

// ── Oynatıcıyı Başlat ─────────────────────────────────────────────────────────
function startPlayer(youtubeUrl) {
  playBtn.disabled = true;
  firstFrame = true;
  frameQueue.length = 0;
  setStatus('');
  setLoading('Bağlanıyor...');

  // 1. Ses: <audio> elementi ile proxy üzerinden aktar
  //    Tesla drive modunda <audio> çalışmaya devam eder
  audio.src = `/api/audio?url=${encodeURIComponent(youtubeUrl)}`;
  // Sesi ilk kare gelince play() ile başlatacağız (sync için)

  // 2. Video: WebSocket → JPEG kareler → Canvas
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(
    `${proto}//${location.host}/ws/video?url=${encodeURIComponent(youtubeUrl)}`
  );
  ws.binaryType = 'arraybuffer';

  ws.onopen = () => {
    setLoading('Video hazırlanıyor...');
  };

  ws.onmessage = async (event) => {
    // Sunucudan error mesajı gelebilir (JSON string)
    if (typeof event.data === 'string') {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'error') {
          setLoading('');
          setStatus(msg.msg, 'error');
          playBtn.disabled = false;
        }
      } catch { /* ignore */ }
      return;
    }

    // Binary → JPEG → ImageBitmap (GPU'ya yükle)
    const blob = new Blob([event.data], { type: 'image/jpeg' });
    let bitmap;
    try {
      bitmap = await createImageBitmap(blob);
    } catch {
      return; // Bozuk kare, atla
    }

    // Kuyruğu sınırla: çok dolmasın (bellek + gecikme)
    if (frameQueue.length < 12) {
      frameQueue.push(bitmap);
    } else {
      bitmap.close(); // Taşmayı önle
    }
  };

  ws.onerror = () => {
    setLoading('');
    setStatus('Bağlantı hatası', 'error');
    playBtn.disabled = false;
  };

  ws.onclose = () => {
    setLoading('');
    playBtn.disabled = false;
  };

  // 3. Render döngüsünü başlat
  if (animFrameId) cancelAnimationFrame(animFrameId);
  renderLoop();
}

// ── Oynatıcıyı Durdur ─────────────────────────────────────────────────────────
function stopPlayer() {
  if (ws) {
    ws.close();
    ws = null;
  }

  if (animFrameId) {
    cancelAnimationFrame(animFrameId);
    animFrameId = null;
  }

  // Kuyruktaki bitmap'leri temizle
  while (frameQueue.length) frameQueue.shift().close();

  audio.pause();
  audio.src = '';

  ctx.clearRect(0, 0, canvas.width, canvas.height);

  playerScreen.style.display = 'none';
  inputScreen.style.display  = 'flex';
  playBtn.disabled = false;
  fpsBadge.textContent = '';
  setStatus('');
  setLoading('');
}

// ── Olaylar ───────────────────────────────────────────────────────────────────
playBtn.addEventListener('click', () => {
  const url = urlInput.value.trim();
  if (!url) return setStatus('Lütfen bir YouTube URL\'si girin', 'error');
  startPlayer(url);
});

backBtn.addEventListener('click', stopPlayer);

urlInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') playBtn.click();
});

// Tesla'da ekrana uzun basınca paste menüsü çıkmaması için
// input alanına odaklanınca klavye açılır (Tesla'da sanal klavye)
urlInput.addEventListener('focus', () => {
  urlInput.placeholder = 'https://youtu.be/...';
});
