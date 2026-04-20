# Decode-bench harness (experimental research tool)

> **Status: first draft, pending review.** Drafted with assumptions
> marked **[ASSUMPTION]** for fast review. Collected at the bottom.

## Problem

Before we commit to the [pixel-budget](../pixel-budget/plan.md) feature
and especially its auto-calibrate variant (one-shot benchmark on first
launch that measures the machine's sustained Mpx/s ceiling), we need
to understand which factors actually dominate libmpeg2 decode cost on
PowerPC G3/G5:

- **Raw pixel throughput** — W × H × fps.
- **Bitrate / bits-per-pixel** — per-coefficient work in VLC decoding
  and inverse quantization scales with non-zero DCT coefficients.
- **Content complexity** — static regions and predictable motion
  short-circuit through the zero-coefficient IDCT fast path; real
  content does not.
- **Noise / high-frequency detail** — overlaying noise on a simple
  source destroys both temporal and spatial redundancy and, at fixed
  `-q:v`, sends the emitted bitrate up by an order of magnitude.

Informal bench-piping on uranium (this laptop) suggests these factors
are not independent — adding noise to `testsrc2` bumped the encoded
bitrate from 2.5 Mbps to 10.4 Mbps at the same W×H×fps — but we don't
know how much each dimension moves the decoder's wall-clock cost on a
G3 specifically.

A flexible research harness that lets us measure sustained decode
performance across these dimensions — and keeps the exact invocations
around for reproducibility — will tell us whether:

- A single simple benchmark (e.g., plain `testsrc2`) captures most of
  the variance and is enough to drive auto-calibration, **or**
- We need a composite benchmark (multiple runs at different points in
  the parameter space) to derive a reliable Mpx/s ceiling, **or**
- The answer is nonlinear enough that the "no explicit benchmark,
  measure achieved fps during first real playback" approach wins.

## Dimensions and hypotheses

The harness is designed to disentangle four independent-ish variables
that could plausibly dominate libmpeg2's wall-clock decode cost, and
to test each against a falsifiable hypothesis.

### The four dimensions

**1. Pixel throughput (W × H × fps).** The naïve "Mpx/s" axis. Every
per-pixel decode step (IDCT fixed cost, motion compensation traversal,
UYVY output write, GL upload) scales with this. If nothing else
mattered, this alone would determine the machine's ceiling.

**2. Bitrate / bits-per-pixel.** Per-coefficient work in bitstream
parsing (VLC) and inverse quantization scales with how many non-zero
DCT coefficients live in the stream. At a fixed W×H×fps, a 10 Mbps
stream does proportionally more VLC parsing than a 1 Mbps stream.

**3. Content complexity.** Even at matched bitrate, different content
exercises different decoder paths. Static regions and predictable
motion short-circuit through "all-zero block" IDCT fast paths and
cheap motion vectors. Real-world video sits in the middle; synthetic
lavfi sources give us deliberate corner cases.

**4. Noise / high-frequency detail.** A forcing function for dimension
2: overlay `noise=alls=N` on any source and you can dial bits-per-pixel
arbitrarily high without changing pixel count. Lets us test whether
bitrate really does dominate at fixed geometry.

### Machine variables (the orthogonal fleet axis)

On top of the four stream-side dimensions, the fleet of nine PowerPC
Macs (G3 400 MHz → G5 2 GHz, Tiger and Leopard, single- and dual-core)
gives us additional orthogonal variables:

- **Clock frequency** (within a CPU generation).
- **CPU generation** (G3 vs G4 with AltiVec vs G5).
- **OS** (Tiger vs Leopard).
- **Core count** (single G4 vs dual G4 on mdd).

See "Multi-machine methodology" below for how these factor in.

### Hypotheses

**H1. Pixel throughput dominates.** If the sustained Mpx/s ceiling is
independent (within, say, 10%) of bitrate, content, and noise at fixed
W×H×fps, then the naïve Mpx/s model is correct. The real feature just
needs to benchmark decode at some Mpx/s target and apply a scaling
factor, and we're done.

*Falsifying evidence:* `sweep-bitrate.sh` shows a clear monotonic
drop in sustained Mpx/s as bitrate rises from 500 kbps to 16 Mbps at
fixed geometry. Or `sweep-content.sh` shows >10% spread across source
types at fixed geometry and quality.

**H2. Bits-per-pixel is a meaningful second factor.** The real
benchmark must target a representative bits-per-pixel (matching what
the proxy actually serves on real content), otherwise the measured
ceiling won't transfer. This is currently ~0.5 bits/pixel based on the
initial exploration (rickroll re-encoded to MPEG-1 at `-q:v 4`).

*Confirming evidence:* `sweep-bitrate.sh` shows sustained Mpx/s
dropping by more than 10% as bitrate rises at fixed geometry.

**H3. Content type, even at matched bitrate, matters.** Different
synthetic sources exercise different fast paths; real content doesn't
fit any single synthetic profile.

*Confirming evidence:* `sweep-content.sh` at fixed `-q:v 4` shows
different sources with similar emitted bitrates (say, all within
20% of 2.5 Mbps) still producing meaningfully different sustained
Mpx/s on the client.

**H4. Machine variables scale linearly, preserve ranking.** The
relative ranking of bench configurations (which sources are "harder",
which geometries are at the ceiling) is stable across the fleet; only
the absolute numbers change. Specifically, within a CPU generation,
sustained Mpx/s scales linearly with clock frequency.

*Confirming evidence:* `sweep-fleet-calibration.sh` on the G3 fleet
(five machines, 400–900 MHz, Tiger) shows sustained Mpx/s
proportional to clock within ~5%. If this holds, **the auto-calibrate
feature doesn't need a runtime benchmark at all** — a lookup table of
"Mpx/s per MHz per CPU generation" plus `sysctl hw.cpufrequency` at
launch gives the answer for free.

*Falsifying evidence:* nonlinear MHz scaling, or different relative
rankings of bench configs on G3 vs G5. Either forces us back to
runtime calibration.

### What the hypotheses buy us

If **H1 is true** and **H4 is true**: the simplest possible world. A
lookup table indexed by CPU generation and clock speed produces the
ceiling. No benchmark at launch, no ffmpeg encoding on demand, no
calibration stream. The pixel-budget feature can ship a static
mapping table.

If **H1 is false** and **H4 is true**: a runtime benchmark is needed
but a *single simple clip* suffices because the ranking is stable.
Run it once on first launch, persist the number, done. This is the
middle-complexity outcome.

If **H4 is false**: we need machine-class-specific benchmark
strategies or per-machine runtime calibration with a composite
benchmark. Highest-complexity outcome.

The harness exists to figure out which world we're in before we
commit to the real feature's design.

## Solution overview

Three pieces:

1. **Proxy: `/bench` endpoint.** Accepts query parameters describing a
   synthetic video stream (source, geometry, fps, rate-control mode,
   bitrate or quality target, optional noise, duration, GOP). Emits
   raw MPEG-1 ES — byte-compatible with what `/v/yt/...` and
   `/v/file/...` already emit — so the decode path is identical to
   real playback.

2. **Client: `--bench-url=<url>` command-line mode.** When launched
   with this flag, TigerTube skips the YouTube search UI entirely and
   opens a player window pointed directly at the given URL. Optional
   `--bench-duration=<secs>` auto-quits after N seconds. On quit, the
   client dumps a single `BENCH:` line to stderr summarising measured
   fps, display drops, decoded frames, and sustained Mpx/s.

3. **Plan-adjacent sweep scripts** in this directory's `scripts/`.
   Each script runs a parameter sweep via the bench endpoint, calls
   the `--bench-url` mode repeatedly on imacg3, and captures the
   stderr `BENCH:` lines. They are the record of which experiments
   were run so results stay reproducible.

## Design decisions (and rationale)

### Why a research harness, not "just build the feature"

The [pixel-budget plan](../pixel-budget/plan.md) picks tier values
(1 / 2 / 4 / 8 / 16 Mpx/s) partly by inference from 320×240@24
existing defaults. If that inference is wrong — if bitrate matters
more than pixel count, or if content complexity swamps both — the
tiers will be in the wrong place and auto-calibration will produce
misleading numbers. A throwaway afternoon of sweeping is cheap
insurance against landing a feature that bakes in a wrong
mental model.

### Why a command-line mode in the existing app, not a separate test app

- The existing app already has libcurl + libmpeg2 + CoreAudio + the
  GL upload path wired together correctly. Duplicating that into a
  second app target (and keeping them in sync) is busy-work.
- `--bench-url` is dormant when not passed; users never see it.
  There's no user-facing cost to leaving it in production.
- A curious person who discovers it can harmlessly play with it —
  pointing their client at a proxy's `/bench` endpoint is not a
  dangerous operation.

### Why server-side synthetic content, not a bundled clip

- A bundled clip bakes in one encoder configuration forever and drifts
  from whatever the proxy actually serves if we ever retune encode
  settings. Proxy-generated content stays aligned with production by
  construction.
- lavfi's synthetic sources (`testsrc2`, `mandelbrot`, `color`, `life`,
  etc.) plus the `noise` filter cover the axes we want to explore
  without shipping any binary media.
