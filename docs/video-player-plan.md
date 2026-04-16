# TigerTube video player: design plan v1

Native video playback inside TigerTube, decoded with **libmpeg2** (video) and
played through **CoreAudio** (audio), rendered into a Cocoa window from
inside the app process. No MPlayer, no QuickTime playback, no external
viewer.

Targeting the 600 MHz iMac G3 (PowerPC G3, no AltiVec, ATI Rage 128 Pro 2
with 16 MB VRAM, Core Image and Quartz Extreme both unsupported, so the
window server is compositing in software).

Initial performance landmark: **320×240 @ 24 fps**. Audio: **44.1 kHz
stereo s16be PCM**; fallback to **44.1 kHz mono** if we're pinched on CPU
or bandwidth; do **not** drop the sample rate.


## Why libmpeg2 (vs. other decoders)

- Plain C99, autotools, no external deps.
- Builds trivially on darwin-ppc / gcc-4.0 / MacOSX10.4u.sdk.
- Static-links cleanly into the .app alongside curl and openssl.
- Ships a partner lib (`libmpeg2convert`) with ready-made YUV→RGB/UYVY
  converters — saves us writing a scaler.
- Single codec, single job: MPEG-1/2 video only. No process model,
  no framework runtime deps, ~100 KB of code.

ffmpeg 5.1.2 is already installed on imacg3 (`/opt/ffmpeg-5.1.2`) and is
useful for server-side transcoding and imacg3 benchmarking, but is *not*
a candidate for client-side decode — far too heavy for the .app bundle.


## Overall architecture: two raw streams, no container

Every previous transcoding-proxy experiment in `/Users/cell/junk/ppctube`
leaned on a container format (MPEG-TS, HLS, MOV, RTP) because the
playback side was QuickTime or MPlayer. Once we decode with libmpeg2
directly, the container becomes a liability — libmpeg2 is video-only
and doesn't demux anything, so every container means writing or
vendoring a demuxer on the Tiger side.

The simplest thing that works: **two HTTP endpoints per video**, each
served by its own `ffmpeg -ss T ...` subprocess on the proxy, producing
raw elementary streams with no container at all.

```
                        ┌─────────────────────────────┐
                        │       Proxy (modern Mac)    │
                        │                             │
                        │  GET /v/{id}?t=&w=&h=&br=   │
                        │  ───▶ ffmpeg -ss -c:v       │
                        │       mpeg1video -f         │
                        │       mpeg1video pipe:1     │
                        │                             │
                        │  GET /a/{id}?t=&rate=&ch=   │
                        │  ───▶ ffmpeg -ss -c:a       │
                        │       pcm_s16be -f s16be    │
                        │       pipe:1                │
                        └──────────┬──────────────────┘
                                   │  HTTP (two streams, same wall-clock origin)
         ┌─────────────────────────┴──────────────┐
         │              Tiger G3                  │
         │                                        │
         │  video curl ──▶ ring ──▶ libmpeg2 ──▶  │   frame queue
         │   (net thread)         (dec thread)    │        │
         │                                        │        │
         │  audio curl ──▶ ring ──▶ CoreAudio ──▶ │   ◀────┘ consults clock
         │   (net thread)          render cb      │
         │                         │              │   (present or drop)
         │                         ▼              │
         │                    output device       │
         └────────────────────────────────────────┘
                                   │
                            NSView / GL view
                            (frame present)
```

Key properties:

- **No demuxer on Tiger.** libmpeg2 takes raw ES bytes. PCM is the
  rawest possible audio.
- **Audio is the playback clock.** The number of samples consumed by
  CoreAudio, divided by the sample rate, is the master clock.
- **Seek = cancel both transfers, reopen with new `t=`.** Every
  previous attempt struggled with seeking *inside* a streaming
  container; here seeking is a stateless HTTP query parameter.
- **Backpressure is automatic.** TCP closes its window → ffmpeg blocks
  on write → decoder drains its buffer → audio drains its ring →
  everything slows together.
