# Plan: use yt-dlp as a Python library, split audio/video streams

## Goal

Replace the `subprocess.check_output(["yt-dlp", ...])` call in
`proxy/tigertube-proxy.py` with in-process use of the `yt_dlp` Python
package, and use the richer information that gives us to pick
**separate video-only and audio-only formats** for the `/v/yt/` and
`/a/yt/` endpoints.

## Why

Today the proxy calls `yt-dlp -g 'best[height<=N][ext=mp4]/...'`,
which returns a single **combined** (audio + video) URL.  Both
`/v/yt/<id>` and `/a/yt/<id>` then feed that same URL to ffmpeg,
which throws away whichever track the endpoint doesn't need.  Net
effect: the proxy downloads the full video twice per play (~2x the
bandwidth).

The `yt_dlp` library exposes a structured `info` dict with a
`formats` list where each entry has `vcodec`/`acodec`/`height`/`ext`
fields.  With that we can pick a video-only format (`acodec == 'none'`)
for `/v/yt/` and a small audio-only format (`vcodec == 'none'`) for
`/a/yt/`.  Each ffmpeg instance then downloads only what it needs.

Secondary benefits (nice-to-have, not driving motivation):

- No ~1-2 s fork/exec/startup cost per cache-miss resolve.
- Structured errors (`yt_dlp.utils.DownloadError`) instead of
  parsing stderr.
- The separated audio/video formats are usually DASH `.mp4`/`.m4a`
  URLs rather than the HLS playlist that currently triggers the
  "`-ss 0` skips the first 5 s" workaround in `build_video_cmd`.
  That workaround can stay for safety, but the new path shouldn't
  hit it.

## Files touched

- `proxy/tigertube-proxy.py` — the only file that needs changes.
  - Add `import yt_dlp`, guarded like the zeroconf import (fail
    fast with `pip3 install yt-dlp` hint).
  - Replace `yt_resolve()` and `_yt_cache` with a new `yt_extract_info()`
    that caches the full info dict per `youtube_id` for
    `YT_URL_TTL` seconds (unchanged, 5.5 h).
  - Add `pick_video_format(info, src_h)` and
    `pick_audio_format(info)`, each returning a URL string.
  - `resolve_source(kind, ident, src_h)` splits into
    `resolve_video_source(kind, ident, src_h)` and
    `resolve_audio_source(kind, ident)`.  The `file` branch still
    returns the local path for both.
  - `/v/yt/`, `/a/yt/`, `/probe/yt/` handlers updated to call the
    right variant.
  - Drop `YT_PLAYER_CLIENTS` as a string, pass as a list via
    `extractor_args`.

## Design decisions

### Format selection

Use a yt-dlp format-selector string rather than filtering the
`formats` list by hand — it's what yt-dlp is good at, and it handles
codec-preference ordering internally.

- **Video-only:** `bestvideo[height<={src_h}][ext=mp4]/bestvideo[height<={src_h}]`
  (prefer mp4/h264 for ffmpeg's sake; fall back to whatever's best).
- **Audio-only:** `bestaudio[ext=m4a]/bestaudio`
  (prefer m4a/AAC for the same reason; fall back).

`src_h` is still derived from the client's requested output height
via the existing `compute_src_height()`.  `YT_ALLOWED_SRC_HEIGHTS`
and `YT_DEFAULT_SRC_HEIGHT` stay.

Pass the selector to yt-dlp as `ydl_opts['format'] = selector`.
After `extract_info(url, download=False, process=True)`, the chosen
URL is in `info['requested_formats'][i]['url']` (one per selected
format) or for single-format selectors, at the top level.

Use `ydl.sanitize_info()` if we want to serialize; not needed for
our purposes.

### Cache

Cache the full info dict keyed by `youtube_id` alone, not by
`(id, src_h)`.  The info dict is ~50-200 KB per video, which is
fine for the handful we'll see.  Video/audio URL picking is a
trivial in-memory lookup per request.

TTL stays at 5.5 h (googlevideo token expiry).  On cache miss,
re-extract.

```python
_yt_cache = {}  # youtube_id -> (info_dict, timestamp)
```

### Player clients

Still needed — bot detection is per-client and our current
`tv_simply,web_safari,mweb` list is what's working as of
2026-04.  Pass via:

```python
ydl_opts = {
    'quiet': True,
    'noplaylist': True,
    'extractor_args': {
        'youtube': {'player_client': YT_PLAYER_CLIENTS},
    },
    'format': selector,
}
```

where `YT_PLAYER_CLIENTS` is now a Python list, not a comma string.

### Fallback for videos without separated streams