- Cost of running on demand: ~100 ms of ffmpeg spin-up per
  invocation, well within experiment tolerance.

### Why raw MPEG-1 ES output (not mpegts)

Production `/v/yt/...` and `/v/file/...` emit raw MPEG-1 ES via
`-f mpeg1video pipe:1`. The bench endpoint matches for two reasons:

1. The client's decode path expects raw ES — `feedData:` into
   libmpeg2 without a demuxer in the middle.
2. We want the decoder to see exactly what production gives it.
   Adding an mpegts container would exercise a separate parse path
   (or none, depending on client-side handling) and the measurement
   would not transfer.

`mpegts` was convenient for piping into `ffplay` during exploration on
uranium. It is the wrong choice for the client-facing bench stream.

### Why an opaque `--bench-url` (not individual `--bench-w`, etc.)

The URL is built by shell scripts that iterate parameter grids. Making
the client parse and reassemble the parameter space would duplicate
logic that already needs to live in the sweep scripts. One opaque
flag, and the harness complexity lives in one place.

### Why `BENCH:`-prefixed stderr lines (not JSON, not a file)

- Sweep scripts already SSH to imacg3 and pipe stderr; `grep
  "^BENCH:"` is a one-liner.
- Plain-text key=value columns are trivially parseable with `awk` for
  follow-on aggregation.
- JSON would force pulling in a formatter and doesn't buy anything
  at this scale. We can add JSON later if a real dashboard emerges.
- Writing to a file would need a convention for file naming and
  cleanup. stderr is the existing norm for TigerTube's diagnostic
  output.

### Why we measure display drops, not decoder underrun, as the "drop" signal