- **Pause** = stop the AudioUnit and stop draining the curl socket.
  Resume = restart the AU.

### Bandwidth budget

| Stream | Format | Rate |
|---|---|---|
| Video | MPEG-1 320×240 @ 24 fps @ 800 kbit/s | 100 KB/s |
| Audio | PCM s16be 44.1 kHz stereo | 176 KB/s |
| Total | | 276 KB/s |

Well within 100Base-TX (12.5 MB/s) and well within what a G3 can memcpy
around. If we fall back to mono audio: 188 KB/s total.


## Component plan (five parts)

### 1. libmpeg2: build & shipping

- **Version**: libmpeg2 **0.5.1** (2008-07-18).
- **Upstream**: `https://libmpeg2.sourceforge.io/files/libmpeg2-0.5.1.tar.gz`.
- **Build environment**: `/usr/bin/gcc-4.0`, `MacOSX10.4u.sdk`, on imacg3.
  Follows the standard DESTDIR-install + rsync-back pattern used by
  curl and openssl in `libs/`.
- **Install script**: new `install-libmpeg2-0.5.1.sh` **written into
  `TigerTube/proxy/` or `TigerTube/scripts/` initially — NOT committed
  to leopard.sh.** We will use the template at
  `~/github/cellularmitosis/leopard.sh/tigersh/scripts/templates/build-from-source.sh`
  as a starting point but the resulting script is a throwaway build
  helper that lives in TigerTube's repo for now. A skill for adding
  new /opt recipes to leopard.sh will be tackled in a later session.
- **Long-build protocol**: per the imacg3-dev skill — write the build
  into a script under `/Users/macuser/tmp/`, launch it backgrounded
  with `nohup ... &`, poll with `tail` + `ps`, never foreground.
- **Configure flags**:
  ```
  ./configure \
      --prefix=/usr/local \
      --disable-shared --enable-static \
      --disable-sdl \
      --without-x \
      CFLAGS="-O2 -mcpu=750 -fno-strict-aliasing"
  ```
  AltiVec is disabled by default on G3 (we have none). Omit `--disable-altivec`
  only if configure auto-detects correctly; otherwise pass it explicitly.
- **DESTDIR install**:
  ```
  make install DESTDIR=/Users/macuser/tmp/libmpeg2-install
  # → /Users/macuser/tmp/libmpeg2-install/usr/local/lib/libmpeg2.a
  # → /Users/macuser/tmp/libmpeg2-install/usr/local/lib/libmpeg2convert.a
  # → /Users/macuser/tmp/libmpeg2-install/usr/local/include/mpeg2dec/mpeg2.h
  # → /Users/macuser/tmp/libmpeg2-install/usr/local/include/mpeg2dec/mpeg2convert.h
  ```
- **Rsync back to main Mac**:
  ```
  ~/bin/tiger-rsync.sh --delete \
      imacg3:/Users/macuser/tmp/libmpeg2-install/usr/local/ \
      ~/github/cellularmitosis/TigerTube/libs/libmpeg2/
  # Result: TigerTube/libs/libmpeg2/lib/libmpeg2.a (and libmpeg2convert.a)
  # plus   TigerTube/libs/libmpeg2/include/mpeg2dec/*.h
  ```
- **pbxproj wiring**: add `libmpeg2.a` + `libmpeg2convert.a` via four
  sections each (PBXFileReference, PBXBuildFile, PBXFrameworksBuildPhase,
  HEADER_SEARCH_PATHS and LIBRARY_SEARCH_PATHS in both Debug and Release
  `XCBuildConfiguration` blocks). Same pattern as the existing
  `libcurl.a`, `libssl.a`, `libcrypto.a` entries.
- **Output pixel format: UYVY via `GL_APPLE_ycbcr_422`** (DECIDED).
  libmpeg2 outputs I420 (3 planes). We interleave to UYVY on the CPU
  (cheap byte shuffle, ~2 cycles/pixel) and upload via
  `glTexSubImage2D` with `GL_YCBCR_422_APPLE`. The Rage 128 Pro's
  texture unit does YUV→RGB in hardware.
