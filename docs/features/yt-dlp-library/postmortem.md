# Postmortem: yt-dlp as a library + split audio/video streams

Plan: [plan.md](plan.md).  Shipped in one pass; the refactor is live and
serving the TigerTube client on imacg3.

## What shipped

All six plan steps landed roughly as written:

1. `import yt_dlp` with a zeroconf-style fail-fast + install hint.
2. `_yt_cache` now keys on `youtube_id` alone and stores the full info
   dict; old `(id, src_h)` URL cache deleted.
3. `yt_extract_info(id)` wraps `yt_dlp.YoutubeDL(...).extract_info(url,
   download=False, process=True)` and caches the result for
   `YT_URL_TTL` (5.5 h).
4. `pick_video_format(info, src_h)` and `pick_audio_format(info)`
   filter `info['formats']` manually -- video-only
   (`vcodec != 'none' and acodec == 'none'`) sorted by `(mp4, height,
   tbr)`; audio-only (`vcodec == 'none' and acodec != 'none'`) sorted
   by `(m4a, abr)`.  Combined-format fallback if no split streams
   exist, with a warning log.
5. `resolve_source` split into `resolve_video_source` (yt branch picks
   video format) and `resolve_audio_source` (yt branch picks audio
   format); the file branch is identical for both, factored into
   `_resolve_file_source`.
6. `/v/yt/`, `/a/yt/`, `/v/file`, `/a/file`, `/probe/yt/`,
   `/probe/file` updated; subprocess-based `yt_resolve()` and the
   `yt-dlp -g` invocation deleted.

## Deviation: `android_vr` added to `YT_PLAYER_CLIENTS`

The plan assumed that moving from subprocess to library would expose
split video-only / audio-only formats automatically ("the `yt_dlp`
library exposes a structured `info` dict ... we can pick a video-only
format (`acodec == 'none'`)").  That assumption was wrong.

The format list is a function of which **YouTube player clients**
yt-dlp impersonates, not how you invoke yt-dlp.  With the plan's
stated client list (`tv_simply,web_safari,mweb`), `extract_info`
returned **11 formats, all combined HLS**.  Both pickers hit the
combined fallback path every single time, defeating the bandwidth-win
that was the primary motivation for the refactor.

Probe (Rick Astley test, `dQw4w9WgXcQ`):

| clients                                  | total | v-only | a-only | combined |
|------------------------------------------|-------|--------|--------|----------|
| `tv_simply,web_safari,mweb`              |    11 |      0 |      0 |        7 |
| `tv_simply,web_safari,mweb,android_vr`   |    37 |     22 |      4 |        7 |
| `android_vr` alone                       |    31 |     22 |      4 |        1 |

`android_vr` is the load-bearing client for split DASH formats.
Shipped with it added to the end of the existing list, so bot-detection
behavior is unchanged for the first three clients (they're still tried
first) and android_vr is the fallback that produces the split streams.

A comment in the config explains why it's there so a future edit
doesn't drop it "for simplicity."

## Surprises

### The plan's premise was one `extract_info` call away from being
validated

Three minutes of actual probing would have caught the client/format
relationship before the plan was written.  The specific question --
"does `tv_simply,web_safari,mweb` expose split streams?" -- is a
~10-line Python script.  Worth building a reflex around: when a plan
depends on an external tool's output shape, probe the tool first.

### Split URLs come from different CDN edges

Video and audio googlevideo URLs for the same video use different
`rrN---…` CDN hostnames (`rr5---sn-q4fzened` vs `rr4---sn-q4fzene6`
in one test).  Net effect: the two ffmpegs on the proxy get natural
TCP-level parallelism on the fetch side, rather than contending for
one connection to one edge.  Bonus we didn't plan for.

### Concurrent cache-miss race

When the client opens a video, `/v/yt/<id>` and `/a/yt/<id>` fire
essentially simultaneously.  On a cold cache, both handlers miss,
both call `yt_extract_info`, and the second one wins the cache write.
Cost: one redundant ~3 s extract on first play of each video.
Observable in the proxy log as two `--- yt-dlp: extract <id>` lines
for the same id milliseconds apart.

Not fixed.  A single-flight lock around `yt_extract_info` (one mutex
per id, extract under lock, readers wait) would eliminate it in ~15
lines.  Deferred -- cold-cache only, no correctness impact, and
rebuilding the lock-per-id dictionary cleanly isn't worth the
distraction right now.  If we start seeing cold-cache play latency
complaints, revisit.

## Bandwidth win (rough)

For `dQw4w9WgXcQ` at the 480p tier we now pull:
- video itag 135: `clen=14103519` (~13.5 MB)
- audio itag 140: `clen=3449447` (~3.3 MB)

That's ~17 MB for one full play vs. 2× the combined stream before
(the same content served twice to feed /v/ and /a/ separately).
Napkin: ~50% reduction on a typical play.  Bigger on long videos
where the combined URL was cached and both endpoints drained it
fully.

No formal nettop measurement done -- the itag-level evidence is
airtight and matches the expected split-stream behavior.

## HLS `-ss 0` workaround: still warranted

The new hot path produces DASH mp4 URLs, not HLS playlists, so the
"could not seek to position 0.000" quirk doesn't fire.  But the
combined-format fallback path (for videos without split streams --
Shorts, old uploads) can still return HLS.  The workaround in
`build_video_cmd` stays.

## What to do differently

- **Smoke-probe format lists before planning around them.**  Adding
  this as a reflex: any plan that depends on "tool X returns shape
  Y" should have a 3-line probe in the plan doc proving Y, or be
  downgraded to "expected but untested."
- **Player-client list is now a tested dependency**, not a free
  variable.  Document in CLAUDE.md that any change to
  `YT_PLAYER_CLIENTS` needs a split-vs-combined probe before merge.
  (Not done in this change -- mentioned in the config comment but
  not CLAUDE.md.  Left for a follow-up if it bites again.)
