const express = require('express');
const { WebSocketServer, WebSocket } = require('ws');
const { spawn } = require('child_process');
const http = require('http');
const https = require('https');
const path = require('path');

const app = express();
const server = http.createServer(app);

// Video frame WebSocket sunucusu
const wss = new WebSocketServer({ server, path: '/ws/video' });

app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());

// ─── Bağımlılık Kontrolü ───────────────────────────────────────────────────
// ffmpeg: -version (tek tire), yt-dlp: --version (çift tire)
function checkDependency(cmd, args) {
  return new Promise((resolve) => {
    const proc = spawn(cmd, args);
    proc.on('close', (code) => resolve(code === 0));
    proc.on('error', () => resolve(false));
  });
}

app.get('/api/check', async (req, res) => {
  const [ytdlp, ffmpeg] = await Promise.all([
    checkDependency('yt-dlp', ['--version']),
    checkDependency('ffmpeg', ['-version']),   // ffmpeg tek tire kullanır
  ]);
  res.json({ ytdlp, ffmpeg, ok: ytdlp && ffmpeg });
});

// ─── Ses Proxy ─────────────────────────────────────────────────────────────
// <audio> elementi Tesla'da çalışır, yt-dlp ile ses URL'sini alıp proxy'leriz
app.get('/api/audio', (req, res) => {
  const youtubeUrl = req.query.url;
  if (!youtubeUrl) return res.status(400).json({ error: 'URL eksik' });

  const ytDlp = spawn('yt-dlp', [
    '-f', 'bestaudio[ext=m4a]/bestaudio',
    '--get-url',
    '--no-playlist',
    youtubeUrl,
  ]);

  let audioUrl = '';
  ytDlp.stdout.on('data', (d) => (audioUrl += d.toString()));
  ytDlp.stderr.on('data', () => {});

  ytDlp.on('close', (code) => {
    audioUrl = audioUrl.trim().split('\n')[0]; // ilk URL
    if (code !== 0 || !audioUrl) {
      return res.status(500).json({ error: 'Ses URL alınamadı' });
    }

    // YouTube CDN'den sesi proxy'le
    const lib = audioUrl.startsWith('https') ? https : http;
    lib
      .get(audioUrl, { headers: { 'User-Agent': 'Mozilla/5.0' } }, (audioRes) => {
        res.setHeader('Content-Type', audioRes.headers['content-type'] || 'audio/mp4');
        res.setHeader('Cache-Control', 'no-cache');
        audioRes.pipe(res);
        res.on('close', () => audioRes.destroy());
      })
      .on('error', () => res.status(500).json({ error: 'Ses proxy hatası' }));
  });
});

// ─── Video Frame WebSocket ──────────────────────────────────────────────────
//
// Nasıl çalışır:
//   1. yt-dlp → YouTube video stream URL'sini alır
//   2. FFmpeg → video'yu MJPEG (seri JPEG kareler) olarak pipe eder
//   3. Her JPEG kare → WebSocket üzerinden binary olarak gönderilir
//   4. Tesla tarayıcısı → <canvas> üzerine çizer (Tesla <video> değil!)
//
wss.on('connection', (ws, req) => {
  const params = new URL(req.url, 'http://localhost').searchParams;
  const youtubeUrl = params.get('url');

  if (!youtubeUrl) return ws.close(1008, 'URL eksik');

  console.log(`[+] Yeni bağlantı: ${youtubeUrl}`);

  let ffmpegProc = null;

  // Adım 1: yt-dlp ile video stream URL'si al
  const ytDlp = spawn('yt-dlp', [
    '-f', 'best[height<=480][ext=mp4]/best[height<=480]/best',
    '--get-url',
    '--no-playlist',
    youtubeUrl,
  ]);

  let videoUrl = '';
  ytDlp.stdout.on('data', (d) => (videoUrl += d.toString()));
  ytDlp.stderr.on('data', () => {});

  ytDlp.on('close', (code) => {
    videoUrl = videoUrl.trim().split('\n')[0];

    if (code !== 0 || !videoUrl) {
      safeSend(ws, JSON.stringify({ type: 'error', msg: 'Video URL alınamadı' }));
      return ws.close();
    }

    console.log(`[~] Video URL alındı, FFmpeg başlatılıyor...`);

    // Adım 2: FFmpeg ile JPEG kareler üret
    ffmpegProc = spawn('ffmpeg', [
      '-i', videoUrl,
      '-vf', 'fps=24,scale=640:-2',   // 24fps, 640px genişlik
      '-f', 'image2pipe',              // JPEG frame pipe
      '-vcodec', 'mjpeg',
      '-q:v', '5',                     // JPEG kalitesi (2=en iyi, 31=en kötü)
      '-an',                           // ses yok (ayrı akıyor)
      'pipe:1',
    ]);

    // Adım 3: JPEG karelerini WebSocket ile gönder
    let buf = Buffer.alloc(0);

    ffmpegProc.stdout.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);

      // MJPEG stream içinden tam JPEG karelerini ayıkla
      // JPEG: SOI = 0xFF 0xD8 ... EOI = 0xFF 0xD9
      while (true) {
        const soi = buf.indexOf(Buffer.from([0xff, 0xd8]));
        if (soi === -1) { buf = Buffer.alloc(0); break; }

        const eoi = buf.indexOf(Buffer.from([0xff, 0xd9]), soi + 2);
        if (eoi === -1) break; // Kare henüz tamamlanmadı, bekle

        const frame = buf.slice(soi, eoi + 2);
        buf = buf.slice(eoi + 2);

        if (ws.readyState === WebSocket.OPEN) {
          ws.send(frame); // Binary JPEG kare gönder
        }
      }
    });

    ffmpegProc.stderr.on('data', () => {}); // FFmpeg log'larını bastır

    ffmpegProc.on('close', () => {
      console.log('[-] FFmpeg kapandı');
      if (ws.readyState === WebSocket.OPEN) ws.close();
    });
  });

  // Bağlantı kapanınca FFmpeg'i durdur
  ws.on('close', () => {
    console.log('[-] WebSocket kapandı');
    if (ffmpegProc) ffmpegProc.kill('SIGTERM');
  });

  ws.on('error', () => {
    if (ffmpegProc) ffmpegProc.kill('SIGTERM');
  });
});

function safeSend(ws, data) {
  if (ws.readyState === WebSocket.OPEN) ws.send(data);
}

// ─── Sunucu Başlat ──────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`\n⚡ Tesla Canvas Player çalışıyor`);
  console.log(`   Adres : http://localhost:${PORT}`);
  console.log(`   Tesla : Tarayıcıdan bu adrese gir ve YouTube URL'si yapıştır\n`);
});