- **Decode benchmark — PASSED**: `mpeg2dec -o null` on a 320×240 @
  24 fps @ 800k clip: **267 fps** (11.1× real-time). 480×360 @ 1500k:
  **120 fps** (5× real-time). Massive headroom at our target resolution.
- **Rendering benchmark — PASSED**: GL + UYVY upload measured **134 fps**
  at 640×480 window (5.6× real-time). GL + BGRA was 67 fps. Software
  blit was only 26 fps (barely above real-time). Decision: GL path (b1)
  with `GL_APPLE_ycbcr_422`.
- **Rage 128 Pro GL capabilities** (empirically verified):
  - GL 1.1, max texture 1024×1024, power-of-2 only (no NPOT, no RECT)
  - `GL_APPLE_ycbcr_422`: **YES**
  - `GL_APPLE_client_storage`: YES
  - `GL_EXT_bgra`: YES
  - `GL_ARB_fragment_program`: no (no shaders)
  - `GL_EXT_texture_rectangle`: no
  - `GL_ARB_texture_non_power_of_two`: no


### 2. Audio path: CoreAudio Default Output Unit

**Decision: CoreAudio Default Output Audio Unit, render-callback driven,
with raw s16be PCM on the wire.** No libmad. No QuickTime for audio.

The canonical idiom is Apple's
[PlayAudioFileLite sample](https://leopard-adc.pepas.com/samplecode/PlayAudioFileLite/),
which uses the Tiger-era APIs:

- `FindNextComponent` with a `ComponentDescription` specifying
  `kAudioUnitType_Output` / `kAudioUnitSubType_DefaultOutput` /
  `kAudioUnitManufacturer_Apple`.
- `OpenAComponent` to instantiate the unit.
- `AudioUnitSetProperty(kAudioUnitProperty_StreamFormat, ...)` to
  configure the unit's input format.
- `AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback, ...)` to
  install a render callback.
- `AudioUnitInitialize` then `AudioOutputUnitStart` to begin playback.

**Wire format**: signed 16-bit big-endian PCM, **44.1 kHz, stereo**.
Fallback only if CPU or bandwidth forces it: 44.1 kHz mono — do **not**
drop the sample rate.

**Render path**:
- The render callback pulls N frames from a lock-free SPSC ring buffer
  that the network thread is filling with curl bytes.
- The AU input format is Float32 stereo 44.1k — native CoreAudio
  preferred format. The render callback does the s16→Float32 conversion
  inline (one multiply per sample, ~8 cycles). Since we're on big-endian
  PowerPC, s16be is already native byte order — no swap needed.
- If the hardware's output sample rate differs from 44.1k (unlikely on
  Tiger, but possible), the Default Output Unit handles sample-rate
  conversion internally.

**Ring buffer sizing**: ~500 ms of audio = ~88 KB at 44.1k stereo s16.
Overflow means curl's write callback blocks, which is the correct
backpressure behavior.

**Pause**: `AudioOutputUnitStop`. Resume: `AudioOutputUnitStart`. Both
are Tiger-era API.

**Risk**: none significant — this is a well-worn path with direct Apple
sample code.

**Milestone test** (step 5 in the execution order): a ~50-line
standalone C program on imacg3 that curls a raw-PCM URL from the proxy
and plays it through the Default Output Unit, with no video path at
all. Verifies CoreAudio end-to-end before we entangle it with libmpeg2.


### 3. Rendering surface

Three candidates on Tiger/Rage 128 Pro:

#### (a) Software YUV→ARGB → `NSBitmapImageRep` → `drawInRect:`

Flow: libmpeg2 → Y/Cb/Cr planes → `mpeg2convert_rgb32` → ARGB buffer →
`NSBitmapImageRep initWithBitmapDataPlanes:` (non-copying wrapper) →
`[rep drawInRect:fromRect:operation:fraction:]` from the video view's
`drawRect:`. `setNeedsDisplay:YES` is triggered from the frame-delivery
path, not from a timer.

