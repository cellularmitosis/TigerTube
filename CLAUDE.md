# TigerTube — notes for Claude

A native Cocoa YouTube client for Mac OS X 10.4 Tiger on PowerPC G3,
paired with a Python/ffmpeg transcoding proxy that runs on a modern
host. The G3 does libmpeg2 decode + GL_APPLE_ycbcr_422 render + CoreAudio
playback; it cannot run a modern TLS stack or yt-dlp itself.

## Dev loop

The Mac this runs on is **imacg3** (600 MHz iMac G3, Rage 128 Pro). The
dev host is this laptop (hostname **uranium**) — "uranium" in user
messages means *this machine*, not a remote.

Edit locally, then:

```
~/bin/tiger-rsync.sh --exclude=build/ --exclude=.git/ --exclude=docs/ \
  --exclude=proxy/ --exclude=libs/ \
  /Users/cell/github/cellularmitosis/TigerTube/ imacg3:tmp/TigerTube/
ssh imacg3 "cd tmp/TigerTube && xcodebuild -configuration Debug"
ssh imacg3 "cd tmp/TigerTube && ./run_and_log.sh"
ssh imacg3 "tail -60 ~/tmp/tigertube.log"
```

- **Do not use plain `rsync`.** Tiger's rsync is from ~2005 and a
  modern-rsync → old-rsync transfer needs specific wire-protocol and
  directory-handling flags, or you get empty/wrong transfers with no
  error. The `~/bin/tiger-rsync.sh` wrapper on this laptop bakes them
  in (`rsync --protocol=27 --no-dirs -rlptgoDv "$@"` — that's `-av`
  expanded plus the two Tiger-specific flags). Pass any extra flags
  (`--delete`, `--exclude`, `--dry-run`) as positional args. See the
  `imacg3-dev` skill for the full environment crib sheet (bash 3.2
  under /opt, modern curl with CA bundle, perl 5.36, etc.).
- **Reach for the `leopard-adc-docs` skill for Cocoa/ObjC 1.0
  questions.** Local mirror of Apple's July 2009 ADC Reference Library
  — the last doc set to cover the pre-ObjC-2.0 world first-class.
  Useful for: "is this NSFoo method on 10.4?" (availability markers
  grep), the ObjC 1.0 Language book + Runtime Reference, 1,431
  pre-unpacked Apple sample projects, and legacy docs (QuickTime,
  Carbon) that Apple has since deleted from developer.apple.com.
- **Always build `Debug` for iteration.** `run_and_log.sh` launches
  `./build/Debug/TigerTube.app/...`, so a `Release` build looks
  successful but leaves the user running yesterday's Debug binary.
  Release is only for producing the GitHub zip.
- `run_and_log.sh` already quits any running instance, captures stderr
  to `~/tmp/tigertube.log`, and relaunches. Don't open `.app` directly
  — LaunchServices swallows stderr.
- `tiger-rsync.sh` preserves source mtimes (archive mode); if Xcode's
  dependency tracking doesn't notice a header change,
  `ssh imacg3 "touch tmp/TigerTube/Foo.h"` and rebuild.
- The proxy runs on **uranium** (this laptop), advertised over mDNS as
  `_tigertube-proxy._tcp` on port 5002. The client auto-discovers it;
  there is no hardcoded IP to update.

## Repo layout

- `*.m` / `*.h` at the root — Cocoa app sources
- `main.m`, `AppController.{h,m}` — app entry + search UI
- `YTClient.{h,m}` — YouTube Data API v3 client (libcurl + SBJson)
- `TTPlayerWindowController.{h,m}` — orchestrates playback, owns the
  two fetch pthreads and the 30 Hz display timer
- `TTPlayerView.{h,m}` — NSOpenGLView, YUV→RGB on the GPU
- `TTVideoDecoder.{h,m}` — libmpeg2 wrapper, emits UYVY via
  `mpeg2convert_uyvy`
