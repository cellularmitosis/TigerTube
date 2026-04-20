# Triggered display + 1 Hz transport-bar guard

> **Status: first draft, pending review.**
>
> Two related refactors to the display pipeline, bundled into a
> single plan because the second (Q1) is a strict subset of the
> machinery introduced by the first (Q2): once the display timer
> is no longer the thing that runs the transport bar, we can
> rate-limit bar updates without affecting video frame delivery.

## Problem

Two CPU-efficiency issues in the current display architecture
(surfaced while analysing the [decode-bench-harness
postmortem](../decode-bench-harness/postmortem.md)):

1. **The 30 Hz display timer is a hard cap on `fps_displayed`.**
   On 60 fps source content, the decoder faithfully produces 60
   frames/sec (paced to the audio clock), but the main-thread
   NSTimer only fires 30 times/sec; the 3-slot queue's
   drop-oldest logic silently discards half the produced frames.
   The G5 can literally decode 113 Mpx/s (measured at
   1920×1080@60, 81% CPU) but the user only sees 30 fps on
   screen. Slower machines pay the full 60 fps decode cost and
   throw half the output away.

2. **The transport bar (slider + time label) updates on every
   display tick at 30 Hz** even though the time label is `MM:SS`
   resolution and only changes once per second, and the slider
   knob moves sub-pixel distances at realistic video durations.
   29 of every 30 `setStringValue:` / `setDoubleValue:` calls
   write values identical to the previous call.

Issue #1 is a functional cap on 60 fps content. Issue #2 is a
small constant CPU tax. Fixing them together is natural because
the architectural change for #1 lets us address #2 in the same
pass.

## Solution overview

Replace the "one 30 Hz polling timer that does everything" design
with two independent mechanisms:

### Q2. Triggered display — driven by the decoder

The decoder thread pushes a frame into the queue (as today), then
posts a main-thread-side message to trigger display:

```
[self performSelectorOnMainThread:@selector(tryDisplayNextFrame)
                        withObject:nil
                     waitUntilDone:NO];
```

The main thread's `-tryDisplayNextFrame` does what the current
display tick does for video frames only:

1. Non-blocking dequeue of the head frame.
2. If a frame was available, `[playerView displayFrame:...]`.
3. If not, return. (Happens only as a race — another pending
   message already consumed the frame.)

**Coalescing** keeps the main run-loop queue from accumulating
messages when the decoder outruns the display: a
`displayRequestPending` BOOL guards the `performSelector…` call
and is cleared at the top of `tryDisplayNextFrame`. At most one
pending trigger at any time.

**Display rate is then exactly source fps.** 24 fps source → 24
draws/sec. 30 → 30. 60 → 60. No per-video timer tuning, no 30 Hz
cap. The existing drop-oldest behaviour still handles the case
where the decoder *does* outrun the display (this can happen if
`performSelectorOnMainThread` latency spikes), so backpressure
semantics are unchanged.

### Q1. Low-rate timer — transport bar only

A separate 5 Hz `NSTimer` runs the transport bar (slider + time
label). Rationale for 5 Hz specifically:

- Time label at `MM:SS` resolution only changes once per second,
  but the slider knob advances continuously. At 5 Hz the slider
  jumps in 200 ms increments — smooth enough to feel live, not
  wastefully frequent.
- The slider's visible knob-position step at 5 Hz on a 4-minute
  video is ~0.3 pixels — effectively smooth.
- Time label updates are guarded on `floor(audioSec) !=
  lastSecondShown` so the actual `setStringValue:` only runs
  once per second. The extra 4 ticks per second cost only a
  comparison and a conditional skip — trivial even on a G3.