- **Pros**: cheapest to implement, no GL setup, no new framework link.
- **Cons**: Quartz Extreme unsupported on this card means the window
  server composites in software. Every scale-up from 320×240 → final
  window size goes through QuartzEngine's software blitter.

Budget estimate at 320×240:
- YUV420→ARGB ≈ 76 Kpix, naive C loop with clip table ~5-10 ms/frame.
- Software blit+scale to 640×480 ≈ 5-15 ms/frame.
- Decode leaves ~20-30 ms for everything else in a 41 ms (24 fps)
  budget. Probably fits. Marginal at larger window sizes.

#### (b) OpenGL texture upload + full-screen textured quad

Flow: `NSOpenGLView` with a `GL_TEXTURE_2D` of 512×256 (next-pow-2 above
320×240 for Rage 128 compat; sampler wraps the valid 320×240 region);
`glTexSubImage2D` per frame; `GL_QUADS` scaled to fill the window;
`[glContext flushBuffer]`.

Two sub-variants depending on extension support:

- **(b1)** If Rage 128 Pro supports `GL_YCBCR_422_APPLE`: CPU converts
  I420 → UYVY (a reorder, not color math, much cheaper than I420 → ARGB);
  upload as UYVY; driver does YUV→RGB in its fixed-function path. This
  is the fast path on pre-shader Macs **if the hardware has it** —
  empirically unknown.
- **(b2)** If it doesn't: CPU converts to BGRA; upload with `GL_BGRA` +
  `GL_UNSIGNED_INT_8_8_8_8_REV`. Same CPU cost as path (a), but the
  scale-up from 320×240 to window size happens on the GPU's texture
  unit — free — instead of hitting QuartzEngine's software blitter.

The existing GL-on-Tiger scaffolding in
`/Users/macuser/Desktop/junk/opengl/scratch/drawarrays/` already has a
working NSOpenGLView context setup we can borrow.

#### (c) QuickTime `ICMDecompressionSession` / Visual Context

In principle routes pre-decoded YUV frames through QuickTime's own
pipeline, possibly with hand-tuned YUV→RGB. In practice the setup code
is more than (a) and (b) combined, the APIs are quirky, and the path is
poorly documented. **Deprioritized unless (a) and (b) both fail.**

#### Recommendation

Build **(a)** and **(b2)** both, compare empirically, keep the faster
one. Measurements to run on imacg3, independent of libmpeg2 work and
parallelizable with it:

1. **GL extension probe**: ~50-line C program that creates an NSOpenGL
   context, reads `GL_VERSION`, `GL_RENDERER`, `GL_EXTENSIONS`.
   Definitively answers whether `APPLE_ycbcr_422` is available on this
   card. Also gives us the list of supported texture formats.
2. **Software blit microbench**: timer loop holding a fixed 320×240
   ARGB `NSBitmapImageRep`, drawing it into an `NSWindow` at 640×480 as
   fast as possible, measuring fps.
3. **GL upload microbench**: same loop, but via GL (`glTexSubImage2D`
   BGRA into a 512×256 texture, `glDrawArrays`, `flushBuffer`),
   measuring fps. Independent of decode cost.

Decision rule: if (a) sustains ≥ 24 fps at 640×480 it ships. If not,
(b2) wins provided its fps is higher. If neither sustains 24 fps at
640×480, we shrink the default window to 480×360 or 320×240 (native).


### 4. Threading & A/V sync

**Five threads:**

| Thread | Owns | In | Out |
|---|---|---|---|
| Main | UI, NSApp, window, view, menu, sync-loop timer | user events, frame-available notifications | view invalidation |
| VideoNet | curl handle for `/v/` | socket bytes | videoInRing |
| VideoDec | libmpeg2 state | videoInRing | frameQueue |
| AudioNet | curl handle for `/a/` | socket bytes | audioRing |
| AudioCallback | CoreAudio HAL (kernel-owned) | audioRing | hardware; increments `g_samplesOut` |

