# Plan: skip-decode when video falls behind the audio clock

## Goal

Keep video in sync with audio on CPU-bound playback by telling
libmpeg2 to **skip P and B frames** (decoding only I-frames) when the
decoder falls far enough behind the audio clock, and resuming full
decode once we've caught up.  Engage/disengage is governed by
hysteretic lag thresholds and happens entirely on the client; the
proxy is unchanged.

## Why

On the 600 MHz G3 without AltiVec, libmpeg2 maxes out around ~13 fps
of MPEG-1 decode at 320x240 and lower at 480p / 640p.  Source fps at
the client is 24 fps.  Today the decoder just runs as fast as it can,
produces frames at ~13 fps of source-timeline content per wall
second, and audio (which plays at real-time) drifts progressively
ahead.  The drops counter recently added correctly surfaces this: on
a 640x480 video roughly half of source frames never reach the screen.

`libmpeg2` exposes `mpeg2_skip(mpeg2dec_t*, int)` for exactly this
case:

- `MPEG2_SKIP_NONE` -- decode everything (default).
- `MPEG2_SKIP_B` -- skip B frames.  Saves ~30-40% decode work
  (typical IBBP GOP).
- `MPEG2_SKIP_PB` -- skip P and B, decode I only.  At GOP 12 / 24 fps
  that leaves ~2 decoded frames per wall second -- the visible
  stream becomes a 2 Hz "slideshow" while it's engaged, but audio
  stays smooth and the decoder catches up fast.

The plan is to switch skip modes dynamically from the client, based
on measured lag = `audioSec - decodedTime`.  When we're sufficiently
behind, flip to `SKIP_PB`; once we've caught back up, flip to
`SKIP_NONE`.  Net effect: instead of a monotonically growing
audio-to-video drift, the viewer sees smooth playback most of the
time punctuated by brief stutter intervals where the decoder is
catching up -- and A/V stays tight.

## Files touched

- `TTVideoDecoder.h` / `TTVideoDecoder.m`
  - Add `- (void)setSkipMode:(int)mode;` that wraps
    `mpeg2_skip(decoder, mode)`.  Mode constants exposed as
    `TT_SKIP_NONE`, `TT_SKIP_B`, `TT_SKIP_PB` defined in the header
    so callers don't need to include `mpeg2.h`.
  - (Optional, for diagnostics) track and expose
    `- (int)currentSkipMode`.
- `TTPlayerWindowController.h` / `TTPlayerWindowController.m`
  - New ivar `int decoderSkipMode` (current setting).
  - Hysteresis logic in `didDecodeFrame:` after the enqueue, driven
    by lag = `audioSec - decodedTime`.
  - `fprintf(stderr, ...)` log line on each mode transition so
    postmortem analysis from `~/tmp/tigertube.log` can show where
    and why skip was engaged.
  - `reset` (for seek) resets `decoderSkipMode = TT_SKIP_NONE` so
    every new segment starts from full-decode.

No proxy changes.  No UI changes.  The drops-counter surface stays
as-is -- skipped frames *are* real drops by the counter's
definition ("source-timeline frames that didn't reach the screen"),
which is the honest read.

## Design decisions

### Why hysteresis, not a single threshold

If there's one threshold at (say) 0.5 s, the decoder toggles
SKIP_PB on at lag > 0.5 s, immediately catches up, toggles off at
lag < 0.5 s, slips back, toggles on, ... rapid flicker between
slideshow and smooth.  Two thresholds with a comfortable gap
eliminates the flicker and produces intervals of each mode that
last at least a few seconds.

Proposed thresholds (tune during validation):

- `TT_SKIP_ENGAGE_LAG  = 0.5`  -- seconds behind audio.
- `TT_SKIP_DISENGAGE_LAG = 0.1` -- considered caught up.

Only transitions (NONE -> PB, PB -> NONE) actually call
`mpeg2_skip`.  `mpeg2_skip` is cheap but we shouldn't call it on
every frame -- calling only on transitions also makes the
fprintf-logged trail meaningful.

### Binary (PB only) vs three-tier (NONE / B / PB)

Start with binary NONE <-> PB.  Rationale:

- On this G3 the bottleneck is severe enough that SKIP_B alone
  probably doesn't catch us up fast enough at 480p+; we'd spend all
  our time in the B tier without ever reaching NONE.
- Simpler state machine, simpler log.
- A future three-tier upgrade (NONE <-> B <-> PB, two sets of
  thresholds) is an easy extension if real-world tuning shows
  SKIP_B gives a usable middle ground for lighter workloads.

### When to measure lag

After `feedData:` -> libmpeg2 -> `didDecodeFrame:` has enqueued a
frame.  At that point `framesDecoded` has been bumped and we can
compute:

```
decodedTime = framesDecoded / fps;
audioTime   = samplesPlayed / 44100.0;
lag         = audioTime - decodedTime;
```

That's the same lag the existing decoder-pacing sleep in
`didDecodeFrame:` computes, just the other direction -- that block
sleeps when lag is negative (decoded is AHEAD of audio) to avoid
racing ahead during smooth playback.  Skip-decode handles the
opposite: when lag is positive (decoded is BEHIND audio).

Do the mode check once per enqueue, before the pacing-sleep block.
Pacing sleep won't fire when we're behind, so there's no
interaction.

### State ownership

`decoderSkipMode` lives on the player controller, not the decoder.
The decoder just exposes a setter.  Rationale:

- The decision is a property of the A/V sync subsystem, which is
  the player controller's job.  The decoder is a straight
  byte-stream -> UYVY translator; it shouldn't know about audio.