Display drops (the main-thread 30 Hz timer dequeues and finds the
queue empty) capture the full pipeline — decode + GL upload + color
conversion + contention with audio. The G3's bottleneck isn't always
pure decode (the Rage 128 Pro's texture upload path is not free).
Decoder-internal underrun would miss that.

### Why the bench stream has no audio track

- Audio decode cost on the G3 is trivial (s16be PCM passthrough into
  a ring buffer). Including it would only add a confounding variable
  to video-decode measurements.
- The audio player already tolerates a missing audio stream
  gracefully (the existing YouTube path sometimes races and the
  audio fetch completes after video ends without issues).
- Simpler ffmpeg invocation, simpler URL shape.

### Why sweep scripts live in the plan directory (not in a toplevel `scripts/`)

- The plan directory is the unit of reproducibility. Someone reading
  `plan.md` six months from now can find the exact sweeps we ran in
  the same place — no hunting.
- These scripts are not part of the shipped product. They don't
  belong alongside `run_and_log.sh` or `tiger-rsync.sh`.
- The postmortem (eventually) will reference the same scripts and
  summarise the results they produced.

## Multi-machine methodology

The fleet of nine PowerPC Macs (see the "PPC test fleet" project
memory for hostnames and specs) makes this more than a single-machine
benchmark — it's a cross-generation performance study. Structuring
the work in three phases keeps the cost proportional to the
information gained.

### Phase A — deep investigation on imacg3 (600 MHz G3, Tiger)

All four sweeps (`sweep-geometry`, `sweep-content`, `sweep-bitrate`,
`sweep-noise`) run end-to-end on imacg3. This is where we form the
hypothesis about which dimensions dominate decode cost (H1 vs H2
vs H3).

Why imacg3 specifically:

- The dev-loop scaffolding (`run_and_log.sh`, `tiger-rsync.sh`,
  CLAUDE.md's notes on Xcode-dependency-tracking quirks) is already
  there — no setup cost.
- A 600 MHz G3 is slow enough to hit decode ceilings within every
  sweep's parameter range, so we see actual *shape* in the data
  (the curve bends where the ceiling is) rather than "everything
  works, numbers indistinguishable."
- But fast enough to produce useful absolute numbers — we don't
  want to characterize the slowest-possible machine and then scale
  up blindly.

Expected wall-clock: ~10–15 minutes per full sweep × 4 sweeps ≈ 1
hour of bench runtime, plus setup.

### Phase B — shallow probe across the full fleet

A single script, `sweep-fleet-calibration.sh`, runs the same
stripped-down probe on every machine:

- 4 geometries: 240×180, 320×240, 480×360, 640×480
- 2 sources: testsrc2 (baseline) and mandelbrot (complex motion)
- Fixed fps=30, qv=4, dur=10
- Total: 8 bench runs × ~12s each ≈ 100 seconds per machine
- Across 9 machines: ~15 minutes wall-clock (sequential)

This phase tests H4 (machine variables scale cleanly) and answers
four questions single-machine Phase A cannot:

**Q1. Does Mpx/s scale linearly with MHz within a CPU generation?**
Five G3s at 400 / 500 / 600 / 900 / 900 MHz give a clean regression.
If linear within ~5%, the real feature doesn't need a runtime
benchmark at all — a per-generation Mpx/s/MHz constant plus
`sysctl hw.cpufrequency` gives the answer. This is the *most
valuable possible outcome* and is the single most important thing
to measure early.

**Q2. Does AltiVec (G4+) move the per-MHz constant?**
libmpeg2's runtime-selected AltiVec IDCT is the likely hotspot. If
the G4 at 1.25 GHz exceeds the fastest G3 (900 MHz) by more than
the 1.39× MHz ratio, AltiVec is contributing real work. Expect
this to be true — the question is by how much.

**Q3. Does the OS matter?**
Comparing G4-class machines across Tiger (emac @ 1.42 GHz) and
Leopard (pbookg42 @ 1.25 GHz, mdd @ 2×1.25 GHz) controls for
generation while varying OS. Clock doesn't quite match, so we have
to use the Phase B data to normalize by MHz first. If per-MHz
numbers match between Tiger G4 and Leopard G4, OS is not a variable
we need to model.

**Q4. Does the second core on mdd contribute?**
libmpeg2 is single-threaded, but the app's pipeline isn't — curl
fetch threads, display timer, CoreAudio render callback, and the
main run loop all exist. If mdd (2×1.25 GHz G4) meaningfully
exceeds a hypothetical single-core 1.25 GHz G4 (interpolated from
emac's 1.42 GHz data), the non-decode pipeline is worth modeling;
otherwise the second core is idle and we can treat mdd as a
single-core G4 for calibration purposes.

### Phase C — targeted follow-up on any outliers

If any Phase B machine produces numbers that don't fit the
hypothesis refined in Phase A (e.g., a G3 whose per-MHz scaling is
off, or Leopard showing a consistent offset from Tiger), run the
full sweep set on that machine to figure out why. Don't run Phase
C speculatively.

### Starting order for Phase B

Run the **two clock-frequency extremes first** to bracket the full
dynamic range before filling in the middle:

1. **pmacg3** (400 MHz G3, Tiger) — slowest in the fleet; expected
   to hit ceilings at the smallest geometries.
2. **imacg52** (2.0 GHz G5, Tiger) — fastest; expected to sail
   through every point.

If the two extremes produce results consistent with H4, the
intermediate machines should fit the curve cleanly. If they
disagree more than expected, the middle data points will tell us
where the non-linearity lives.

Then fill in frequency scaling within the G3 generation:
3. **ibookg32** (500 MHz G3, Tiger)
4. **ibookg3** and **ibookg37** (900 MHz G3, Tiger — two machines
   at the same clock, nice redundancy check)
5. **imacg3** (600 MHz G3, Tiger — already covered by Phase A; the
   abbreviated Phase B pass verifies consistency)

Then CPU-generation and OS effects:
6. **emac** (1.42 GHz G4, Tiger) — single-core G4 baseline
7. **pbookg42** (1.25 GHz G4, Leopard) — Leopard G4
8. **mdd** (2×1.25 GHz G4, Leopard) — dual-core + Leopard

### Build and deploy

**Build machine: ibookg37** (900 MHz G3, Tiger).

Two reasons:

1. **Fastest G3 available.** 900 MHz > 600 MHz (imacg3) > 500 MHz
   (ibookg32) > 400 MHz (pmacg3). Builds faster than any other G3.
2. **G3 build environment.** Building on a G3 guarantees the
   resulting ppc binary doesn't inadvertently pick up a G4- or
   G5-only code path from the host. Xcode's `-arch ppc` +
   `-mmacosx-version-min=10.4` is meant to give the same output
   regardless of the build machine, but building on a G3 makes that
   a verified property rather than an assumption.

Running a G3-built binary on the G4s and G5 is itself a
compatibility test — it validates the CLAUDE.md assumption that
"AltiVec is runtime-detected; single ppc binary serves both."
If the binary runs on imacg52, we have confirmation.

**Deploy: `tiger-rsync.sh` for every target.**

CLAUDE.md specifies `tiger-rsync.sh` (on uranium) for
uranium → Tiger transfers, with the `--protocol=27 --no-dirs`
flags that a modern rsync needs to talk to Tiger's 2005-era
rsync. The user has confirmed we should use `tiger-rsync.sh`
uniformly for the Leopard machines (pbookg42, mdd) as well — the
extra flags don't hurt Leopard, and keeping one consistent
command for the whole fleet is simpler than branching on OS.

Deploy sequence:

1. Build Debug on ibookg37: `ssh ibookg37 "cd tmp/TigerTube &&
   xcodebuild -configuration Debug"`.
2. Pull the built `.app` from ibookg37 to uranium into a staging
   directory (using `tiger-rsync.sh` in pull mode).
3. Push from the staging directory to each fleet target (using
   `tiger-rsync.sh` per target).

Step 2 → Step 3 round-trips through uranium because
`tiger-rsync.sh` runs locally on uranium and talks to one remote
at a time; going host-to-host directly would bypass it.

The `scripts/deploy-to-fleet.sh` script automates all of the
above.

## Proxy: `/bench` endpoint

### URL shape

```
GET /bench
  ?source=<name>       [required]  testsrc2 | testsrc | mandelbrot |
                                   color | life | smptebars |
                                   rgbtestsrc | cellauto | gradients
  &w=<int>             [required]  output width (pixels)
  &h=<int>             [required]  output height (pixels)
  &fps=<num>           [required]  output framerate
  &dur=<int>           [required]  stream duration (seconds)
  &rc=<q|cbr>          [optional]  rate-control mode  (default: q)
  &qv=<int>            [optional]  quality scale 1-31, if rc=q  (default: 4)
  &bv=<bitrate>        [optional]  target bitrate, if rc=cbr    (e.g., "2M", "2000k")
  &noise=<int>         [optional]  noise filter amplitude (0-100); omitted = no noise
  &g=<int>             [optional]  GOP size  (default: fps, matching existing proxy)
```

### Source types and what they test

| source | compressibility | motion | intended signal |
|---|---|---|---|
| `testsrc2` | high (large static regions + counter) | low-moderate | baseline |
| `testsrc` | high | low | older classic |
| `mandelbrot` | low-medium (climbs over zoom) | smooth | detail-heavy temporal redundancy |
| `color=c=gray` | very high (single color) | none | minimum work; pair with noise |
| `life` | medium | chaotic | unpredictable motion |
| `cellauto` | medium | banded | vertical scrolling pattern |
| `gradients` | very high | smooth | low-detail motion |
| `smptebars` | very high | none | mostly I-frames |
| `rgbtestsrc` | very high | none | ditto |

These nine cover a spread of "easy → hard" for the encoder and
therefore the decoder. Not all will be swept in every experiment;
`scripts/sweep-content.sh` compares a curated subset.

### ffmpeg command shape

```python
def build_bench_cmd(source, w, h, fps, dur, rc, qv, bv, noise, g):
    # Input filter graph: synthetic source, optional noise overlay
    src_expr = f"{source}=size={w}x{h}:rate={fps}"
    if noise is not None:
        src_expr = f"{src_expr},noise=alls={noise}:allf=t"

    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning",
        "-f", "lavfi", "-i", src_expr,
        "-t", str(dur),
        "-an", "-sn",
        "-c:v", "mpeg1video",
    ]
    if rc == "q":
        cmd += ["-q:v", str(qv)]
    else:  # rc == "cbr"
        cmd += [
            "-b:v", bv,
            "-minrate", bv,
            "-maxrate", bv,
            "-bufsize", bv,
        ]
    cmd += [
        "-g", str(g if g is not None else int(round(fps))),
        "-force_key_frames", "0",
        "-f", "mpeg1video",
        "pipe:1",
    ]
    return cmd
```

The route handler:

1. Parses the query string with a small `parse_bench_params`
   (mirrors `parse_video_params`).
2. Validates `source` is in the allowed set, `w/h/fps/dur` are
   positive, `rc` is one of `q|cbr`, required sub-params are present
   for the chosen `rc`.
3. Logs the constructed ffmpeg command (`print(..., flush=True)`),
   so the proxy stderr has an exact replay of every bench stream
   served. Matches the existing pattern in `GET_video_yt`.
4. Calls `stream_ffmpeg(handler, cmd, "video/mpeg")`.

### Route registration

```python
add_static_route("GET", "/bench", GET_bench)
```

Static route (no path-parameter regex needed — everything is in the
query string).

## Client: `--bench-url` mode

### Argv parsing

In `-[AppController applicationDidFinishLaunching:]`, scan
`[[NSProcessInfo processInfo] arguments]` **before** calling
`buildWindow`. Recognise two flags:

- `--bench-url=<url>` — activates bench mode.
- `--bench-duration=<secs>` — auto-quit timer (optional; if omitted,
  app runs until the bench stream naturally ends or user quits).

If `--bench-url` is absent, normal flow unchanged.

### Bench-mode launch path

```objective-c
- (void)applicationDidFinishLaunching:(NSNotification*)note {
    fprintf(stderr, "=== TigerTube launched (build %s %s) ===\n", __DATE__, __TIME__);
    curl_global_init(CURL_GLOBAL_DEFAULT);

    NSString* benchURL = [self benchURLFromArgs];
    double benchDuration = [self benchDurationFromArgs];  /* 0 = no limit */

    if (benchURL != nil) {
        [self launchBenchMode:benchURL duration:benchDuration];
        return;  /* skip buildWindow entirely */
    }

    /* ... existing flow ... */
}
```

`launchBenchMode:duration:`:

1. Creates a minimal `TTPlayerWindowController` configured with the
   bench URL and a bench-mode flag.
2. If `duration > 0`, schedules a main-thread timer that calls
   `[self quitAndDumpStats]` after `duration` seconds.
3. When the player window is closed (by the timer or by the user),
   dumps `BENCH:` stats to stderr, then `[NSApp terminate:]`.

No search UI, no Bonjour discovery, no proxy browsing. The bench URL
is absolute — the user passes in the full `http://uranium.local:5002/bench?...`
URL — so proxy discovery isn't needed.

### Stats collection

`TTPlayerWindowController` grows a `BenchStats` struct (or just a
handful of counters) updated by its existing hot paths:

```objective-c
typedef struct {
    uint64_t frames_decoded;       /* incremented in didDecodeFrame: */
    uint64_t frames_displayed;     /* main-timer tick drew a frame */
    uint64_t display_drops;        /* main-timer tick found empty queue */
    uint64_t audio_underruns;      /* existing counter, reused */
    double   decode_latency_sum;   /* sum of (decoded_at - fed_at) */
    uint64_t decode_latency_n;     /* for mean computation */
    double   bench_start_time;     /* CACurrentMediaTime() at playback start */
    double   bench_end_time;       /* filled at quit */
} TTBenchStats;
```

All fields are plain `uint64_t` / `double` incremented on their
respective threads. The decoder thread increments `frames_decoded`
and contributes to latency; the main thread increments
`frames_displayed` and `display_drops`. No locking — these are
non-critical counters read only at quit, and the stats dump
happens after the threads are joined.

`quitAndDumpStats`:

```objective-c
- (void)dumpBenchStats {
    double wall = stats.bench_end_time - stats.bench_start_time;
    double fps_decoded  = wall > 0 ? stats.frames_decoded  / wall : 0;
    double fps_displayed= wall > 0 ? stats.frames_displayed/ wall : 0;
    double mean_latency = stats.decode_latency_n > 0
        ? stats.decode_latency_sum / stats.decode_latency_n : 0;
    double mpxs = /* computed from W×H×fps_decoded */;

    fprintf(stderr,
        "BENCH: wall=%.3f frames_decoded=%llu frames_displayed=%llu "
        "display_drops=%llu audio_underruns=%llu "
        "fps_decoded=%.2f fps_displayed=%.2f decode_latency_ms=%.2f "
        "mpxs_sustained=%.3f\n",
        wall, stats.frames_decoded, stats.frames_displayed,
        stats.display_drops, stats.audio_underruns,
        fps_decoded, fps_displayed, mean_latency * 1000.0, mpxs);
}
```

One line; greppable; awk-parseable.

### Knowing the stream's W×H client-side

For `mpxs_sustained` we need the stream's resolution. Three options:

1. **[ASSUMPTION]** Parse it out of the bench URL (`w=...&h=...`)
   in the client. Simple, client already sees the URL.
2. Query a new proxy `/bench-probe` endpoint that returns the
   computed dims as JSON. Clean separation but more code.
3. Read it from the decoded stream's sequence header after libmpeg2
   emits the first frame. Most accurate (captures whatever ffmpeg
   actually encoded at, rounded to multiples of 16 or whatever). But
   requires plumbing through `TTVideoDecoder` that doesn't exist yet.

Assumption: (1) is fine for a research harness. If the user passes
mismatched `w=/h=` and the proxy rounds, the Mpx/s calculation will
be slightly off. Acceptable.

## Files touched

- `proxy/tigertube-proxy.py`:
  - New `build_bench_cmd(...)` helper.
  - New `parse_bench_params(query_dict)`.
  - New `GET_bench(handler)` route handler.
  - One `add_static_route` call.
- `src/AppController.{h,m}`:
  - Argv parsing helpers (`benchURLFromArgs`, `benchDurationFromArgs`).
  - Bench-mode branch in `applicationDidFinishLaunching:`.
  - `launchBenchMode:duration:` method.
- `src/TTPlayerWindowController.{h,m}`:
  - `TTBenchStats` struct and counter updates in existing hot paths.
  - `-initWithBenchURL:duration:` initialiser (or a bench-mode flag
    on the existing init path).
  - `-dumpBenchStats` method.
- `src/TTVideoDecoder.{h,m}`:
  - Latency timestamps (feed-time and decode-time) added to the
    existing frame queue slots.
  - Counter increments on decode.
- `docs/features/decode-bench-harness/scripts/*.sh` — see below.

No changes to the audio path. No new Cocoa nibs. No vendored-library
changes.

## Implementation steps

Each step is small enough to land on its own; later steps depend on
earlier ones.

### Step 1 — Proxy `/bench` endpoint

Add `build_bench_cmd`, `parse_bench_params`, `GET_bench`, and the
route registration. Sanity-test with `curl` + `ffplay`:

```bash
curl 'http://uranium.local:5002/bench?source=testsrc2&w=320&h=240&fps=30&dur=5&rc=q&qv=4' | ffplay -
```

### Step 2 — Client argv parsing

Add `--bench-url` and `--bench-duration` recognition. Log what was
seen; don't branch behaviour yet. Confirm via `./TigerTube
--bench-url=foo --bench-duration=3` that the values are picked up.

### Step 3 — Client bench-mode launch path

Implement `launchBenchMode:duration:` that skips `buildWindow` and
opens a `TTPlayerWindowController` directly at the bench URL.
Hardcode a dummy stats struct for now; verify the stream plays.

### Step 4 — Stats plumbing

Wire up the counters in `TTPlayerWindowController` and
`TTVideoDecoder`. Implement `dumpBenchStats`. Verify the `BENCH:`
line appears on stderr at quit by running on imacg3.

### Step 5 — Build on ibookg37, deploy to the fleet

Build Debug on ibookg37 (fastest G3 in the fleet). Use
`scripts/deploy-to-fleet.sh` to stage through uranium and push to
each fleet target. Smoke-test on one Tiger G3 (imacg3), one
Leopard G4 (pbookg42 or mdd), and the G5 (imacg52) to confirm the
G3-built binary runs on all three CPU generations.

### Step 6 — Sweep scripts

Write the six scripts in `scripts/`: one helper (`run-bench.sh`),
four axis-sweepers (`sweep-geometry.sh`, `sweep-content.sh`,
`sweep-bitrate.sh`, `sweep-noise.sh`) for Phase A, and
`sweep-fleet-calibration.sh` for Phase B.

### Step 7 — Run Phase A (imacg3)

All four axis sweeps on imacg3, populating `results/sweep-*.log`.
Analyze. Identify which hypotheses (H1/H2/H3) the data supports.

### Step 8 — Run Phase B (full fleet)

`sweep-fleet-calibration.sh` across all nine machines. Starting
with the extremes (pmacg3, imacg52) as noted in the methodology
section. Analyze H4.

### Step 9 — Run Phase C if needed

Full sweep on any Phase B outlier.

### Step 10 — Write up

Postmortem (`postmortem.md`) summarising findings, tables of
bench numbers per machine, verdict on each hypothesis, and
recommendation for the real pixel-budget auto-calibrate feature.

## Sweep scripts (in `scripts/`)

Each script is a thin bash wrapper that:

1. Builds a list of bench URLs parameterised over one axis.
2. SSHes to the target (default imacg3, parameterizable via
   `BENCH_HOST`) and invokes `TigerTube --bench-url=...
   --bench-duration=10`.
3. Greps the stderr for `BENCH:` and appends to a per-script log
   under `results/`.

Seven scripts in total — a helper, a deploy script, four Phase A
axis-sweepers, and a Phase B fleet-probe:

- **`run-bench.sh`** — helper. Takes one URL, runs one bench, prints
  the single `BENCH:` line. All sweep scripts shell out to this.
  Honours `BENCH_HOST` env var (defaults to `imacg3`).
- **`deploy-to-fleet.sh`** — builds Debug on `ibookg37` (or
  `BUILD_HOST`), stages through uranium, rsyncs the built `.app` to
  every fleet machine via `tiger-rsync.sh`.
- **`sweep-geometry.sh`** (Phase A) — vary W×H×fps over a grid;
  fixes source (`testsrc2`), rc (`q`), qv (`4`), noise off. Finds
  the raw pixel-throughput ceiling for a "baseline easy" source.
- **`sweep-content.sh`** (Phase A) — fix geometry (e.g.,
  480×360@30), sweep source across `testsrc2 / mandelbrot / life /
  cellauto / gradients / smptebars` plus `color` with varying
  noise amplitudes. Shows how much content complexity alone moves
  sustained Mpx/s.
- **`sweep-bitrate.sh`** (Phase A) — fix source (`testsrc2`) and
  geometry, sweep `rc=cbr` with `bv` values (`500k`, `1M`, `2M`,
  `4M`, `8M`, `16M`). Isolates the per-coefficient / VLC-parsing
  cost independent of pixel count.
- **`sweep-noise.sh`** (Phase A) — fix source (`testsrc2`) and
  geometry, sweep `noise` amplitude (`0`, `1`, `2`, `3`, `5`, `10`,
  `20`). Validates the bits-per-pixel / decode-cost relationship
  directly via encoder-driven (not forced-CBR) bitrate variation.
- **`sweep-fleet-calibration.sh`** (Phase B) — shallow probe (8
  bench runs per machine: 4 geometries × 2 sources, all at
  fps=30/qv=4/dur=10s). Runs across all 9 fleet machines. Tests
  H4 (machine-variable orthogonality and per-MHz scaling).

All seven live in `scripts/`. Each script's first comment line
states the research question it addresses, so a reader can pick one
by intent.

## Validation

Manual, on uranium (proxy) and the fleet (clients).

1. **Normal path (no `--bench-url`)** — launch TigerTube the usual
   way on imacg3; behaviour is byte-identical to today.
2. **`curl` test of `/bench`** — `curl '.../bench?source=testsrc2&w=320&h=240&fps=30&dur=5&rc=q&qv=4'
   | ffplay -` on uranium shows a playable stream.
3. **Bench-mode launch on imacg3** — one-off invocation plays the
   stream and prints a plausible `BENCH:` line at quit.
4. **Cross-generation compatibility** — the G3-built binary
   from ibookg37 runs unchanged on at least one G4 (emac or mdd)
   and the G5 (imacg52). Confirms CLAUDE.md's runtime-AltiVec
   assumption.
5. **`sweep-geometry.sh`** on imacg3 — completes the grid without
   errors. `BENCH:` lines parse. Numbers monotonically trend as
   expected (more pixels → fewer fps once over ceiling).
6. **`sweep-content.sh`** on imacg3 — different sources at
   identical geometry produce meaningfully different
   `mpxs_sustained`. If they don't, content complexity isn't a
   real factor and plain `testsrc2` is sufficient for the real
   feature.
7. **`sweep-bitrate.sh`** on imacg3 — forced CBR at high bitrate
   should push `mpxs_sustained` down vs low bitrate at same
   geometry. Confirms the bits-per-pixel hypothesis
   quantitatively.
8. **`sweep-fleet-calibration.sh`** — completes cleanly on all
   nine machines. Data for H4 analysis.
9. **Release build smoke test** — a Release build with no
   `--bench-url` works normally, confirming the bench path is
   correctly dormant.

## What's explicitly NOT in this

- **The real pixel-budget feature** (tier values, popup UI, proxy
  `mpxs=` param). That lives in the existing
  [pixel-budget](../pixel-budget/plan.md) plan.
- **Auto-calibration at launch.** Same — separate plan, informed by
  this harness's output.
- **A results-aggregation dashboard.** Stderr lines + hand-curated
  tables in the postmortem is the expected output format.
- **Budget/quota enforcement on the `/bench` endpoint.** It's a
  research tool on a LAN; no rate limiting or auth.
- **Audio path benchmarking.** Audio decode cost on the G3 is
  trivial and not a bottleneck; including it only adds variance.
- **Saving bench URLs or bench mode in `NSUserDefaults`.** Launch-
  flag-only; no persistence.
- **Parity between Debug and Release binaries for bench numbers.**
  We will benchmark Debug (per CLAUDE.md: "Always build Debug for
  iteration"). If the real feature uses benchmark-at-launch it must
  re-calibrate under Release, because the measured numbers here
  aren't transferable.

## Open questions / assumptions to confirm

### Proxy

- **P1. URL path is `/bench`.** Alternative: `/bench/testsrc2` with
  the source name in the path. Query-string-only is simpler and
  matches the existing pattern where `/v/yt/<id>` puts the resource
  identity in the path and tuning knobs in the query. Since there's
  no single "resource" here, query-only feels right.
- **P2. Allowed sources are a fixed list.** Alternative: pass the
  source expression through verbatim. Fixed list prevents a curious
  user from shelling out arbitrary lavfi expressions (not a security
  concern on a LAN but a clarity one).
- **P3. Default `rc=q`, `qv=4`.** Matches what we've been piping on
  uranium. `-q:v 4` gives stable per-frame output on synthetic
  sources; reasonable default.
- **P4. `-force_key_frames 0` copied from `build_video_cmd`.**
  Applicable? That option fires a keyframe at the very start of the
  stream; probably harmless for bench, and makes the first frame
  decodable without waiting for the next GOP.

### Client

- **C1. Bench-mode skips Bonjour discovery.** User must pass a full
  URL including host:port. Less magical, more reproducible.
- **C2. `BENCH:` stderr line format.** Space-separated `key=value`
  columns. JSON later if a real aggregator emerges.
- **C3. How to compute `mpxs_sustained`.** `W × H × fps_displayed`
  (or `fps_decoded`?). Displayed is the honest end-to-end metric but
  is capped at the 30 Hz display timer; for probing whether decode
  can exceed 30 fps we need the decoded metric too. Dump both.
- **C4. `--bench-duration` default.** **[ASSUMPTION]** 10 seconds
  when the flag is present but no value given. Unbounded when the
  flag is absent.
- **C5. Where the stats counters live.** **[ASSUMPTION]** In
  `TTPlayerWindowController`, since it already orchestrates the
  pipeline actors. Decoder and display paths increment shared
  counters directly, no intermediary.

### Experimental design

- **E1. Phase structure (A deep → B shallow fleet → C targeted
  follow-up).** Described in the "Multi-machine methodology" section
  above. Alternative: run full sweeps on every machine (9× the
  runtime of Phase A). Overkill for the questions we're asking, and
  Phase C exists to catch any surprises.
- **E2. Duration of each bench run.** 10s default feels right —
  enough for the decode pipeline to hit steady state, short enough
  that a 30-point grid finishes in under 10 minutes of wall time.
- **E3. Whether to disable the audio player during bench mode.** No
  audio in the stream means the CoreAudio unit just pulls silence
  from an empty ring, which is the existing no-audio behavior. Doing
  nothing is fine.
- **E4. Results storage.** **[ASSUMPTION]** Append raw `BENCH:` lines
  to `results/<script-name>.log` next to the scripts. For Phase B,
  one log per machine (`results/sweep-fleet-calibration-<host>.log`).
  Postmortem summarises / tabulates from those logs.
- **E5. Build machine is ibookg37 (900 MHz G3).** Alternative:
  imacg52 (fastest overall, 2.0 GHz G5). Rationale for G3: the
  resulting binary running on G4/G5 is itself a compatibility test
  for the single-ppc-binary assumption, which matters for the
  shipped product. imacg52 builds faster but doesn't exercise that
  compatibility claim.
- **E6. `tiger-rsync.sh` used uniformly for all fleet targets.**
  CLAUDE.md specifies it for Tiger transfers. Leopard transfers
  likely work with plain `rsync -av` too, but using the same
  wrapper everywhere is simpler. Confirmed by user.

## Appendix A: investigation journal — finding a good test source

Before writing this plan, an afternoon of interactive exploration on
uranium (ffmpeg + ffplay in a bash shell) narrowed the space of
candidate benchmark inputs. This appendix captures what was tried,
what was learned, and the command-line recipes worth reaching for
again — so that a reader of this plan can reproduce any step rather
than just taking the final choice on faith.

The final landing spot was:

```
testsrc2 at 640×360 @ 30 fps, mpeg1video codec, -q:v 4, optionally
with a light noise overlay (alls=3) to match real-content bitrate.
```

The rest of this appendix explains how we got there.

### A.1 Visual survey of lavfi synthetic sources

ffmpeg's `lavfi` input device generates video without any source
file. Each of the following was inspected live via `ffplay` to build
an intuition for what content complexity we could dial in without
shipping media:

```bash
# Classic animated test pattern (color bars + moving timestamp + counter)
ffplay -f lavfi -i testsrc=size=480x360:rate=30
```

```bash
# Improved testsrc with more visual interest and motion
ffplay -f lavfi -i testsrc2=size=480x360:rate=30
```

```bash
# SMPTE color bars (static)
ffplay -f lavfi -i smptebars=size=480x360:rate=30
```

```bash
# HD SMPTE bars (static)
ffplay -f lavfi -i smptehdbars=size=480x360:rate=30
```

```bash
# PAL color bars, 75% and 100% variants (static)
ffplay -f lavfi -i pal75bars=size=480x360:rate=30
ffplay -f lavfi -i pal100bars=size=480x360:rate=30
```

```bash
# RGB / YUV test patterns (static, mostly for color debugging)
ffplay -f lavfi -i rgbtestsrc=size=480x360:rate=30
ffplay -f lavfi -i yuvtestsrc=size=480x360:rate=30
```

```bash
# Solid color (takes c= for any named color or #rrggbb)
ffplay -f lavfi -i color=c=gray:size=480x360:rate=30
```

```bash
# Animated Mandelbrot zoom (detail grows dramatically over time)
ffplay -f lavfi -i mandelbrot=size=480x360:rate=30
```

```bash
# Conway's Game of Life (chaotic B&W motion)
ffplay -f lavfi -i life=size=480x360:rate=30:mold=10:life_color=white:death_color=black
```

```bash
# Scrolling cellular automaton bands
ffplay -f lavfi -i cellauto=size=480x360:rate=30
```

```bash
# Animated color gradients (smooth motion, very compressible)
ffplay -f lavfi -i gradients=size=480x360:rate=30
```

```bash
# Sierpinski fractal
ffplay -f lavfi -i sierpinski=size=480x360:rate=30
```

```bash
# The degenerate cases: every RGB / YUV value, 4096×4096 — not
# useful as bench input but worth knowing about.
ffplay -f lavfi -i allrgb
ffplay -f lavfi -i allyuv
```

Takeaways from the visual survey:

- **Static sources** (smptebars, pal bars, rgbtestsrc, yuvtestsrc,
  color) compress trivially — most frames are P-frames with zero
  non-trivial macroblocks. Useful as a lower bound on decode cost
  but unrealistic for actual video.
- **Predictable-motion sources** (testsrc, testsrc2, gradients)
  sit at a reasonable middle ground.
- **Chaotic sources** (life, cellauto, mandelbrot with ongoing
  zoom) exercise more of the decoder.
- **`allrgb` / `allyuv`** go 4096×4096 and will overwhelm any small
  display buffer — included here only for completeness.

### A.2 Piping synthetic sources through an MPEG encode

To see how each source *actually* behaves when fed through the
encode path the proxy uses, we piped ffmpeg's lavfi output into
ffmpeg again (re-encoding) and then into ffplay:

```bash
# Template: encode synthetic source to MPEG-1 at target bitrate,
# play the result. Swap the input source or encoder flags to vary.
ffmpeg -f lavfi -i mandelbrot=size=480x360:rate=30 -t 5 \
       -c:v mpeg1video -b:v 2M -f mpegts - | ffplay -
```

Key flag notes:

- `-t 5` caps the synthesized duration to 5 seconds (or whatever).
- `-c:v mpeg1video` matches what the production proxy emits (see
  `build_video_cmd` in `proxy/tigertube-proxy.py`). **Earlier
  attempts used `-c:v mpeg2video`** — works fine for ffplay, but
  diverges from the production decode path.
- `-f mpegts` wraps the raw ES in an MPEG-TS container so
  `ffplay -` can demux it. The proxy's `/bench` endpoint will
  serve raw `-f mpeg1video` (no container) to match production;
  mpegts was just for interactive piping into ffplay.

### A.3 Mandelbrot's bitrate climb and the 180-second cache limit

Running the mandelbrot source for 30-second and 300-second
durations revealed that its emitted bitrate is wildly time-variant:

```bash
# Start of zoom — low detail, bitrate around 2–5 Mbps even at -q:v 4
ffmpeg -f lavfi -i mandelbrot=size=480x360:rate=30 -t 30 \
       -c:v mpeg1video -q:v 4 -f mpegts - | ffplay -
```

```bash
# Longer run — as the zoom goes deeper, detail explodes and the
# encoder emits 15–20 Mbps by minute 3.
ffmpeg -f lavfi -i mandelbrot=size=480x360:rate=30 -t 180 \
       -c:v mpeg1video -q:v 4 -f mpegts - | ffplay -
```

**Hard limit discovered at ~180 seconds:** beyond roughly three
minutes of real-time zoom, the mandelbrot filter fails with an
error about running out of cache (something like "mandelbrot: not
enough cache"). This is a known ffmpeg filter limitation. In
practice, **cap mandelbrot benchmarks at `-t 180` or shorter** — the
harness doesn't need anywhere near that length anyway.

#### Controlling mandelbrot to keep complexity stationary

The bitrate climb is a problem for bench use — a benchmark needs
stationary input complexity or the measurement is a weighted
average of wherever-in-the-zoom you happened to be. Mandelbrot's
filter parameters include `start_scale` and `end_scale`, letting
you pin the zoom to a narrow range where complexity is already
saturated:

```bash
# Start deep in the zoom, barely move — stationary high-detail
# content from frame 0.
ffmpeg -f lavfi -i "mandelbrot=size=480x360:rate=30:start_scale=0.0001:end_scale=0.00005" \
       -t 180 -c:v mpeg1video -q:v 4 -f mpegts - | ffplay -
```

Other mandelbrot parameters worth knowing about: `start_x`,
`start_y` (center of the initial view), `maxiter` (detail ceiling),
`outer` (coloring algorithm). Full list in `ffmpeg -h
filter=mandelbrot`.

### A.4 Rate control: the `-q:v` versus `-b:v` trap

The bash history shows multiple wrong attempts at "constant quality"
mode before landing on the correct flag:

- `-v:q 2` — not a flag
- `-q:1 10M` — confuses per-stream specifier with value
- `-q:10` — likewise
- `-qzzz:10 10M` — typo

The correct syntax is **`-q:v N`** where N is the quantization
scale (1 = best quality / highest bitrate, 31 = worst). For
mpeg1video / mpeg2video, values around 2–5 produce visually
indistinguishable output at modest bitrates.

```bash
# Correct: constant-quality VBR. Emitted bitrate varies with
# content complexity; visual quality stays fixed.
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30" -t 180 \
       -c:v mpeg1video -q:v 4 -f mpegts - | ffplay -
```

```bash
# The alternative: constant-bitrate. Useful for forcing the encoder
# to produce a specific bits-per-pixel target regardless of content.
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30" -t 180 \
       -c:v mpeg1video -b:v 2M -f mpegts - | ffplay -
```

For the benchmark, `-q:v 4` is the default because it gives
stationary, content-aware bitrate — the encoder settles into a
per-content emitted bitrate and stays there, which is exactly what
we want for a stable decode workload.

### A.5 Real-content baseline: the Rick Astley check

To calibrate synthetic numbers against reality, we compared the
encoded bitrate of a real low-resolution YouTube video (Rick
Astley's "Never Gonna Give You Up" at YouTube format 18, H.264
360p) before and after re-encoding to MPEG-1.

```bash
# Probe the real file's properties.
ffprobe rickroll-f18.mp4

# Produced:
#   Duration: 00:03:33.04, bitrate: 444 kb/s
#   Stream #0:0: h264, yuv420p, 640x360, 312 kb/s, 25 fps
#   Stream #0:1: aac, 127 kb/s
```

```bash
# Re-encode the real video to MPEG-1 at -q:v 4, same codec settings
# we'll use for synthetic bench sources. Observe emitted bitrate.
ffmpeg -i rickroll-f18.mp4 -t 180 -c:v mpeg1video -q:v 4 \
       -f mpegts - | ffplay -

# Emitted bitrate settled around 1.9 Mbps.
```

Findings:

| Stream | Bitrate | Notes |
|---|---|---|
| rickroll H.264 (original) | 312 kbps video, 444 kbps total | 640×360, 25 fps |
| rickroll re-encoded MPEG-1 -q:v 4 | ~1.9 Mbps | 640×360, 25 fps, video only |
| testsrc2 MPEG-1 -q:v 4 (480×360 @ 30) | ~2.3 Mbps | first geometry tested |
| testsrc2 MPEG-1 -q:v 4 (640×360 @ 30) | ~2.5 Mbps | same as rickroll geometry |
| testsrc2 + noise=10, MPEG-1 -q:v 4 | ~10 Mbps | 5.5× rickroll — too high |
| testsrc2 + noise=3, MPEG-1 -q:v 4 | ~3–5 Mbps (TBD) | candidate for bench |

Takeaway: **plain testsrc2 at `-q:v 4` already runs slightly hotter
than real content** at matched geometry (2.5 vs 1.9 Mbps, a ~30%
margin). That's the right direction — a *conservative* benchmark
that slightly over-estimates decode cost produces a slightly
under-reported Mpx/s ceiling, which is the safe side for a
"don't exceed this budget" UI.

### A.6 Measuring realtime bitrate: the `-f null` N/A trap

To compare synthetic and real streams, we wanted a realtime
bitrate readout. Our first attempt didn't work:

```bash
# Pipe to null muxer at realtime speed. Expected realtime bitrate
# ticks; got Lsize=N/A bitrate=N/A on newer ffmpeg builds.
ffmpeg -re -i rickroll-f18.mp4 -c copy -f null -
```

Newer ffmpeg versions' null muxer doesn't count bytes, producing
`N/A` in the progress line. Workaround: pipe through a real
streamable muxer to `/dev/null`:

```bash
# Real byte counter runs; realtime bitrate ticks once per second.
ffmpeg -re -i rickroll-f18.mp4 -c copy -f mpegts /dev/null
```

For a non-realtime single-number average, ffprobe is cleaner:

```bash
# Per-stream bitrate (present if the container has it in metadata).
ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=nk=1:nw=1 rickroll-f18.mp4
```

```bash
# Fallback when bit_rate isn't populated: compute from size/duration.
ffprobe -v error -select_streams v:0 \
        -show_entries stream=duration,nb_frames \
        -show_entries format=size,duration \
        -of default=nk=1:nw=1 rickroll-f18.mp4
# Outputs four values: stream_duration, nb_frames, format_duration,
# total_bytes. Bitrate = bytes*8/duration.
```

### A.7 Noise amplitude exploration

The `noise` filter overlays pseudo-random noise on any source,
destroying both temporal and spatial redundancy and forcing the
encoder to allocate more bits. Apply it as a filter chain after the
source:

```bash
# General form: source,noise=alls=<N>:allf=t
# alls = amplitude strength per pixel (0 = no noise, 100 = strong)
# allf = flags: t means "apply to all frames temporally" (as
#        opposed to a single static noise pattern)
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30,noise=alls=10:allf=t" \
       -t 180 -c:v mpeg1video -q:v 4 -f mpegts - | ffplay -
```

At fixed `-q:v 4`, emitted bitrate varies approximately as:

| alls | Emitted bitrate | Relative to rickroll real content |
|---|---|---|
| 0 (filter absent) | 2.5 Mbps | 1.3× |
| 1 | ~2.7 Mbps (est.) | ~1.4× |
| 2 | ~3 Mbps (est.) | ~1.6× |
| 3 | ~3–5 Mbps (est., TBD on fleet) | 1.6–2.5× |
| 5 | ~5–6 Mbps (est.) | 2.6–3× |
| 10 | ~10 Mbps | 5.5× |
| 20 | very high | way too much |
| 100 | off the chart | unrealistic |

Exact values depend on the source and will be nailed down in Phase
A. The intuition confirmed: noise at the `alls=10+` level vastly
overshoots real content. noise=3 is the mild-overshoot sweet spot
that gives a conservative margin without making the decoder do 4×
the work real content imposes.

#### Forcing CBR with noise

For `sweep-bitrate.sh` the encoder is told to hit a target bitrate
*regardless* of content. Useful for decoupling "bits per pixel"
from "noise amount":

```bash
# Force 10 Mbps constant bitrate with heavy noise. Encoder
# allocates its budget across the noisy input, producing a
# uniformly high bits-per-pixel stream.
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30,noise=alls=100:allf=t" \
       -t 180 -c:v mpeg1video -b:v 10M -f mpegts - | ffplay -
```

### A.8 Quality sweep at fixed noise

To see how much `-q:v` alone moves emitted bitrate (and by proxy
per-coefficient decode work), we swept q from 1 through 5 at fixed
noise=10:

```bash
# q=1: highest quality, highest bitrate
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30,noise=alls=10:allf=t" \
       -t 180 -c:v mpeg1video -q:v 1 -f mpegts - | ffplay -

# q=5: lower quality, lower bitrate
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30,noise=alls=10:allf=t" \
       -t 180 -c:v mpeg1video -q:v 5 -f mpegts - | ffplay -
```

Quality-step differences at noise=10 are substantial (several
Mbps between q:v 1 and q:v 5). At noise=0 the sensitivity is
smaller because the encoder has less non-compressible content to
budget for.

For the bench default, `-q:v 4` sits in a stable region — small
quality changes don't drastically shift emitted bitrate.

### A.9 Landing spot — summary

Based on A.1 through A.8:

- **Source:** `testsrc2` — stationary complexity, no time-drift
  issues like mandelbrot's zoom.
- **Geometry for the "typical" bench point:** 640×360 @ 30 fps.
  Matches a common real-content geometry (YouTube f18).
- **Codec:** `mpeg1video` — matches the production proxy.
- **Rate control:** `-q:v 4` as default; `-b:v <bitrate>` for the
  bitrate sweep.
- **Noise:** default off (plain `testsrc2` already runs 30% hot vs
  rickroll). `noise=3` as the "slightly more realistic high-
  entropy" variant if we need it. `noise=10+` only for forcing
  worst-case behavior and should not be treated as representative.
- **Duration:** 10 seconds per bench run. Long enough for decode
  steady-state, short enough for 30-point grids. Mandelbrot runs
  capped at 60 seconds to stay well under the 180s cache limit.

These choices are encoded as defaults in the Phase A sweep scripts.
Override via env vars or script edits if a specific experiment
requires different values.