VideoNet and AudioNet are thin: `curl_easy_setopt` a WRITEFUNCTION that
pushes bytes into the ring and returns (or blocks on backpressure).

VideoDec runs libmpeg2's state machine, producing frames into a small
bounded `frameQueue` (3-4 frames deep). Blocks on the input ring when
starved and on the frameQueue when the decoder is ahead of display.

**The audio callback is the heartbeat.** Every render tick, it
increments `g_samplesOut` by the number of frames it consumed. The
playback clock is just `g_samplesOut / sampleRate`.

**Sync loop** (main thread, 60 Hz via `NSTimer` — or `CVDisplayLink` if
Tiger supports it, it does, 10.4+):

```
loop tick:
    clockSec = g_samplesOut / sampleRate
    while frameQueue not empty:
        nextFrame = peek(frameQueue)
        framePTS = nextFrame.index / frameRate
        if framePTS < clockSec - 1/frameRate:
            drop(frameQueue)                    // late — discard
            continue
        if framePTS > clockSec:
            break                               // too early — wait
        currentDisplayFrame = pop(frameQueue)
        [videoView setNeedsDisplay:YES]
        break
```

~20 lines. No container PTS math. No DTS-vs-PTS. libmpeg2 reorders
B-frames internally and emits in display order. The frame PTS is
`frame_index / frame_rate`, fully deterministic because the stream
always starts at frame 0 (the server does the seek, not the client).

**Seek protocol** (triggered by scrub-bar `mouseUp` or ±5 s keys):

1. Main thread: `player->seekRequestedSec = T`.
2. Main thread signals VideoNet and AudioNet to abort their curl
   transfers (WRITEFUNCTION returns 0 → CURL aborts).
3. Main thread waits for VideoNet, VideoDec, AudioNet to reach idle
   (condvar).
4. Main thread: `mpeg2_reset(decoder, 1)`, drain `videoInRing`, drain
   `audioRing`, drain `frameQueue`, `AudioOutputUnitStop`, zero
   `g_samplesOut`.
5. Main thread issues new GETs to `/v/{id}?t=T` and `/a/{id}?t=T`.
6. Main thread starts AU, signals VideoNet/AudioNet to resume.

Target seek latency: < 500 ms from drag-release to first frame shown.

**A/V alignment risk**: the two ffmpeg processes on the server get
`-ss T` independently. For PCM audio, `-ss` is sample-accurate. For
MPEG-1 video, we pass `-ss T -i src -force_key_frames 0 -g <small>` so
that output frame 0 is a keyframe at exactly T. Net alignment error
< 1 frame. If observed drift is larger, escape hatch: switch video to
MPEG-1 *system stream* (`-f mpeg`) with real PTSes, add a ~150-line PS
demuxer on the client, use real PTSes.

**Stream ends**: stop when the audio stream EOFs and its ring drains.
Any unpresented video frames are dropped; the last-displayed frame
stays on screen.


### 5. Player UI

No nib. Minimal viable:

```
┌────────────────────────────────────────────┐
│                                            │
│           video view (fills)               │
│                                            │
│                                            │
├────────────────────────────────────────────┤
│ [▶/❚❚]  [━━━━━━━●─────────]   0:23 / 3:42  │   ← transport bar (28 px)
└────────────────────────────────────────────┘
```

- **Window**: programmatic `NSWindow`, 640×480 content (2× native
  decode), titled `<video title> — TigerTube`. Closable. Standard
  close-on-Escape handled by the content view's keyDown.
- **Video view**: either a custom `NSView` subclass (path (a)) or an
  `NSOpenGLView` subclass (path (b)), wired to receive frames from
  VideoDec.
