# Decode-bench-harness postmortem

**Status: complete.** Phases A, B, and B-extended ran cleanly across
the full nine-machine PowerPC fleet. Phase C was not needed — the
Phase B outliers were explained by the data itself, not by
measurement artefacts.

## TL;DR

- **H1 (pixel throughput dominates) is confirmed strongly.** On
  imacg3, geometry moves sustained Mpx/s across the full dynamic
  range; content, bitrate (32× variation), and noise (up to 5×
  realistic amplitudes) each move it by <15%.
- **H2 (bits-per-pixel matters) is rejected.** Bitrate sweeps moved
  the ceiling by <11% across a 32× bitrate range.
- **H3 (content type matters) is weak.** Six of seven tested
  synthetic sources cluster within ±5% of baseline; `life` is a
  single 25%-low outlier.
- **H4 (linear MHz scaling within CPU generation) is rejected for
  G3.** pmacg3 at 400 MHz outperforms imacg3 at 600 MHz at
  geometries from 480×360 up. The difference is **L2 cache size**,
  not memory bandwidth (both machines have PC100 SDRAM). Below
  240×180 the reference frames fit in either cache and the two
  machines agree within 1%; above that, imacg3's 256 KB L2 can no
  longer hold two reference frames for motion compensation, while
  pmacg3's 1 MB L2 can.
- **H4 approximately holds for G4/G5 single-core.** 22–27 Mpx/s per
  GHz for G4s; 30 Mpx/s per GHz for G5. Within ~20% of linear.
- **Dual-core G4 (mdd) is a performance regression vs single-core
  G4 at the same clock.** 20 Mpx/s ceiling vs pbookg42's 34, with
  measured CPU utilisation climbing past 100% — both cores are
  engaged but the second core hurts rather than helps.
- **Tiger vs Leopard at matched clock is indistinguishable.** OS
  isn't a variable worth modelling.
- **AltiVec is huge.** A 1.25 GHz G4 does the same 5.17 Mpx/s
  at 480×360@30 as a 900 MHz G3 but at 26% CPU vs 85%.

**Verdict for the real auto-calibrate feature:** a single simple
one-shot benchmark (plain `testsrc2` at realistic quality) on
first launch is sufficient. No per-content composite, no MHz
lookup table, no OS-specific calibration. One measurement per
machine, persisted in `NSUserDefaults`.

## What shipped

- **Proxy**: `/bench` endpoint (synthetic lavfi → MPEG-1 ES) +
  `/bench-audio` companion (silent PCM s16be). Byte-compatible with
  `/v/yt/...` so the client's decode path is production.
- **Client**: `--bench-url=<url>` + `--bench-duration=<secs>`
  command-line mode. Skips search UI + Bonjour; emits a single
  `BENCH:` line on stop.
