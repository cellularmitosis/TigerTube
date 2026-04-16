# The "first 5 seconds" bug: postmortem

During early bring-up of the player, the client exhibited a pair of
symptoms that both looked like a "first 5 seconds" problem:

1. The video was **frozen on its first frame for ~5 seconds** while
   audio played normally. Motion only started at wall-time ~5s.
2. After fixing (1), motion started immediately — but the video began
   at source-time **00:00:05** instead of 00:00:00. The first 5 seconds
   of the actual video content were missing.

Both were caused by ffmpeg's handling of the proxy input source, not by
the player. Both happened to produce a ~5s artifact because of the same
underlying property of YouTube's HLS delivery. They are, however, two
independent bugs with two independent fixes.

This doc records what they were, how we diagnosed them, and the fixes
that are now in `proxy/tigertube-proxy.py`.


## Context: what the proxy is feeding into

The proxy resolves YouTube URLs via `yt-dlp -f "best[height<=1080][ext=mp4]"`.
For most recent YouTube videos that format spec resolves to **format 301**
— a 1080p HLS stream (H.264 + AAC, ~5.12s segments). ffmpeg sees it via
its HLS demuxer.

HLS segments have one important property that bit us twice: the **first
video packet's PTS is not zero**. It's the absolute timeline PTS at the
start of that segment, which for a mid-playlist segment is whatever
wall-timeline offset the segment corresponds to. For segment 0 of a VOD
HLS playlist it's usually *close to* zero, but ffmpeg's demuxer often
still presents the first decoded frame at PTS ~5s (the segment's
nominal start of the **next** segment, after discontinuity handling).

Two places in our ffmpeg pipeline reacted badly to that.


## Bug #1: frozen-frame-for-5-seconds

### Symptom

Player starts. Audio begins normally. Video shows the very first decoded
frame and holds it, unchanging, for ~5s. Then motion starts and
continues normally.

Player logs (added during diagnosis) showed:

- `first decode at wall=0.3s` — decoder was getting bytes immediately.
- `first display at wall=0.4s` — GL presented a frame immediately.
- `framesDecoded` climbed at ~24/s from wall=0 onward.
- `framesDisplayed` climbed at ~24/s from wall=0 onward.

So the player was decoding *and* displaying 24 fps worth of frames.
They just all looked identical for the first 5 seconds.

Pulling the raw MPEG-1 ES from the proxy and extracting every 12th
frame with ffmpeg confirmed it: the proxy's output stream itself
contained ~120 copies of the first frame followed by normal motion.
The bug was in the proxy, not the client.

### Root cause

The proxy's video ffmpeg command had a `-vf fps=24` CFR filter at the
end of the filtergraph. `fps=N` with the default `round=near` policy
works by choosing, for each output-PTS slot, the input frame whose PTS
is closest.

If the first input frame arrives with PTS = 5.0 (which is what the HLS
demuxer was delivering), then for output-PTS slots 0, 1/24, 2/24, ...
all the way up to 5s, the "nearest input frame" is *always* that first
frame at PTS 5 — there's literally nothing earlier to round to. So the
filter emits 120 copies of the same frame, and only starts emitting
real motion once output-PTS catches up to input-PTS.

### Fix

Prepend `setpts=PTS-STARTPTS` to the filtergraph, **before** `fps=`,
to rebase the input PTS to start at zero:

```
-vf scale=W:H:...,
    pad=W:H:...,
    setpts=PTS-STARTPTS,
    fps=24
```

`setpts=PTS-STARTPTS` records the first seen PTS and subtracts it from
every subsequent PTS, so the first frame ends up at PTS 0. Now `fps=24`
sees a normal timeline and there are no ghost output slots to fill.

Order matters: `setpts` must run **before** `fps`, otherwise the CFR
filter has already duplicated frames and you're rebasing the damaged
timeline.

### How we reproduced it locally

Generated a deterministic test source with a burn-in timecode:

```bash
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=50:duration=30 \
  -vf "drawtext=text='%{pts\\:hms}':x=10:y=10:fontsize=48:fontcolor=white" \
  -c:v libx264 -pix_fmt yuv420p src.mp4
```

Ran the proxy's exact ffmpeg command against `src.mp4` — no freeze
(input PTS already 0). Then added `-itsoffset 5` before `-i` to
simulate the HLS demuxer's "first PTS is 5" behavior — **freeze
reproduced**. Added `setpts=PTS-STARTPTS` — **freeze gone**. That
isolated the fix before we touched the YouTube-facing side.

### Why audio didn't have the same issue

The audio ffmpeg command has no `fps=` equivalent. `-c:a pcm_s16be`
with a target `-ar 44100 -ac 2` produces a sample stream paced by
decoded audio samples, not by PTS slot rounding. Whatever PTS the
first audio frame has, the demuxer just streams the underlying samples
out; there are no empty slots to fill.

So audio played normally from wall-time 0 while video was stuck on its
first frame — and that asymmetry is actually what made this bug look
like a *player* problem at first, until logs proved the player was
innocent.


## Bug #2: video actually starts 5 seconds late

### Symptom