- **Transport bar**: fixed-height `NSView` at the bottom containing:
  - `NSButton` for play/pause (titled, upgrade to drawn icon later)
  - `NSSlider` for scrub (continuous off — `target/action` fires on
    mouseUp only so we don't seek per pixel)
  - `NSTextField` for `M:SS / M:SS`, non-editable, updated from the
    sync-loop tick
- **Keyboard**: Space = play/pause, Left/Right = ±5 s, Escape = close.
- **Row activation**: in the existing search table, wire
  `-[NSTableView doubleAction:]` and Return-key to construct a
  `TTPlayerWindowController` with the selected row's video ID + duration,
  and `makeKeyAndOrderFront:`.

**Out of scope for v1**: volume control, fullscreen, progress spinner,
error banners beyond `NSLog`, menubar integration.


## Transcoding proxy

**New file in the TigerTube repo**, not in `ppctube/` — lives at
`TigerTube/proxy/tigertube-proxy.py`. Reference implementations:

- `/Users/cell/junk/ppctube/ytproxy.py` — yt-dlp caching, cleanest
  existing file
- `/Users/cell/junk/ppctube/test-server.py` — most recent effort,
  fragmented-MOV HLS chunks

**Endpoints**:

```
GET /v/{youtube_id}?t=<float>&w=320&h=240&br=800k
    → raw MPEG-1 elementary video stream, no container
    → ffmpeg -ss T -i <yt-dlp -g url> -an \
        -c:v mpeg1video -s WxH -r 24 -b:v BR \
        -force_key_frames 0 -g 12 \
        -f mpeg1video pipe:1
    → Content-Type: video/mpeg (or application/octet-stream)

GET /a/{youtube_id}?t=<float>&rate=44100&ch=2
    → raw PCM s16be, interleaved, no header
    → ffmpeg -ss T -i <yt-dlp -g url> -vn \
        -c:a pcm_s16be -ar RATE -ac CH \
        -f s16be pipe:1
    → Content-Type: audio/L16; rate=44100; channels=2
```

**Server-side seek**: `-ss T` is placed *before* `-i` for fast input
seek. For video we add `-force_key_frames 0 -g 12` so the first emitted
frame is an I-frame (no partial-GOP B-frames at the start). For audio,
PCM is sample-accurate regardless of flag placement.

**yt-dlp URL caching**: reuse the cache pattern from `ytproxy.py` —
googlevideo URLs are valid for ~5.5 hours, cache them per video ID so
seeks don't re-run yt-dlp.

**No HLS, no playlist, no RTP, no SDP, no container.** One GET = one
ffmpeg subprocess, piped straight out.

**Testing** (on main Mac, before any Tiger code):

```
curl 'http://127.0.0.1:5001/v/dQw4w9WgXcQ?t=0&w=320&h=240&br=800k' > /tmp/test.m1v
ffplay /tmp/test.m1v            # should play in ffplay
file /tmp/test.m1v              # should say "MPEG sequence, v1"

curl 'http://127.0.0.1:5001/a/dQw4w9WgXcQ?t=0&rate=44100&ch=2' > /tmp/test.pcm
ffplay -f s16be -ar 44100 -ac 2 /tmp/test.pcm
```

**Test sources** (all usable for transcoding as proxy inputs, no
yt-dlp needed during bring-up):

Main Mac (`/Users/cell/tmp/`):
- `liakim.1920x1080.mkv`
- `louie1.1280x720.mkv`, `louie2.1280x720.mkv`
- `mag7.1920x804.mp4`
- `topgun.3840x2160.mkv`
- `rickroll-f18.mp4`

Imacg3 (`/Users/macuser/Desktop/`):
- `minions-480x270/`, `minions-512-288-good/` — empirical calibration
  data, 512×288 is the known "playable" bar for the previous player
  setup, giving us ~2.5× margin for our 320×240 target
- `katamari-star8-10s.mpg`
- `mpeg1-*.mpeg`, `mpeg2-*.mpeg` matrices in `/Users/macuser/Desktop/junk/`


## Proposed execution order

Checkpoints between phases; stop and report back at each ✋.

1. **Proxy v1**: new `TigerTube/proxy/tigertube-proxy.py` with `/v/` and
   `/a/` endpoints. Test with `curl | ffplay` on main Mac against local
   test sources first, then with a live yt-dlp URL. ✋
2. **libmpeg2 build**: write throwaway `install-libmpeg2-0.5.1.sh` (in
   TigerTube, not committed to leopard.sh), build on imacg3
   backgrounded, rsync `.a` + headers to `TigerTube/libs/libmpeg2/`.
3. **Decode benchmark**: `mpeg2dec -o null` on a 320×240 @ 24 fps @
   800k clip transcoded from one of the test sources. Report frames/sec.
   **Go/no-go gate.** ✋
4. **Rendering microbenchmarks** in parallel on imacg3:
   - GL extension probe (capabilities of Rage 128 Pro)
   - NSBitmapImageRep blit bench (path a)
   - `glTexSubImage2D` bench (path b2)
   Pick winner. ✋
5. **CoreAudio standalone test**: ~50-line C program on imacg3 that
   curls a raw-PCM stream from the proxy and plays it through Default
   Output Unit. No video involved. ✋
6. **Wire libmpeg2 into TigerTube**: pbxproj entries for
   `libmpeg2.a` + `libmpeg2convert.a`, new `TTDecoder` wrapper around
   libmpeg2's state machine. Test offline with a local MPEG-1 file
   before wiring to curl.
7. **Build the player window**: `TTPlayerWindowController` with video
   view + transport bar, wired to `TTDecoder` + `TTAudio` + sync loop.
8. **Wire seeking**: scrub-bar action → cancel streams → reopen with
   new `t=`.
9. **Wire activation**: double-click / Return in the search table →
   construct and show the player window.


## Open risks summary

| # | Risk | Mitigation |
|---|---|---|
| 1 | libmpeg2 decode too slow at 320×240 on G3 (no AltiVec) | Gated by step 3 benchmark. If fail → renegotiate resolution / fps. |
| 2 | Rage 128 Pro lacks `APPLE_ycbcr_422` | Fall back to (b2) BGRA upload path or (a) software blit. Both work. |
| 3 | A/V drift from independent ffmpeg `-ss` calls | Force-keyframe at frame 0 bounds error to < 1 frame. Escape hatch: MPEG-1 system stream with real PTSes + ~150-line client-side PS demuxer. |
| 4 | QuartzEngine software blit too slow for large windows | Path (b) GL upload avoids the blit cost for scale-up. |
| 5 | Proxy cold-start latency (yt-dlp + ffmpeg init) | Cache yt-dlp URLs for 5.5 h. Pre-warm on search result selection. |


## Conventions (reminder for implementation)

- Programmatic UI only; no nibs for views. `MainMenu.nib` kept only
  for the default menu bar.
- Category files named `Foo+.h/.m`.
- C/Obj-C formatting: asterisk hugs type (`NSString* foo`), no
  multi-decls, K&R braces, except multi-line method signatures keep
  `{` on its own line. Vendored sources (libmpeg2, libmpeg2convert)
  exempt — leave upstream formatting alone.
- Build pattern: edit on main Mac → `~/bin/tiger-rsync.sh --delete
  --exclude build/ --exclude '.git/' --exclude '*.pbxuser' --exclude
  '*.mode1v3' TigerTube/ imacg3:/Users/macuser/tmp/TigerTube/` →
  `ssh imacg3 'cd /Users/macuser/tmp/TigerTube && PATH=/opt/tigersh-deps-0.1/bin:$PATH
  xcodebuild -configuration Debug'` →
  `ssh imacg3 'osascript -e "tell application \"TigerTube\" to quit"
  2>/dev/null; sleep 0.3; open /Users/macuser/tmp/TigerTube/build/Debug/TigerTube.app'`.
  Never use `/tmp` on imacg3; wiped on reboot.
- Long builds (libmpeg2 etc.) backgrounded with nohup, polled with
  tail + ps. Never foreground an ssh for 10+ minutes.
- "commit" means commit **and** push in one step.