**Why 5 Hz and not 1 Hz (the user's first instinct).** 1 Hz
makes the slider knob visibly jump in 1-second increments. On a
4-minute video with a ~400-pixel slider that's ~1.7 pixels per
second of actual movement — a visible step, not a glide. 5 Hz
is the sweet spot: smooth-enough slider, still ~6× cheaper than
the current 30 Hz.

**The slider's scrub-drag path is unchanged** — the existing
`[scrubSlider isDragging]` check means the slider doesn't get
touched by the timer when the user is actively dragging it.

## Design decisions (and rationale)

### Why `performSelectorOnMainThread:withObject:waitUntilDone:NO`

- 10.0+ Cocoa API, works uncomplicatedly on 10.4.
- The right abstraction: posts an invocation to the main run
  loop, which picks it up at the next iteration. No explicit
  CFRunLoopSource boilerplate.
- `waitUntilDone:NO` is the non-blocking variant — decoder
  thread returns immediately after posting, doesn't wait for
  the main thread to drain.
- Per-call overhead on 10.4 is ~50–100 µs (wraps an NSInvocation
  + posts to the main port); at 60 fps that's ~6 ms/sec, which
  is comparable to the existing 30 Hz timer infrastructure
  cost. Net-neutral or slightly positive.

Alternatives considered:
- **CFRunLoopSource**. More boilerplate, same runtime cost.
  Justified only if we needed multi-thread fan-in, which we
  don't.
- **Writing to a pipe + selecting on it in the main run loop.**
  POSIX-classical but awkward to integrate with NSRunLoop and
  adds a file descriptor; no reason to prefer it over the
  Cocoa API.

### Why coalesce with `displayRequestPending`

Without coalescing, a decoder producing at 60 fps while the main
thread is briefly stalled (e.g. in a long GL call or a window
server interaction) could enqueue dozens of pending
`tryDisplayNextFrame` messages. The main thread would then drain
all of them in quick succession — wasteful, and each one just
dequeues the current head frame anyway.

Coalescing is the standard "I want the main thread to know there
is work to do; exactly one trigger is sufficient" pattern:

```objc
// Decoder thread, in didDecodeFrame: after pushing to queue:
BOOL post = NO;
pthread_mutex_lock(&displayTriggerMutex);
if (!displayRequestPending) {
    displayRequestPending = YES;
    post = YES;
}
pthread_mutex_unlock(&displayTriggerMutex);
if (post) {
    [self performSelectorOnMainThread:@selector(tryDisplayNextFrame)
                            withObject:nil
                         waitUntilDone:NO];
}
```

```objc
// Main thread:
- (void)tryDisplayNextFrame {
    pthread_mutex_lock(&displayTriggerMutex);
    displayRequestPending = NO;
    pthread_mutex_unlock(&displayTriggerMutex);
    // ... dequeue + display as before ...
}
```

The flag lives on the controller alongside the existing queue
mutex. A separate mutex is cheap and keeps the queue lock's
critical section tight.

### Why the transport bar stays on its own timer (and isn't driven by display)

Two cases the display-triggered model doesn't cover:

1. **Pause.** The decoder stops pushing frames; if the bar were
   display-driven it would freeze mid-tick. The time label
   should continue reflecting the audio clock (which also
   stops at pause, so actually fine) but the user still
   expects a responsive UI.
2. **Stream end / stalled fetch.** No frames arrive but the
   audio clock is still the source of truth.

A dedicated timer (5 Hz) handles both cleanly. The decoder path
doesn't need to know about the transport bar; the timer doesn't
need to know about video frames.

### Why we keep the audio clock as the drop-accounting baseline

The existing `computeDrops:` logic uses the audio sample counter
as the "how many source frames should have displayed by now"
baseline. Unchanged. Drop counter accuracy doesn't depend on
the display-tick rate; it depends on the audio clock.

### Why this is one feature and not two

Scope is small enough (both changes touch the same
`-displayTimerFired:` method plus the decoder callback) that
splitting into separate sessions would cost more in context-
switching than shipping together. Both are motivated by the
same architectural insight: the current 30 Hz polled timer is
doing two unrelated jobs and each would be better served by a
mechanism suited to its actual rate.

## Files touched

- `src/TTPlayerWindowController.h`:
  - New ivar: `BOOL displayRequestPending`.
  - New ivar: `pthread_mutex_t displayTriggerMutex`.
  - New ivar: `NSTimer* barTimer` (replaces displayTimer's bar
    responsibilities).
  - New ivar: `unsigned long lastSecondShown`.
  - `displayTimer` stays for now but only fires a *tail-end*
    cleanup (audio-start detection, tick cadence
    instrumentation). May be removable entirely — see
    Implementation Step 3.
- `src/TTPlayerWindowController.m`:
  - `-[init...]`: initialise the new ivars.
  - `-[dealloc]`: destroy the mutex.
  - `-[play]`: create `barTimer` at 5 Hz. Keep `displayTimer`
    for now as the audio-start / instrumentation fallback.
  - `-[stop]`: invalidate both timers.
  - `-[videoDecoder:didDecodeFrame:]` (the enqueue path): after
    the push, check `displayRequestPending` + post
    `tryDisplayNextFrame` if not already pending.
  - New `-[tryDisplayNextFrame]`: carved-out main-thread
    display-frame path from the existing `-displayTimerFired:`.
  - New `-[barTimerFired:]`: transport bar only (slider +
    time label, with `lastSecondShown` guard for the label).
  - `-[displayTimerFired:]` shrinks to the residual
    responsibilities (audio-start check, cadence stats) or is
    deleted.
- No proxy changes.
- No decoder changes.

## Implementation steps

### Step 1 — Add the coalescing plumbing

Add `displayRequestPending`, `displayTriggerMutex`, and
`barTimer` ivars. Initialise in `-init`. Destroy in `-dealloc`.
No behavioural change yet.

### Step 2 — Carve `tryDisplayNextFrame` out of `displayTimerFired:`

Extract the "dequeue + display a video frame" block from
`-[TTPlayerWindowController displayTimerFired:]` into a new
`-[TTPlayerWindowController tryDisplayNextFrame]` method. Still
called from `displayTimerFired:` at 30 Hz for now.

Verify behaviour is byte-identical to today.

### Step 3 — Hook the decoder push to `tryDisplayNextFrame`

In `-[videoDecoder:didDecodeFrame:]`, after the queue push, do
the coalesced-trigger dance and call `performSelectorOnMainThread`
on `tryDisplayNextFrame`.

At this point the 30 Hz timer is firing *and* the decoder is
triggering — so `tryDisplayNextFrame` runs more often, bounded
by the queue being empty most of the time. Measure: on a G5,
bench now shows `fps_displayed` == source fps (60 on 60 fps
content)? On a G3, no regression at 24/30 fps?

### Step 4 — Carve `barTimerFired:` out

Extract the transport bar update block (slider + time label)
into a new `-[barTimerFired:]` method with the
`lastSecondShown` guard. Schedule `barTimer` at 5 Hz in
`-[play]`.

Still calling the same update logic from `displayTimerFired:`
for now — so the bar is updated from both timers. Double-update
is idempotent (guard skips it if second hasn't changed).

### Step 5 — Remove the 30 Hz display timer's bar + frame work

Once `barTimer` handles the bar and the decoder triggers frames,
`displayTimer`'s remaining responsibilities are audio-start
detection and tick-cadence instrumentation. Two options:

1. Keep `displayTimer` at 30 Hz but have it do only the
   audio-start check + the tick-cadence stats.
2. Kill `displayTimer` entirely; move the audio-start check to
   `tryDisplayNextFrame` (it'll be called early enough once
   frames start flowing) and to `barTimerFired:` (as a 5 Hz
   fallback for the "ring builds before first frame" case).

Leaning (2): fewer timers, cleaner architecture. But (1) is
conservative if we want to preserve the existing 30 Hz
instrumentation cadence for debugging.

### Step 6 — Validate across the fleet

- **imacg3** (600 MHz G3, Tiger, dev loop machine): real
  YouTube content at various fps. No regressions. Transport
  bar smooth at 5 Hz.
- **emac** (G4 single-core, Tiger): 60 fps content now
  delivers 60 fps to screen. Verify with bench harness at
  testsrc2=60.
- **imacg52** (G5, Tiger): 60 fps content at higher geometry
  — the `fps_displayed` cap at 30 should be gone; bench should
  now show fps_displayed tracking fps_decoded up to source fps.

### Step 7 — Bench-harness validation (not re-bench)

Almost all existing bench data stands post-Q2:

- **Phase A sweeps** (all at 30 fps source on imacg3): numbers
  unchanged. No re-run needed.
- **Phase B fleet calibration** (all at 30 fps source across
  nine machines): numbers unchanged. No re-run needed.
- **Phase B extended high-res sweep** at 30 fps (pbookg42,
  emac, mdd, imacg52): numbers unchanged. No re-run needed.

The two measurements that **do** change under Q2 are the 60 fps
source points in `sweep-highres-g5-extended.log`:

- `1280×720@60` previously: `fps_displayed=29, mpxs_displayed=26.8`.
  Post-Q2: `fps_displayed` should track `fps_decoded` (~58) →
  `mpxs_displayed` jumps to ~53. That's the validation signal.
- `1920×1080@60` previously: `fps_displayed=27, mpxs_displayed=56`.
  Post-Q2: `mpxs_displayed` should climb toward the decoder's
  measured `mpxs_decoded=113`.

Re-run `sweep-highres-g5-extended.sh` after Q2 lands and append
the post-Q2 numbers alongside the old ones in the log (or to a
new `-post-q2.log` file). This confirms Q2 is doing its job. No
other sweeps need regeneration.

## Validation

Functional:

1. **No-regression playback.** 24/30 fps YouTube on imacg3
   behaves identically to today. No UI jitter, no frame loss,
   no A/V desync.
2. **60 fps content on G4.** Play a known 60 fps YouTube
   source (use sweep bench `testsrc2 fps=60`) on emac. Verify
   `fps_displayed` in the player-stats log is ~60, not ~30.
   Verify visually: motion should be noticeably smoother than
   before.
3. **60 fps content on G5.** Same test on imacg52. At 1280×720
   or higher, verify `fps_displayed` ~60 and that the window's
   update pattern feels twice as fluid.
4. **Transport bar smoothness.** At 5 Hz the slider knob
   should appear to glide (not obviously stutter). Time label
   changes at exactly 1 Hz. Scrub-drag remains responsive.
5. **Pause / resume.** Bar timer keeps firing during pause
   (so time label reflects the paused audio clock). Resume
   restarts decoder-triggered display.
6. **Stop / close.** Both timers invalidate cleanly. No
   leaked pending `performSelectorOnMainThread` invocations.

Performance (re-bench):

7. **Phase A re-run on imacg3.** `sweep-geometry.sh` numbers
   should look the same at 24/30 fps source content; should
   show `mpxs_displayed == mpxs_decoded` at 60 fps small-
   geometry points instead of the old ~50% ratio.
8. **Phase B highres re-run on imacg52.** `fps_displayed`
   should track `fps_decoded` up to source fps, removing the
   30 Hz cap we documented in the G5 extended-ceiling note.

## What's explicitly NOT in this feature

- No change to the decoder pacing logic (A/V clock, skip-PB
  hysteresis, frame queue size, drop-oldest semantics). All
  unchanged.
- No change to audio path. Audio render callback runs
  independently of display.
- No per-video fps detection — decoder already knows its source
  fps. The display rate just *emerges* from the decoder's
  push rate.
- No Core Animation, no double-buffering beyond what OpenGL's
  already doing, no vsync changes (vsync checkbox still
  applies).
- Not attempting to lower decoder pacing on G3s that can't keep
  up with 60 fps content. Decoder still paces to audio clock;
  if it can't, drops happen (same as today).

## Open questions / assumptions to confirm

- **Q1.1. Bar timer rate: 5 Hz vs 1 Hz vs other.** The draft
  picks 5 Hz as the sweet spot between smoothness and savings.
  Alternative: 1 Hz (jumpy slider but cheapest), or even 10 Hz
  (barely cheaper than 30 Hz). **Still open**; 5 Hz is the
  default.
- **Q1.2. Keep the 30 Hz `displayTimer` as a residual
  audio-start / stats driver, or kill it entirely.** See Step 5.
  Leaning kill. **Still open.**
- **Q2.1. Should `tryDisplayNextFrame` be called under
  `@autoreleasepool` or similar?** On the main thread this
  should be a no-op (main thread has its run loop's pool), but
  under stress (many rapid triggers) there could be autoreleased
  objects accumulating. Leaning "no pool needed" since the
  method doesn't allocate Obj-C objects. **Still open.**
- **Q2.2. Coalescing flag mutex vs atomic BOOL.** A plain BOOL
  with memory-barrier writes works on PPC but requires careful
  ordering. A mutex is simpler. **Leaning mutex.**
- **Q2.3. When the player is destroyed with a pending
  `performSelectorOnMainThread` message in flight, what
  happens?** Probably: the message fires on the main thread, the
  controller is gone, crash. Mitigations: retain self in the
  post (like the curl threads do), or cancel pending
  performSelectors via
  `[NSObject cancelPreviousPerformRequestsWithTarget:self]` in
  `-dealloc`. **Still open**, leaning "cancel on dealloc".
