# ⚡ TeslaPlay — Canvas Tabanlı YouTube Oynatıcı

Tesla seyir halindeyken `<video>` elementini bloklar. Bu proje bunu `<canvas>` ile aşar.

## Nasıl Çalışır?

```
Tesla <video> → ❌ Engellenir
Tesla <canvas> → ✅ Çalışır

YouTube URL
    ↓
[Sunucu] yt-dlp → video stream URL
    ↓
[FFmpeg] → JPEG kareler (24fps)
    ↓
[WebSocket] → Tesla tarayıcısına binary gönder
    ↓
[Canvas] ctx.drawImage() → "Video" görüntüsü
    ↓
[Audio] <audio> proxy → Ses ayrı çalışır
```

Tesla sistemi sadece `<video>` elementini tanıdığı için, canvas üzerindeki hızlı JPEG karelerini "video" olarak görmez.

## Kurulum

### 1. Bağımlılıklar

```bash
# yt-dlp
pip install yt-dlp
# veya
brew install yt-dlp

# FFmpeg
apt install ffmpeg
# veya
brew install ffmpeg

# Node.js paketleri
npm install
```

### 2. Başlat

```bash
npm start
# → http://localhost:3000
```

### 3. Tesla'da Kullan

Tesla tarayıcısında `http://SUNUCU_IP:3000` adresine git, YouTube URL'si yapıştır, Oynat'a bas.

## Proje Yapısı

```
tesla-canvas-player/
├── server.js          # Express + WebSocket sunucu
├── package.json
└── public/
    ├── index.html     # Tesla'ya optimize UI
    └── player.js      # Canvas player + WebSocket client
```

## API

| Endpoint | Açıklama |
|----------|----------|
| `GET /` | Ana sayfa |
| `GET /api/check` | yt-dlp + ffmpeg kontrolü |
| `GET /api/audio?url=` | Ses proxy akışı |
| `WS /ws/video?url=` | JPEG kare stream'i |

## Teknik Detaylar

- **Video**: `FFmpeg -f image2pipe -vcodec mjpeg` → JPEG stream → WebSocket binary
- **Kare ayrıştırma**: `0xFF 0xD8` (SOI) → `0xFF 0xD9` (EOI) marker'ları
- **Render**: `createImageBitmap()` → `requestAnimationFrame` → `ctx.drawImage()`
- **Ses**: yt-dlp audio URL → Node.js proxy → `<audio autoplay>`
- **FPS**: 24fps (Tesla browser için dengeli)
- **Çözünürlük**: 640px genişlik (Tesla ekranına uygun)