Some videos (esp. YouTube Shorts and very old uploads) only have
combined formats.  yt-dlp's `bestvideo/` selector will fail with
`DownloadError: requested format is not available` in that case.

Fallback logic in `pick_video_format`: on `DownloadError`, re-run
with the old combined-format selector `best[height<={src_h}][ext=mp4]/best[height<={src_h}]`.
Same URL then gets used for both `/v/` and `/a/` — regresses to
current bandwidth behavior for those videos, but they still play.

### `/probe/yt/<id>`

Keep it simple: probe the video URL (whatever `pick_video_format`
returns).  That's what it effectively does today.

### HLS `-ss 0` workaround

`build_video_cmd` currently omits `-ss 0` to avoid an HLS demuxer
quirk.  DASH mp4 sources don't have this quirk, but the workaround
is harmless for mp4 too.  Leave it as-is.

### Cropdetect

Cropdetect probes the video URL for a few frames.  After the split,
it still uses the video URL (now video-only) — same behavior.  No
change needed.

## Ordered steps

1. Add `import yt_dlp` with try/except + install hint matching the
   zeroconf pattern.  Exit 1 if missing.
2. Add `_yt_cache = {}` and `yt_extract_info(youtube_id)` that
   calls `YoutubeDL(...).extract_info()` with the selector arg
   *omitted* — we want the full format list in cache, not a
   pre-picked URL.  Raise `HTTPError(502, ...)` on
   `yt_dlp.utils.DownloadError`.
   - Hmm, decide: do we call `extract_info` once per cache miss (no
     selector, gets full list), or twice (once for info, once per
     pick)?  Single call is simpler and what `foo.py` does.  Go with
     that.  Pick the URL afterwards by filtering the `formats` list
     manually — not worth a second extract_info just to re-use
     yt-dlp's format selector.
3. Write `pick_video_format(info, src_h)`:
   - Filter `info['formats']` to `vcodec != 'none' and acodec == 'none'`.
   - Sort by (ext == 'mp4' desc, height desc, tbr desc) within
     `height <= src_h`.
   - Return the best one's `url`.
   - On empty result (no video-only format), filter combined
     (`vcodec != 'none' and acodec != 'none'`), same sort, return
     its `url`.  Log a warning so we know we hit the fallback.
4. Write `pick_audio_format(info)`:
   - Filter `formats` to `vcodec == 'none' and acodec != 'none'`.
   - Sort by (ext == 'm4a' desc, abr desc).
   - Return best `url`.
   - Fallback to combined same way as above.
5. Split `resolve_source` into `resolve_video_source` and
   `resolve_audio_source`.  The `file` branch is identical for both.
6. Update route handlers:
   - `GET_video_yt` → `resolve_video_source("yt", id, src_h)`.
   - `GET_audio_yt` → `resolve_audio_source("yt", id)`.
   - `GET_probe_yt` → `resolve_video_source("yt", id, YT_DEFAULT_SRC_HEIGHT)`.
7. Delete the old `yt_resolve()` function and the
   `subprocess`-based yt-dlp call.
8. Keep `import subprocess` — still used for ffmpeg/ffprobe.
9. Restart the live proxy on uranium, test with the TigerTube app.

## Validation

- Proxy starts cleanly with yt-dlp installed; fails with helpful
  message + exit 1 when `pip uninstall yt-dlp` has been run.
- Play a standard YouTube video (e.g. `dQw4w9WgXcQ`) end-to-end in
  the TigerTube app on imacg3:
  - Video plays.
  - Audio plays, stays in sync.
  - Seek works (tests the preserved `-ss` logic).
- Measure bandwidth: a 1-minute play should pull roughly the sum of
  one video-only + one audio-only stream, not 2× a combined stream.
  Can eyeball this via `nettop` or `lsof -p $PROXY_PID` on uranium.
- Second play of the same video within 5.5 h doesn't log a fresh
  `--- yt-dlp: extract` line — cache is hit.
- Try a video that has only combined formats (YouTube Shorts are a
  common source).  Verify the fallback path plays and logs the
  warning.
- `curl http://127.0.0.1:5002/probe/yt/<id>` returns ffprobe JSON.
- Nothing in the TigerTube app changes — the whole refactor is
  server-side.

## Out of scope

- po_token support for bot-detection resistance.  Would be nice but
  separate effort; our current player-client list still works
  cookie-free as of 2026-04.
- Replacing the HLS `-ss 0` workaround.  The new path shouldn't
  hit HLS, but removing safety nets for paths we just changed is
  asking for a postmortem.
- Caching the picked URL separately from the info dict.  The info
  dict cache makes picking O(1) already; no second cache needed.
- Releasing a new TigerTube.app client — zero client-side changes.