After the fix above, the frozen-frame behavior was gone: motion started
immediately at wall=0. But visually, the content the user saw begin at
wall=0 corresponded to **source-time 00:00:05**, not 00:00:00. The
first 5 seconds of actual video content was missing.

Confirmed the source itself was not at fault: the user downloaded
format 18 (the legacy combined MP4) with yt-dlp and played it in both
vlc and ffplay — both started at 00:00:00. A browser played the
canonical YouTube URL starting at 00:00:00. The 5-second offset only
appeared through our proxy.

### Root cause

The proxy was passing `-ss 0` for the default no-seek case (`t=0`).
Running the proxy's command against the HLS URL with and without
`-ss 0`, then extracting the first output frame:

- **With `-ss 0`**: ffmpeg stderr logged
  `[in#0/hls @ ...] could not seek to position 0.000`
  and the first frame's burn-in timecode read `00:00:05:07`.
- **Without `-ss`**: no stderr warning, first frame's burn-in read
  `00:00:00:00` (actually `00:00:00:01` — frame 1).

ffmpeg's HLS demuxer refuses to honor `-ss 0` and compensates by
advancing past what it treats as the first partial segment. Net effect:
the first ~5 seconds of content is dropped before it's even offered to
the encoder.

The MP4 demuxer doesn't have this behavior — `-ss 0` against an MP4
source is a no-op. The bug is specific to the HLS demuxer, which we
only see because `best[height<=1080][ext=mp4]` happens to resolve to
format 301 (HLS) for most modern YouTube videos despite the `ext=mp4`
hint.

### Fix

Omit `-ss` entirely when `t == 0`. Only pass it for actual seeks
(`t > 0`). See `build_video_cmd` and `build_audio_cmd` in
`proxy/tigertube-proxy.py`.

```python
cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning"]
if t > 0:
    cmd += ["-ss", f"{t}"]
cmd += ["-i", source, ...]
```

This also aligns better with ffmpeg's input-side `-ss` semantics in
general: passing `-ss 0` is not meaningfully different from "no seek"
for well-behaved demuxers, but it's a trigger for a real bug in the
HLS demuxer. Don't ask for seeks you don't actually need.


## Debugging tactics that worked

A few things that turned out to be very effective on this kind of bug
and are worth remembering for the next one.

**Don't trust assumptions about where a 5-second artifact is coming
from.** "5 seconds frozen" sounds like a buffering / startup problem
and naturally pulls focus onto the player. In this case the player was
fine; the proxy's output literally contained duplicated frames. Verify
the output stream byte-for-byte, not just the end-to-end behavior.

**Pull the proxy's output to disk early.** `curl -s -o v.m1v
'http://.../v/yt/<id>?t=0'` gives you a file you can feed into any
inspection tool (ffprobe, ffplay, `ffmpeg -vframes ...`) without the
player in the loop at all. This is how we went from "is it the player
or the proxy" to "it's the proxy" in one command.

**Reproduce against a deterministic local source with burn-in.**
A short `testsrc2` with `drawtext=text='%{pts\:hms}'` burn-in gives you
a video where every frame is self-labeled. Extracting frame 0 of the
output and reading the label tells you immediately where the content
starts. Combined with `-itsoffset N` this lets you simulate whatever
PTS offset you suspect upstream is causing, without needing the real
upstream at all. This is how we isolated both bugs independently.

**Compare first frames with and without the suspect flag.** For the
`-ss 0` bug: same command twice, one with `-ss 0`, one without, diff
the first-frame burn-ins. The result was unambiguous.

**Add player-side diagnostic counters before blaming the player.**
First-decode wall time, first-display wall time, running decoded /
displayed counts logged at 0.5s intervals told us the player was
keeping up from wall=0 onward. Once those numbers looked healthy the
only place left to look was upstream of the player.


## Player-side diagnostics added during investigation

The diagnostics in `TTPlayerWindowController.m` (`firstDecodeLogged`,
`firstDisplayLogged`, 0.5s stats cadence) proved their worth in
ruling out the player for this bug. They're worth keeping in — cheap
to emit, invaluable the next time something timing-related misbehaves.

Relevant fields in `TTPlayerWindowController.h`:

```objc
BOOL firstDecodeLogged;
BOOL firstDisplayLogged;
```

And the log lines they produce:

```
player: first decode at wall=0.312s (fps=23.98, 320x240)
player: first display at wall=0.418s (decoded=1, gl took 0.001s)
```

If we ever see first-decode lag behind wall=0 by anything significant,
that's a real player-side problem. If we see first-display lag well
behind first-decode, that's a GL setup cost we should measure. Both of
those are future bugs we're now instrumented to catch.


## What's still open

- **Display rate lower than decode rate** under some conditions
  (~10fps displayed vs 24fps decoded observed during this debugging
  session). Likely a display-timer / A-V sync issue unrelated to the
  two bugs above. Deferred — does not block playback correctness.
- **Seeking** (scrub bar → cancel streams → reopen with `t=`) still
  to be implemented. The `-ss` code path is now correct for any
  `t > 0`, so the proxy side is ready; just needs client UI.
