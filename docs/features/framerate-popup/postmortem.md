# framerate-popup — postmortem

Shipped 2026-04-18 against
[`plan.md`](plan.md) in commit
[`5aad9f5`](https://github.com/cellularmitosis/TigerTube/commit/5aad9f5).

## What shipped vs. the plan

Implementation tracked the plan closely. Two deviations, both in the
layout pass; neither changed the feature's shape.

### Popup width 75 → 85, minWidth 810 → 820

**Plan:** `fpsPopW = 75.0f`, `setMinSize:NSMakeSize(810, 400)`.

**Shipped:** `fpsPopW = 85.0f`, `setMinSize:NSMakeSize(820, 400)`.

The first build on imacg3 showed the popup rendering `So...` — Tiger's
13 pt Lucida Grande drew `Source` wider than the planned 52 px text
estimate, and the 75 px popup clipped. The plan's *Open questions*
section flagged this specific scenario ("if the layout screenshot
shows the arrow cramped against the text, bump to 80") so the fix
took one edit + rebuild. Went to 85 rather than 80 for a bit more
breathing room; the minWidth bump followed directly from the popup
widening by 10 px.

### ffmpeg `fps=24.0` cosmetic

**Plan:** `fps = float(fps_arg) if fps_arg is not None else None` so
the proxy accepts fractional rates from out-of-band callers.

**Shipped:** same code, but this also means the ffmpeg `-vf` chain
now contains `...,fps=24.0` instead of the old `...,fps=24`.

ffmpeg accepts both forms identically. Logs are cosmetically noisier
but no functional effect. Noted here so the next person reading proxy
logs isn't confused by the `.0`.

## What went well

- **Plan iteration happened in the plan doc before any code.** Two
  rounds of revision (default `24` → `Source`; popup items trimmed
  from 7 → 4 after reframing as downconvert-only) each sharpened the
  rationale. By the time implementation started, every design
  decision had a written defense. Zero churn in the commit history
  tracking the design evolution.
- **Proxy change validated independently.** Three curls against
  `/v/file` on uranium (no-fps / fps=24 / fps=30) confirmed the
  proxy behavior before either Mac ever ran the new client. This
  caught the `fps=24.0` detail pre-deploy instead of in confusing
  client-side stderr.
- **AppleScript-keystroke → screenshot → Read** was as productive
  here as on the file-source feature. The truncated `So...` popup
  showed up in the very first layout screenshot; diagnosing and
  fixing it took about three minutes wall-clock.

## Surprises

- **Xcode dep tracking misses rsync'd `.m` files, not just `.h`.**
  CLAUDE.md called out the trap for headers
  ("`tiger-rsync.sh` preserves source mtimes; if Xcode's dependency
  tracking doesn't notice a header change…"), but the same thing
  bit a changed `.m` during the 75 → 85 popup fix — Xcode reported
  `** BUILD SUCCEEDED **` without recompiling anything, and the
  relaunched binary was the old one. `ssh imacg3 "touch
  tmp/TigerTube/src/AppController.m"` + rebuild fixed it. Expanding
  the CLAUDE.md note to cover `.m` as well would save the next
  person a round.
- **Tiger's system font metrics don't match my mental model.** The
  52 px estimate for "Source" at 13 pt was visibly off; real render
  was closer to 56-58 px. Label-width estimates for Resolution /
  Quality / VSync were closer because I was tightening *existing*
  measured widths — but any *new* label would benefit from an
  empirical measurement pass, not a guess.

## What to do differently next time

- **Measure popup text widths empirically at dev time, not in the
  plan.** A one-shot `sizeToFit` on a test NSTextField set to the
  widest popup item would give the exact pixel width. The cost is
  ~5 lines of throwaway code; the benefit is skipping the 85 px
  rebuild loop.
- **Append `.m` to the CLAUDE.md rsync-mtime note.** The trap
  surface is wider than just headers.

## Follow-ups considered, not shipped

- **Motion-interpolated downconversion.** Discussed after shipping:
  `fps=N` drops frames in an irregular pattern, which is what makes
  30 → 24 look juddery (the two clean 2:1 cases, 60 → 30 and 50 →
  25, don't have this issue). ffmpeg offers `tblend` (cheap blend),
  `minterpolate=mi_mode=blend` (moderate), and
  `minterpolate=mi_mode=mci` (expensive motion-compensated) as
  smoother alternatives, all running server-side on uranium.
  Decision: **ship as-is**. The popup's job is G3 headroom, not
  cinematic quality, and the two clean cases cover most of the
  "actually useful for TigerTube" ground. If 30 → 24 judder turns
  out to be a real user complaint, a later feature could add an
  `interp=` query param without disturbing anything shipped here.

## Open questions resolved

The plan flagged two:

1. *Does 75 px comfortably render `Source` on Tiger's system font?*
   **No.** Answered above; needed 85.
2. *Does libmpeg2 on the G3 handle a 50 or 60 fps MPEG-1 ES stream
   correctly when `Source` is chosen on high-rate content?*
   **Not tested yet.** The file-source and YouTube smoke tests ran
   on a 24 fps clip. A 60 fps YouTube upload with `Source` selected
   is the natural next QA case, but the G3's Rage 128 Pro + 30 Hz
   display timer already caps effective display rate at 30, so the
   worst realistic outcome is "decoder works hard, display shows
   every other frame" — which is exactly why the `30` option
   exists as the user's escape hatch.
