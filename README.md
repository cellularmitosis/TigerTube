# TigerTube

A native Cocoa YouTube client for **Mac OS X 10.4 Tiger on PowerPC**,
paired with a transcoding proxy that runs on a modern host.

![TigerTube 0.3 screenshot](media/tigertube-0.3.png)

## How it works

TigerTube is split across two machines:

- **`TigerTube.app` (on a PowerPC Mac)** bundles its own openssl so it
  can reach modern HTTPS, and talks directly to YouTube's Data API
  for search, metadata, and thumbnails.
- **`tigertube-proxy.py` (on a modern laptop)** uses `yt-dlp` to resolve
  a video and `ffmpeg` to transcode it in real-time to MPEG-1 video +
  PCM audio — formats which even a G3 can
  keep up with.

When you click a search result, the client opens two HTTP streams to
the proxy (one video, one audio) and decodes them live.

## Running the release build

Grab [TigerTube-0.3.zip](https://github.com/cellularmitosis/TigerTube/releases/tag/v0.3)
from the Releases page. It contains:

- `TigerTube.app` — PowerPC Release build, targets 10.4+
- `proxy/tigertube-proxy.py` — transcoding proxy (Python 3,
  `yt-dlp`, `ffmpeg`, `zeroconf`)

### 1. Start the proxy on a modern host

Requires Python 3, `ffmpeg`, `yt-dlp`, and `python-zeroconf`:

```sh
pip install yt-dlp zeroconf
python3 proxy/tigertube-proxy.py
```

The proxy listens on port `5002` and advertises itself via mDNS.

### 2. Launch TigerTube.app on the Tiger Mac

TigerTube will auto-discover the proxy on a healthy LAN — no configuration needed.
The window title shows which proxy it found (e.g. `uranium.local:5002`).

## Player keyboard controls

| Key         | Action                  |
|-------------|-------------------------|
| Space       | Pause / resume          |
| `f`         | Toggle fullscreen       |
| `ESC`       | Exit fullscreen / close |
| `q`         | Quit player             |
| `←` / `→`   | Seek ±15 s              |
| `↓` / `↑`   | Seek ±60 s              |

## What's new in 0.3

See [the v0.3 release notes](https://github.com/cellularmitosis/TigerTube/releases/tag/v0.3)
for the full list. Highlights:

- **Transport bar** under the video — play/pause button, draggable
  scrub slider, and live time/duration label. Spacebar also pauses.
- **Skip-decode under A/V drift** — on CPU-bound playback libmpeg2
  drops to I-frames-only when it falls more than 0.5 s behind the
  audio clock, then resumes full decode once caught up. Keeps A/V
  tight on 640x480+ instead of accumulating drift.
- **Dropped-frames counter** above the search field reflects
  source-timeline frames the viewer never saw, derived from the
  audio clock (not just internal queue overflow).
- **Bring-your-own API key** via `~/.tigertube/youtube-api-key.txt`
  to bypass the shared default quota.
- **Leaner proxy** — `yt-dlp` used as a library, Flask dependency
  dropped, fail-fast install hints when `ffmpeg` or `zeroconf` is
  missing.

## What's new in 0.2

See [the v0.2 release notes](https://github.com/cellularmitosis/TigerTube/releases/tag/v0.2)
for the full list. Highlights:

- **Bonjour proxy discovery** — the client auto-finds the proxy on the
  LAN via `_tigertube-proxy._tcp` (mDNS). No hardcoded IPs.
- **mplayer-style keyboard seeking** — `←`/`→` = ±15 s, `↓`/`↑` = ±60 s.
- **Resolution + quality dropdowns** under the search field (240x180
  through 640x480; MPEG-1 qscale 2–8).
- **Quality-mode (VBR) transcode** in the proxy — `q=N` for
  constant-quality VBR instead of CBR, avoiding pixelation spikes on
  high-motion frames.

## Known good on

- 600 MHz iMac G3 (PowerPC G3, no AltiVec, ATI Rage 128 Pro, 10.4)

320x240 is rock solid.  400x300 will drop some frames but is watchable.
Video is drawn using OpenGL, so fullscreen scaling is free (press "f"),
even on a Rage 128 Pro.

Should work on any PowerPC Mac running 10.4 or later.  This release is
intended for G3 processors (MPEG-1 video at small resolutions, uncompressed audio).
Later releases will include better codecs for Altivec-class Macs.

## YouTube API key

TigerTube ships with a built-in YouTube Data API v3 key so it works
out of the box, but the key's daily quota (~100 searches) is shared
across everyone running the app. If you start seeing search errors
about usage limits, create your own key and drop it in a plain text
file at `~/.tigertube/youtube-api-key.txt` — TigerTube reads that
path on startup and uses it in place of the built-in key, no rebuild
required.

Create a key at the [Google Cloud Console](https://console.cloud.google.com/)
(enable "YouTube Data API v3" under APIs & Services). The free quota
for a personal key is 10,000 units/day, enough for ~100 searches
per day on your own.

## Building from source

You'll need a PowerPC Mac running 10.4 with Xcode 2.5 installed.
Before the first build, create `src/Secrets.h` containing your own
YouTube Data API v3 key:

```c
#define YOUTUBE_API_KEY "abc123..."
```

See the YouTube API key section above for how to obtain a key.
At runtime the compiled-in key is used as a
default but is overridden by `~/.tigertube/youtube-api-key.txt` if
that file exists.

Then from the repo root on the Tiger Mac:

```sh
xcodebuild -configuration Debug     # or Release
```

All native dependencies (libcurl, OpenSSL, libmpeg2) are vendored under
`libs/` as PowerPC static builds. SBJson (backported to Objective-C 1.0)
is vendored under `SBJson-2.2.3/`.