- Seek resets `decoderSkipMode` to NONE alongside the other
  per-segment counters.  Keeping skip state next to them makes the
  reset site a single conceptual change.

### Seek interaction

Current seek flow already calls `[videoDecoder reset]` which
internally tears down and re-creates the mpeg2 decoder.  The
re-created decoder starts at `MPEG2_SKIP_NONE` by default, so we
don't need to `mpeg2_skip` explicitly there -- but the player's
`decoderSkipMode` ivar must still be reset to `TT_SKIP_NONE` so the
next frame after reset doesn't think it's already in PB mode and
skip the NONE -> NONE transition log.

### Drops counter interaction

`framesDropped` is defined as "source-timeline frames that should
have been on screen by the audio position but weren't."  A
deliberately-skipped P/B frame *is* such a frame -- the viewer
didn't see it.  So skipped frames get counted by the existing
counter, and this is honest: if the content looked stutter-y, the
count reflects the stutter.  That's what the user asked for.

If we ever wanted to split "CPU-thrashed drops" vs "deliberate skip
drops," that's a future refactor.  Not doing it now.

### Why not just shrink the GOP proxy-side

A smaller GOP means more I-frames, meaning SKIP_PB produces more
output frames per second -- the slideshow would be 4 Hz or 6 Hz
instead of 2 Hz.  That's appealing but costs significant bandwidth
(I-frames are much larger than P/B) and requires a proxy change.
Out of scope here; skip-decode is strictly a client-side tweak.

## Ordered steps

1. `TTVideoDecoder.h`: add the three mode constants
   (`TT_SKIP_NONE=0`, `TT_SKIP_B=1`, `TT_SKIP_PB=3` -- values match
   libmpeg2's `MPEG2_SKIP_*` so the wrapper is a straight
   passthrough, and the comment in the header notes this).  Add
   `- (void)setSkipMode:(int)mode;` declaration.
2. `TTVideoDecoder.m`: implement `setSkipMode:` as a one-liner
   `mpeg2_skip((mpeg2dec_t*)decoder, mode);` (guarded on
   `decoder != NULL`).
3. `TTPlayerWindowController.h`: add `int decoderSkipMode` ivar.
4. `TTPlayerWindowController.m`:
   a. Define `TT_SKIP_ENGAGE_LAG 0.5` and `TT_SKIP_DISENGAGE_LAG 0.1`
      as file-scope `static const double` near the top.
   b. Initialize `decoderSkipMode = TT_SKIP_NONE` in `init`.
   c. In `didDecodeFrame:` after the existing enqueue + unlock,
      before the pacing-sleep block:
      - Compute `lag = audioSec - decodedTime` (guarded on
        `fps > 0` and `audioPlayer != nil`).
      - If `decoderSkipMode == TT_SKIP_NONE` and
        `lag > TT_SKIP_ENGAGE_LAG`: set to `TT_SKIP_PB`,
        `[videoDecoder setSkipMode:TT_SKIP_PB]`, log.
      - Else if `decoderSkipMode == TT_SKIP_PB` and
        `lag < TT_SKIP_DISENGAGE_LAG`: set to `TT_SKIP_NONE`,
        `[videoDecoder setSkipMode:TT_SKIP_NONE]`, log.
   d. In the seek reset block, after `[videoDecoder reset]`:
      `decoderSkipMode = TT_SKIP_NONE;`  (the re-created decoder
      already defaults to NONE -- this just keeps our ivar honest).
5. Build, rsync to imacg3, live-test (see Validation).

## Validation

- **320x240 smooth case (no skip expected):**
  - Play any standard video.
  - Expect: `decoderSkipMode` stays at `TT_SKIP_NONE` for the whole
    play.  No `skip engaged` log line.  Drops counter stays hidden.
  - If skip engages here, thresholds are too aggressive.

- **640x480 heavy case (skip expected):**
  - Play a known CPU-heavy video at 640x480.
  - Expect: decoder runs at full rate for the first ~1 s, lag
    builds to > 0.5 s, `skip engaged (PB)` logs, decoder catches up
    quickly (visible 1-2 s slideshow), lag drops below 0.1 s, `skip
    disengaged` logs, smooth playback resumes.  Some oscillation
    between modes is expected under sustained overload.
  - Drops counter climbs faster while engaged than while disengaged
    (that's honest -- more frames skipped).

- **Seek across a heavy segment:**
  - Play heavy video, let skip engage.
  - Seek.
  - Expect: `decoderSkipMode` reset to NONE for the new segment;
    first decoded frame after seek is fully decoded.  If the new
    segment is also CPU-bound, skip will engage again on its own.

- **Audio-clock stays tight:**
  - During heavy playback, `audT` in the periodic stats log should
    track `decT` within ~0.5 s (within hysteresis band), never
    drifting to 10+ s behind like it can today.

- **Pre-existing behaviors unchanged:**
  - Pause/resume still works.
  - Fullscreen still works.
  - Drops label still hides at zero and shows on actual drops.

## Out of scope

- Three-tier state machine (NONE / B / PB).  Defer until binary
  tuning exposes a clear need for the middle tier.
- Proxy-side GOP reduction.  Changes bandwidth math for all
  clients, not just overloaded ones.
- Distinguishing "deliberate skip" drops from "ran out of CPU"
  drops in the counter or UI.  Future refactor if desired.
- Adaptive resolution ("downgrade from 640x480 to 320x240 when
  overloaded").  Much bigger feature; would need window-resize and
  proxy renegotiation.
- po_token / YouTube auth changes (handled elsewhere).
