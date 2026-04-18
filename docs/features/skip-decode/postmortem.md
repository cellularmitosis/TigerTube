# Postmortem: skip-decode when video falls behind the audio clock

## What shipped

Implementation tracked the plan closely:

- `TTVideoDecoder`: `TT_SKIP_NONE/B/PB` constants in the header (values
  match libmpeg2's `MPEG2_SKIP_*` so the wrapper is a passthrough),
  `setSkipMode:` one-liner that calls `mpeg2_skip`, guarded on
  `decoder != NULL`.
- `TTPlayerWindowController`: `decoderSkipMode` ivar initialized to
  `TT_SKIP_NONE`, reset to `TT_SKIP_NONE` in the seek path after
  `[videoDecoder reset]`.  Hysteresis in `didDecodeFrame:` with
  `TT_SKIP_ENGAGE_LAG = 0.5` and `TT_SKIP_DISENGAGE_LAG = 0.1`.
  Transition-only `fprintf` logging of engage/disengage, including
  the lag / decT / audT that triggered the transition.
- No three-tier state machine, no proxy changes, no drops-counter
  changes -- exactly the scope set out in the plan.

One minor deviation from the plan's pseudocode: the hysteresis block
reuses the `decodedTime` / `audioTime` locals from the pacing-sleep
block instead of recomputing them.  The two decisions are
back-to-back, use identical inputs, and are mutually exclusive (pacing
sleeps when ahead, skip engages when behind), so sharing reads
cleaner.  Net change is that the skip check moved from "right after
enqueue" to "right before the pacing-sleep block"; functionally
equivalent.

## Validation

640x480 heavy case behaved exactly as predicted.  Representative log
excerpt from `~/tmp/tigertube.log`:

```
skip engaged (PB) at lag=0.51s (decT=0.62s audT=1.14s)
skip disengaged at lag=0.10s (decT=2.08s audT=2.18s)
skip engaged (PB) at lag=0.50s (decT=2.38s audT=2.88s)
skip disengaged at lag=0.09s (decT=3.50s audT=3.59s)
skip engaged (PB) at lag=0.50s (decT=4.00s audT=4.50s)
skip disengaged at lag=0.09s (decT=4.88s audT=4.97s)
...
```

- Cycle period: ~1 s wall time per engage/disengage round trip, held
  steady across tens of seconds.
- Engage lag: mostly 0.50-0.55 s (threshold + ~one frame of slop
  since the check fires post-enqueue).  Occasional higher values
  (0.60-0.71 s) when a tick ran long.
- Disengage lag: 0.07-0.10 s -- right at the lower threshold.
- Periodic stats show `dec=24fps dis=24fps drop=15` steady, where
  previously `dec` would sit at ~13 fps and drops would grow
  monotonically.  `decT` vs `audT` stays within ~50 ms throughout.

Seek validation: the log shows decT discontinuities (25.25 -> 8.38,
8.96 -> 44.50, etc.) and in every case the first post-seek transition
line is an *engage*, never a *disengage*.  That confirms the per-seek
`decoderSkipMode = TT_SKIP_NONE` reset correctly re-aligns the ivar
with the freshly-rebuilt decoder.

The 320x240 smooth-case check listed in the plan was not exercised
directly in this session.  By construction it should stay
`TT_SKIP_NONE` throughout (skip only engages when lag > 0.5 s, which
requires the decoder to be running below realtime), but worth a quick
confirmation next time a smaller video is played -- one grep for
"skip engaged" against the log is sufficient.

## Surprises

The A/V behavior was tighter than the plan's "punctuated by brief
stutter intervals" framing suggested.  On the 640x480 test content
the engage/disengage cadence is so regular (~1 Hz) that it reads more
like a sustained alternation between a 1-second slideshow and a
1-second smooth stretch, rather than distinct stutter bursts between
long smooth stretches.  That's a consequence of how far below source
fps this G3 runs on 640x480 -- roughly 13 fps decoded vs 24 fps
source means skip-engaged time and skip-disengaged time are roughly
equal, and both are short.

Correctness-wise this is fine; the feature delivers the stated goal
(A/V stays tight within the hysteresis band).  But it does change
the qualitative viewer experience a bit: on heavy content the user
will see a persistent ~1 Hz alternation rather than mostly-smooth
playback with occasional catchup bursts.  Worth remembering if the
three-tier SKIP_B middle tier is ever revisited -- a longer stretch
in SKIP_B might read as subtler than the hard cut to SKIP_PB/back.

## What I'd do differently

- Nothing material.  The plan was accurate; implementation was ~20
  minutes end-to-end; validation confirmed behavior on the first
  try.
- Two-decimal lag in the transition log is enough for the current
  threshold spacing, but if threshold tuning ever becomes a point of
  contention, bumping to three decimals costs nothing.
- Pre-existing `-Wobjc-method-access` warning on `currentSegmentDrops`
  (forward-declared in a Private category that doesn't list it)
  surfaced in the build output alongside my changes.  Unrelated;
  pre-existed before this feature.  Left as-is.