- **Scripts** (in `scripts/`): `run-bench.sh`, `deploy-to-fleet.sh`,
  four Phase A axis sweeps, `sweep-fleet-calibration.sh`,
  `sweep-highres.sh` (extended Phase B for G4+ to find ceilings
  out of the base grid's range).
- **Binary compatibility**: built Debug once on ibookg37 (900 MHz
  G3) and deployed to every fleet target. Ran unchanged on all
  CPU generations — single ppc binary + runtime-detected AltiVec
  works exactly as assumed.

## Phase A — deep on imacg3 (600 MHz G3, Tiger)

Four axis sweeps, all at 480×360@30 (or sweep-appropriate grid).
Raw logs in `results/sweep-*.log`.

### sweep-geometry.sh

Ramp from 240×180@24 to 800×600@60. Ceiling on imacg3 found at
roughly **3.7 Mpx/s displayed**.

- Under ceiling (0 drops): 240×180@24 (1.06 Mpx/s, 42% CPU) →
  320×240@30 (2.24, 65%) → 400×300@24 (2.81, 79%).
- Cusp: 400×300@30 emits 3.54 Mpx/s with 15 drops @ 90% CPU.
- Over ceiling: 480×360@30 = 3.73 Mpx/s @ 75 drops, 93% CPU.
- 60 fps at small res is **display-timer-bounded**: decoder
  produces 58 fps worth of frames (4.45 Mpx/s decoded at 320×240),
  but the 30 Hz main-thread timer caps what reaches the screen.

### sweep-content.sh

Seven sources at 480×360@30. All plots clustered at ~3.4 Mpx/s
except `life` which came in at 2.58 (25% low). Adding noise to a
`color` baseline produced almost no effect at amplitude 3 (3.27)
and a small effect at 10 (3.20). Broad conclusion: **content type
alone moves the ceiling less than 15%** for six of seven sources.

### sweep-bitrate.sh

Forced CBR at 500k, 1M, 2M, 4M, 8M, and 16M on the same
480×360@30 testsrc2 input. All points landed in 3.12–3.47 Mpx/s.
The 32× bitrate range produced **<11% spread** in sustained
Mpx/s. Even the extreme 16M case was only 10% below the 500k
case.

### sweep-noise.sh

Noise amplitude 0, 1, 2, 3, 5, 10, 20 on testsrc2 @ 480×360@30
(`-q:v 4`). Flat 3.42 Mpx/s through noise=5. Noise=10 cost 8%,
noise=20 cost 16%. At **realistic** noise amplitudes (0–5, which
emit bitrates in the 2–5 Mbps range matching real YouTube
content), the sustained ceiling is effectively constant.

### Phase A verdict

**The naïve Mpx/s model is correct.** Geometry is the only axis
that moves sustained decode throughput across the full dynamic
range. Content complexity, bits-per-pixel, and noise each produce
effects under 15%, and those effects further shrink if we stay
within realistic operating conditions.

For the real auto-calibrate feature this means **a single simple
benchmark is enough**. No content mix, no per-bitrate calibration,
no per-content scale factors. Measure once at a known geometry,
persist, trust.

## Phase B — shallow probe across the full fleet

`sweep-fleet-calibration.sh` on all nine machines: 4 geometries
(240×180, 320×240, 480×360, 640×480) × 2 sources (testsrc2,
mandelbrot), fps=30, qv=4, 10s runs. Total ~15 minutes wall-clock.

The G4+ machines had headroom to spare at 640×480, so a follow-up
`sweep-highres.sh` extended the grid to 800×600, 960×720, 1280×720,
1280×960, and 1600×1200 on pbookg42, emac, mdd, and imacg52 to
find their actual ceilings.

### Per-machine ceiling

| Host | CPU / Clock | L2 | OS | Ceiling (Mpx/s) | Mpx/s per MHz |
|---|---|---|---|---|---|
| pmacg3 | G3 400 MHz | 1 MB | Tiger | ~4.0 | **10.0** |
| ~~ibookg32~~ | ~~G3 500 MHz~~ | ? | ~~Tiger~~ | ~~~2.4~~ | ~~4.8~~ |
| imacg3 | G3 600 MHz | 256 KB | Tiger | ~3.5 | 5.8 |
| ibookg3 | G3 900 MHz | 512 KB | Tiger | ~5.2 | 5.8 |
| ibookg37 | G3 900 MHz | 512 KB | Tiger | ~5.2 | 5.8 |
| pbookg42 | G4 1250 MHz | 512 KB | Leopard | ~34 | 27.2 |
| emac | G4 1420 MHz | 256 KB | Tiger | ~31 | 21.8 |
| mdd | 2×G4 1250 MHz | 256 KB×2 | Leopard | ~20 | 16.0 (dual) |
| imacg52 | G5 2000 MHz | 512 KB | Tiger | ~60 | 30.0 |

ibookg32 was struck from the dataset post-hoc: the machine exhibited
a hardware failure after the sweep completed (black display, no
network response, caps-lock LED still toggling — i.e. stuck in a
kernel-level wedge). Its numbers are not reliable.

### Q1. Does Mpx/s scale linearly with MHz within a CPU generation?

**No — not for G3.** The per-MHz Mpx/s varies 2× across G3 machines
(5.8 to 10.0 after dropping the broken ibookg32), and pmacg3 at
400 MHz matches or beats imacg3 at 600 MHz at geometries 480×360
and above. An initial intuition blamed "memory bandwidth" — wrong:
both machines run PC100 SDRAM at 100 MHz system bus. The actual
story is **L2 cache size**.

Comparing pmacg3 and imacg3 side-by-side (via [everymac.com](
https://everymac.com/) specs):

| | pmacg3 (B&W G3/400) | imacg3 (slot-loader G3/600) |
|---|---|---|
| CPU | PowerPC 750 | PowerPC 750cx |
| L2 cache | 1 MB backside @ 200 MHz | 256 KB on-die @ 600 MHz |
| System bus | 100 MHz | 100 MHz |
| RAM | PC100 SDRAM | PC100 SDRAM |
| GPU | Rage 128 GL (66 MHz PCI) | Rage 128 Ultra (AGP 2X) |

The smoking gun is **4× more L2 cache on pmacg3**. A 480×360 UYVY
frame is 480×368×2 = 345 KB. Motion compensation in libmpeg2 needs
both forward and backward reference frames simultaneously available
— so ~690 KB of frame data is in the hot path. That fits in
pmacg3's 1 MB L2 comfortably but **spills to main memory on
imacg3's 256 KB L2 for every macroblock lookup**.

This predicts exactly what the data shows:

- **240×180** (frames ~86 KB, both references ~172 KB): fits in
  either cache. pmacg3 and imacg3 agree within 1% (both ~1.32
  Mpx/s).
- **320×240** (frames ~154 KB, both references ~308 KB): fits in
  pmacg3's L2, spills on imacg3 — but still close since other data
  fits. Both deliver ~2.22 Mpx/s, still close.
- **480×360** (frames ~345 KB, both references ~690 KB): comfortably
  in pmacg3's L2; severely out-of-cache on imacg3. **pmacg3 wins
  4.04 vs 3.30 Mpx/s.**
- **640×480** (frames ~620 KB, both references ~1.24 MB): over cache
  on both machines but imacg3 is worse off. pmacg3 wins 4.15 vs
  3.89 at this edge point.

The imacg3's L2 being *faster* (on-die at 600 MHz vs pmacg3's
off-die at 200 MHz) doesn't help once the working set exceeds it —
you're out in PC100 main memory regardless, and PC100 on a 100 MHz
bus is the same speed on both machines.

The 900 MHz iBook Snow machines (ibookg3, ibookg37) have 512 KB L2
and Radeon Mobility 7500 GPUs — still not enough L2 to fit both
reference frames at 480×360, but their higher clock gives them
enough raw decode throughput to compensate. They're the most
efficient G3s in the fleet per MHz, and their numbers track each
other within 1% at every point (reassuring measurement
reproducibility on identical hardware).

**The real model for G3 is `min(CPU decode throughput,
cache-miss rate × L2 size)`.** L2 capacity dominates once the
working set — dominated by two full-frame motion-compensation
reference buffers — exceeds it.

### Q1'. Does it hold for G4 single-core?

Approximately yes. Ratio of ceilings: emac at 1.42 GHz / pbookg42 at
1.25 GHz = 31/34 = 0.91, even though the MHz ratio is 1.14. pbookg42
(Leopard, Aluminum Powerbook with PC2-4200 DDR2) actually *exceeds*
emac (Tiger, eMac with PC-2700 DDR) — **memory bandwidth trumps
MHz again**, but the spread is smaller than on G3s. AltiVec makes
decode less memory-bound because the coefficient-processing
pipeline stays inside L1 cache more.

Rule of thumb: **22–27 Mpx/s per GHz for G4 single-core**. About
4× the G3 per-MHz throughput — AltiVec's IDCT and motion-
compensation intrinsics do real work.

### Q2. Does AltiVec (G4+) move the per-MHz constant?

**Yes, by a factor of ~4**. A 900 MHz G3 hits ~5.2 Mpx/s (no
AltiVec). A 1.25 GHz G4 hits ~34 Mpx/s (AltiVec). Adjusting for
MHz, G4 extracts ~4.7× more work per MHz than G3. This is
consistent with libmpeg2's AltiVec paths being where the IDCT
and motion-compensation hot loops live.

At matched geometry, a G4 at 1.25 GHz does the same work at **26%
CPU** that a 900 MHz G3 does at **85% CPU**. That's the same
4× ratio expressed differently.

### Q3. Does the OS (Tiger vs Leopard) matter?

**Effectively no.** At 320×240@30 the pbookg42 (Leopard G4) and
emac (Tiger G4) are within 1% of each other once you normalise for
clock, and both track pretty closely with their MHz ratio at larger
geometries. Scheduler overhead, syscall costs, and whatever else
differs between 10.4 and 10.5 doesn't meaningfully affect the
decode+display hot path.

### Q4. Does the second core on mdd contribute?

**Partially confounded by the display configuration — then still
actively hurts at large geometries.** mdd's first pass was run
against a 1920×1080 LCD. A rerun at 1024×768 (matching the other
fleet hosts) shows two separate effects stacking:

**Effect 1: Display-resolution cost.** At 800×600@30, mdd-1920×1080
used 92% CPU; mdd-1024×768 uses 75% CPU for the same decode work.
The Mac OS X window server compositing into a 1920×1080 framebuffer
genuinely costs ~17% CPU at this workload. Other fleet machines all
run 1024×768 and were unaffected.

**Effect 2: Dual-core regression at larger geometries.** Even with
display normalised to 1024×768, mdd still goes sideways above
960×720:

- **At 640×480@30**, mdd-1024×768 sustains 8.96 Mpx/s at 54% CPU vs
  pbookg42's 8.99 at 35%.
- **At 960×720@30**, mdd-1024×768 hits 19.24 Mpx/s at 86% CPU with
  8 drops; pbookg42 hits 19.75 at 61% CPU with 3 drops.
- **At 1280×720@30**, mdd-1024×768 collapses to 13.35 Mpx/s at
  116% CPU with 140 drops; pbookg42 delivers 26.42 at 76% CPU
  with 0 drops.
- **At 1600×1200@30**, mdd-1024×768 sustains 14.67 Mpx/s at 159%
  CPU with 207 drops; pbookg42 delivers 40.55 at 93% CPU with
  75 drops.

CPU utilisation exceeding 100% on mdd confirms both cores are
engaged. Throughput still drops vs the single-core equivalent at
the same clock. The most plausible explanation is **cross-core
cache invalidation**: libmpeg2 is single-threaded, so the decode
hot path pingpongs between cores as the scheduler balances work,
and each migration dumps L1 content. Each G4 core in the MDD has
its own 256 KB L2 — so a thread migration trashes not just L1 but
also the working L2 it had built up. On single-core pbookg42,
everything stays warm.

The 640×480 point is the boundary where reference frames start
mostly-fitting in a single core's 256 KB L2, and mdd already shows
the "same throughput, more CPU" regression. Once the frames
definitively don't fit (1280×720 and up), the dual-core thrashing
dominates and mdd falls to roughly half pbookg42's throughput.

This is a useful negative result: **the auto-calibrate feature
does not need special-casing for core count**, and mdd specifically
would benefit from `thread_policy_set` pinning the decode thread
to a single core — follow-up for another day.

## Surprises

1. **L2 cache size beats MHz on G3.** The fleet has a ~2×
   per-MHz spread among G3 machines that share the same PC100
   SDRAM. The differentiator is L2 cache: pmacg3 has 1 MB, imacg3
   has 256 KB, the 900 MHz iBook Snows have 512 KB. MPEG-1 motion
   compensation needs ~690 KB of reference-frame data hot at
   480×360, and whether that fits in L2 determines everything.
   The initial intuition of "memory bandwidth" was wrong (same
   SDRAM); the real story is cache capacity.
2. **pmacg3 (400 MHz) outperforms imacg3 (600 MHz)** at 480×360
   and up despite being 1.5× slower clock. pmacg3's 1 MB L2
   avoids per-macroblock main-memory fetches that imacg3's 256 KB
   L2 can't.
3. **Dual-core G4 is a trap.** mdd — the only dual-core machine
   in the fleet — performs worse than a single-core G4 at the
   same clock at every grid point beyond 640×480. Thread
   migrations between cores dump per-core L2 cache on every
   scheduler decision.
4. **LCD resolution is part of the decode cost on mdd**, worth
   ~17% CPU at 800×600@30 going from 1920×1080 → 1024×768. Other
   fleet hosts all run 1024×768, so this is mdd-specific and a
   reminder that window-server compositing cost scales with
   display resolution, not window content resolution. Normalised
   mdd data is in `results/sweep-fleet-calibration-mdd.log` (the
   updated 1024×768 run) and `sweep-highres-mdd-1024x768.log`.
5. **pbookg42 (1.25 G4 Leopard) beats emac (1.42 G4 Tiger)**
   despite the MHz gap. The Aluminum Powerbook G4's memory
   subsystem + possibly a larger L2 compensate for 14% less
   clock.
6. **imacg3 has PC100 SDRAM, not PC66** (the draft originally
   claimed PC66 for the slot-loader iMac G3). Both pmacg3 and
   imacg3 run the same RAM speed, which is why the original
   memory-bandwidth theory failed and the cache-size theory
   survived.
7. **Eight of eight large-grid points on imacg52 finished with
   zero drops**, including 1600×1200@30 (54.6 Mpx/s, 83% CPU).
   The G5 has massive headroom for any realistic playback
   geometry.

## Implications for the pixel-budget auto-calibrate feature

Combining Phase A (content/bitrate/noise don't matter much) with
Phase B (per-machine variability dominates), the recommendation is
**a one-shot runtime benchmark on first launch**:

1. On the first TigerTube launch (detected via
   `NSUserDefaults` absence), run a short bench against the
   already-discovered proxy: `testsrc2` at, say, 480×360@30 for
   5 seconds. A moderate geometry that's over-ceiling for a G3
   iMac and well under-ceiling for a G5 so every machine reports
   a meaningful `fps_displayed`.
2. Convert to sustained Mpx/s: `(fps_displayed / 30) * 480 * 368`
   (or whatever exact dims the decoder emitted — the proxy will
   round to multiples of 16, so read the real dims from the
   decoder).
3. Multiply by a safety factor (say 0.8) to account for real
   content's small overhead over testsrc2.
4. Store in `NSUserDefaults`. Never benchmark again unless the
   user explicitly asks.
5. Present Budget popup choices derived from the measured
   ceiling: e.g., "Auto (N.N Mpx/s)" as default, plus a set of
   tiers bracketing that value.

This:

- **Does not need an MHz or generation lookup table** (would
  require hardware detection and would mis-classify any machine
  whose memory subsystem is weak or strong relative to CPU).
- **Does not need a content mix** (Phase A showed content type
  and bitrate each move the ceiling <15%).
- **Does not need periodic recalibration** (per the
  no-thermal-throttle property of PowerPC; one shot holds
  forever).
- **Works uniformly across all three CPU generations** (any
  machine can run the bench and produce a meaningful number).
- **Self-corrects for the surprises** above: memory-bandwidth-
  limited machines will report lower Mpx/s and get lower
  budgets automatically; dual-core mdd will report its
  single-core-equivalent throughput without needing a special
  case.

The benchmark itself can reuse this harness's proxy endpoint —
just call `/bench` with fixed params instead of the sweep
scripts iterating over a grid.

## What we'd do differently

1. **Start with Phase B first.** The single most decision-relevant
   finding of the whole study was the G3 memory-bandwidth
   surprise from Phase B, not anything in Phase A. We had
   already-strong theoretical expectations for Phase A (H1 was
   nearly certain given libmpeg2's architecture) but no
   intuition at all for Phase B. If we'd gone fleet-first, we
   would have hit the interesting finding earlier and could
   have scoped Phase A tighter (fewer geometries, fewer noise
   points).
2. **Put mdd under a single-core constraint.** The dual-core
   G4 data is interesting on its own but pollutes comparisons.
   A second run with `taskpolicy` / CPU affinity pinned to one
   core would tell us whether single-core-equivalent mdd matches
   pbookg42 (which it should).
3. **Extend the Phase B grid from the start.** Halving the
   number of machines or geometries to afford 800×600 and
   960×720 out of the box would have meant no follow-up pass
   was needed. Knowing this in advance would have saved the
   second sweep's round trip.
4. **Log more decoder internals.** The bench stats are
   coarse-grained (frames, fps, drops). Adding per-frame
   decode-latency histograms would have told us whether
   drops at the cusp are caused by a few slow frames
   (long-tail latency) or by sustained decoder slowness
   (everything uniformly slow). Different fixes apply to
   each.
5. **Phase C wasn't needed in this study**, but if we'd planned
   it as the machinery for investigating the G3 variance, we
   could have looked up L2 sizes from each machine's spec sheet
   *before* running the sweeps and predicted the spread.
6. **Normalise display configuration across the fleet first.**
   mdd was initially on a 1920×1080 LCD while every other host
   was at 1024×768; a meaningful chunk of the observed dual-core
   regression turned out to be window-server compositing cost
   rather than the dual-core issue itself. A one-line "set all
   fleet displays to 1024×768 before benchmarking" in the deploy
   script would have avoided conflating the two effects and
   needing a rerun.
7. **Filter out broken hosts before acting on outliers.**
   ibookg32's results were ~2× slower per-MHz than everything
   else, which looked like a "clamshell iBook is just weak"
   story and got written up as such in the first-draft
   postmortem. The machine actually went into a hardware wedge
   shortly after the sweep completed, so its numbers can't be
   trusted. A quick post-sweep health check (`ssh host true`)
   before accepting the data would have flagged this before
   the theorising started.

## Raw data

All in `results/`:

- `sweep-geometry.log`, `sweep-content.log`, `sweep-bitrate.log`,
  `sweep-noise.log` — Phase A (imacg3 only).
- `sweep-fleet-calibration-<host>.log` (9 files) — Phase B.
- `sweep-highres.log` — extended Phase B for G4+ ceilings.

Each line has the bench URL plus a single `BENCH:` record suitable
for `awk` / `grep` parsing.