- `TTAudioPlayer.{h,m}` — Default Output AudioUnit + s16be ring buffer
- `ThumbnailCache.{h,m}` — background-fetches search result thumbnails
- `SBJson-2.2.3/` — vendored JSON (Tiger-compatible; don't replace)
- `libs/{curl,openssl,libmpeg2}/` — vendored native deps, built for ppc
- `proxy/tigertube-proxy.py` — Flask transcoding proxy (modern host)
- `run_and_log.sh` — on imacg3, wrapper around the binary that
  captures stderr
- `docs/` — design notes and postmortems (see "Feature workflow"
  below); not shipped

## Code conventions

- Obj-C 1.0, **manual retain/release** (no ARC — Tiger's runtime
  predates it). Every `-init…` that returns nil must `[self release]`
  before returning.
- `NSString* foo` — asterisk hugs the type. No multi-decls on one
  line. K&R braces. These apply to our code; **don't reformat vendored
  libs** (SBJson, libmpeg2, libcurl).
- Category files are named `Foo+.h` / `Foo+.m` (not `Foo+Topic.h`).
- Build UI programmatically. The nib under
  `English.lproj/MainMenu.nib` is minimal on purpose — don't push UI
  back into it.
- No AltiVec: the G3 doesn't have it. `mpeg2_accel(0)` is deliberate.
- `-std=c99` + Obj-C, `-mmacosx-version-min=10.4`, `-arch ppc`. Don't
  use 10.5+ APIs (no blocks, no `@property`, no ARC, no
  `NSApplicationPresentationHideMenuBar` — we use Carbon's
  `SetSystemUIMode` for fullscreen).
- `fprintf(stderr, ...)` for diagnostics, viewed via
  `~/tmp/tigertube.log`. No NSLog for hot paths.

## Architecture — the playback pipeline

The player is three concurrent actors plus a main-thread display timer:

1. **Video curl thread** → `TTVideoDecoder.feedData:` → libmpeg2 →
   `didDecodeFrame:` callback enqueues UYVY into a **3-slot frame
   queue** under a mutex. Decoder blocks on `queueNotFull` if the
   display is behind; this propagates backpressure through TCP to the
   proxy's ffmpeg.
2. **Audio curl thread** → `TTAudioPlayer.feedPCM:` → 256 KB ring
   buffer. `feedPCM` busy-waits (1 ms) when the ring is full.
3. **CoreAudio render callback** (real-time thread) drains the ring,
   converts s16be → Float32, and advances `samplesOut`.
4. **Display timer on main** at 30 Hz non-blocking-dequeues one frame,
   uploads via `glTexSubImage2D` with `GL_YCBCR_422_APPLE`, draws a
   letterboxed quad, `flushBuffer`.

The **A/V clock is the audio sample counter**: `position = startTime +
samplesOut/44100`. The decoder paces itself to stay ~40 ms ahead of
that clock. Audio playback does not start until the video decoder has
produced its first frame (otherwise the audio clock advances from 0
while the decoder is still starting up, and when video catches up it
races through N seconds of frames).

`stopRequested` is the global shutdown signal. Curl write callbacks
return 0 on `stopRequested` to abort in-flight transfers. The decoder
waits on `queueNotFull` with a `!stopRequested` guard and gets
broadcast-woken. `TTAudioPlayer.cancel` unsticks `feedPCM` when the
ring is saturated.

## Things that will bite you

- **Do not stop the audio unit before the fetch threads exit.** If you
  stop rendering while the ring is full, `feedPCM` busy-waits forever
  because nothing drains. The seek path calls `[audioPlayer cancel]`
  (sets a flag that `feedPCM` checks) and leaves the unit running
  until the threads are confirmed dead, then `reset`s it.
- **libmpeg2 `mpeg2_reset(dec, 1)` does not reliably preserve the
  `mpeg2_convert` hook** in 0.5.1 — the first frame after reset comes
  back with a `display_fbuf->buf[0]` pointing into an unmapped page.
  `-[TTVideoDecoder reset]` tears down and rebuilds the decoder
  instead.
- **Proxy's `-ss 0` is a trap.** ffmpeg's HLS demuxer (used for
  YouTube format 301) logs "could not seek to position 0.000" and
  compensates by skipping the first ~5 s of content. `build_video_cmd`
  omits `-ss` entirely when `t==0`.
- **NSSearchField chrome doesn't scale with font size on Tiger.** If
  you want a bigger search input, use `NSTextField` with
  `NSTextFieldSquareBezel`. We do.
- **YouTube Data API thumbnail dimensions are not a source aspect
  signal.** `default`/`medium`/`high` always come back as 120x90 /
  320x180 / 480x360 regardless of what the source really is. Don't
  try to detect pillarbox from them.
- **Proxy cropdetect is opt-in** via `?crop=auto` or `?crop=W:H:X:Y`.
  The client currently omits the param (fast path). Only wire it in
  if the double-bars case is a real user complaint — the probe adds
  1–2 s to first-frame latency.
- **Xcode dependency tracking can miss rsync'd headers** because
  archive-mode rsync preserves source mtimes. If a `.h` change doesn't
  trigger recompilation, `ssh imacg3 "touch tmp/TigerTube/Foo.h"` and
  rebuild.

## Feature workflow

Non-trivial features follow a plan → implement → postmortem flow, one
Claude session per phase, so no single session has to hold the whole
thing in context:

- `docs/features/<slug>/plan.md` — written first, before any code. Goals,
  files touched, ordered steps, design rationale for non-obvious calls,
  validation checklist. Self-contained enough that a fresh session can
  pick it up cold.
- `docs/features/<slug>/postmortem.md` — written after the feature lands.
  What actually shipped vs. the plan, surprises, what to do differently.
- When asked to "plan a feature," write `plan.md` in a new
  `docs/features/<slug>/` directory and stop there. Don't start
  implementing in the same session.
- When asked to "implement" a feature with an existing `plan.md`, follow
  the plan; deviate only when the plan is wrong, and note the deviation
  for the postmortem.
- Bug postmortems (not feature-paired) can live at `docs/` root or under
  `docs/postmortems/` — not under `docs/features/`.

## Git workflow

- "Commit this" and "push this up" both mean commit *and* push. Don't
  leave unpushed local commits unless the user explicitly asks you to.

## Release workflow

Tagged releases live on GitHub as `vX.Y` with a `TigerTube-X.Y.zip`
asset. The zip layout matches existing releases:

```
TigerTube-X.Y/
  TigerTube.app/...   (Release build from imacg3)
  proxy/tigertube-proxy.py
```

Steps:

1. Commit + push everything to `main`.
2. `ssh imacg3 "cd tmp/TigerTube && xcodebuild -configuration Release"`
3. `~/bin/tiger-rsync.sh imacg3:tmp/TigerTube/build/Release/TigerTube.app /tmp/tigertube-release/TigerTube-X.Y/`
4. Copy `proxy/` in alongside it.
5. `zip -r TigerTube-X.Y.zip TigerTube-X.Y`
6. `gh release create vX.Y --title "Version X.Y" --notes-file ... --target main TigerTube-X.Y.zip`

Release notes should list user-visible changes, what's in the zip,
run instructions, and the player controls.
