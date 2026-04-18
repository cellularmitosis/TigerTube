# Framerate popup (`Source` + 23.976 / 24 / 25 / 30 / 50 / 60)

## Problem

The client currently hard-codes `TT_VIDEO_FPS = 24` and always passes
`fps=24` to the proxy, which inserts `fps=24` into ffmpeg's `-vf`
chain — forcing CFR conversion regardless of the source's native
rate. For a 30 or 60 fps source, frames get dropped; for a 12 fps
animation, frames get duplicated; and on the G3, the decoder is
tuned assuming 24 fps output so non-24 content has less headroom
than it needs to have.

We want a user-facing knob that:

1. Lets the user pick a specific output rate when they have a
   reason to (LAN bandwidth limit, G3 headroom target, matching a
   display refresh).
2. Has a `Source` option that skips the CFR filter and lets ffmpeg
   pass frames through at the source's native rate, quantized to a
   legal MPEG-1 rate by the encoder.

## Solution overview

1. New `NSPopUpButton` labeled `Framerate:` in the controls row,
   positioned **after Quality, before VSync**.
2. Popup items (in order): `Source`, `24`, `25`, `30`. Default
   selection: `Source`.
3. At play time, `playVideoAtIndex:` reads the popup title:
   - `Source` → **omit** the `fps=` query param from the video URL.
   - Any numeric value → send `fps=<value>` as today (with `23.976`
     serialized exactly that way, the server accepts a float).
4. Proxy: `parse_video_params` treats missing `fps` as `None`.
   `build_video_cmd` appends `fps={fps}` to the filter chain only
   when `fps is not None`. The `setpts=PTS-STARTPTS` filter stays
   in both modes.
5. Tighten the label widths and inter-group gaps by a few pixels so
   the new control fits without the row growing.

## Design decisions (and rationale)

### Why `Source` rather than e.g. `Native`, `Auto`, `Passthrough`

`Source` is the word the existing architecture already uses for the
input side of the transcode (yt-dlp / file → ffmpeg input is "the
source"). Matching that vocabulary keeps the popup self-explanatory
to anyone who's read the proxy code. `Auto` is vaguer (auto *what*
— auto-choose 24 based on source rate? auto-match monitor?) and
`Passthrough` implies no re-encoding at all, which is false — we
still transcode to MPEG-1, we just don't impose a CFR rate.

### Why the client signals `Source` by omitting `fps=`, not by sending `fps=0`

- Omission is a cleaner interface: the absence of `fps=` in the
  query string directly matches the absence of `fps=N` in ffmpeg's
  `-vf` chain. One thing is missing on each side; symmetric.
- `fps=0` would need a second special-cased sentinel (alongside
  `None`) in the proxy, and the curl-based debug case ("what URL do
  I hit to get source-rate?") becomes "drop a param" instead of
  "set a param to 0." Easier to remember, easier to explain.

### Why only `24`, `25`, `30` as numeric options (no 23.976, no 50, no 60)

The popup's real job is **downconversion** — the case where the
source is too high for the G3 to keep up and the user wants to
cap playback at a rate the decoder can comfortably hit. `Source`
already covers "preserve the native rate" for everything
including 23.976 passthrough.

From a downconversion target:

- `24` — generic "film-ish" cap. Drops frames from a 30 fps web
  source; preserves 24 fps film-rate content when forced.
- `25` — the exact half of 50 fps PAL broadcast content, so
  50 → 25 decimation is clean (every other frame kept). No
  pulldown artifacts.
- `30` — the exact half of 60 fps desktop-capture / gameplay
  content. Same clean-decimation story: 60 → 30 keeps every
  other frame.

Options rejected:

- `23.976` as a forced rate: nobody needs this level of
  precision *when downconverting*. `24` is close enough for the
  headroom use case, and `Source` already emits the exact
  `24000/1001` rate when the input has it.
- `50`, `60`: we almost never want to downconvert *to* these
  rates — if a user has a 50 or 60 fps source they either want
  `Source` (preserve it) or a lower cap. Picking `50` as a
  target from a 60 source would do an ugly 6-of-5 frame
  decimation; picking `60` as a target from anything lower just
  duplicates frames and wastes bandwidth. Neither is a useful
  downconversion path.
- `29.97` / `59.94`: same reasoning as 23.976 — the drop-frame
  precision doesn't matter when you're trading frames for
  decoder headroom. `30` is close enough; `Source` preserves
  the original ratio exactly.

Adding any of these later is one line in the popup init.

### Why the default is `Source`, not `24`

The honest default is the one that doesn't impose a rate on
content whose native rate we know. A 30 fps upload played back
at a forced 24 fps drops ~6 frames per second before it ever
reaches the decoder — that's information the client was throwing
away by default. `Source` preserves it.

This does change G3 playback characteristics on non-24 fps
content: a 30 fps source gives the decoder ~9× realtime
headroom instead of ~11×, a 60 fps source ~4.5×. Still well
above 1× at 320×240/q=2, so it plays. The G3 user who finds a
specific high-motion video unwatchable at 60 fps can dial it
down to `24` or `30` per-play; they no longer have to — which
is the change. Exposing the knob and defaulting it open is
better than hardcoding a conservative choice and leaving the
native-rate case unreachable without recompiling.

### Why the `setpts=PTS-STARTPTS` filter stays on in `Source` mode

The comment in `build_video_cmd` calls out that `setpts` is
load-bearing *because* of the `fps=N` CFR filter that follows it:
for DASH-fragmented YouTube sources, the first decoded frame has
PTS ~5s (fragment offset), and `fps=` would pad 5s of duplicate
frames at the start if we didn't rebase PTS to zero first.

When we omit `fps=`, the duplication problem goes away — but the
MPEG-1 encoder still receives frames with PTS in the 5-10s range
if we don't rebase. MPEG-1 ES has no per-frame PTS, so the output
stream itself is fine, but keeping `setpts` on is free insurance
against any other filter interaction that cares about PTS origin.
Leave it.

### Why a popup with named entries rather than a free-form text field

A `Framerate:` NSTextField would let the user type `29.97` or
`48`, which ffmpeg *would* accept — but then every typo lands in
ffmpeg's command line, where a bad value either crashes the
encoder or silently produces a file with non-standard rate that
the libmpeg2 decoder may refuse. A fixed popup is a safety rail
at the UI layer.

### Label and popup width tightening

The existing label widths have ~6–10 px of slack between the
text and the adjacent popup/checkbox. The new `Framerate:` label
+ popup needs roughly 70 + 80 = 150 px of room, which doesn't
quite fit in the existing 700 px minWidth without squeezing
something. Approach:

1. Shrink the fixed-width labels to match their actual text
   widths more closely (Resolution 78 → 72, Quality 52 → 48,
   VSync 48 → 44). Net reclaim: ~14 px.
2. Reduce the inter-group gap from 20 → 16 px (three gaps between
   four controls groups once Framerate is added). Net reclaim:
   ~12 px.
3. Bump the window's `setMinSize:` from (700, 400) to (810, 400).
   At widths below that, the hidden-by-default `dropsLabel`
   would clip — but since it's only visible when drops > 0 and
   the content columns fit fine, the minWidth bump is the
   cleanest fix.

Exact new layout (pixel by pixel), from margin=10:

```
  10  margin
+ 72  "Resolution:" label        (was 78)
+150  resPop
+ 16  gap                        (was 20)
+ 48  "Quality:" label           (was 52)
+ 60  qPop
+ 16  gap                        (was 20)
+ 72  "Framerate:" label         (new)
+ 75  fpsPop                     (new -- fits "Source" + arrow)
+ 16  gap                        (was 20)
+ 44  "VSync:" label             (was 48)
+ 20  vsBox
+ 16  gap
+180  dropsLabel                 (hidden unless drops > 0)
+ 10  margin
----
 805  total
```

810 minWidth gives us 5 px of breathing room at the minimum; the
default window size (screen's visibleFrame) is well over that.
Dropping to a 4-item popup means the widest string is `Source`
(~52 px at 13pt system) and the popup can be 75 px instead of
the 85 px the `23.976` option would have needed.

### Why not make the labels self-sizing via `sizeToFit`

`ttCenterLabelInRow` already calls `sizeToFit` for the vertical
centering pass, and we could pull the natural text width from
that. But then the total row width depends on the current system
font's rendered metrics, which is both harder to reason about
(the layout becomes implicit) and annoying to inspect via
screenshot-diff ("did this label get 2 px wider because the font
hinting changed?"). Fixed widths tuned once is easier to reason
about. The six-pixel reduction is a one-time nudge, not a
recurring maintenance burden.

## Files touched

- `src/AppController.h` — one new ivar (`NSPopUpButton* fpsPopup`),
  same weak-retention pattern as the existing popups.
- `src/AppController.m`:
  - `buildWindow`: add the popup between Quality and VSync,
    tighten label widths and gaps, bump minWidth.
  - `playVideoAtIndex:`: read the popup title, omit `fps=` from
    the URL when it's `Source`, else include it.
  - `TT_VIDEO_FPS` constant stays as a fallback / sentinel for the
    "couldn't parse the popup" path (shouldn't trigger since the
    popup items are hardcoded, but belt-and-braces).
- `proxy/tigertube-proxy.py`:
  - `parse_video_params`: treat missing `fps` as `None` rather
    than falling through to `V_DEFAULT_FPS`.
  - `build_video_cmd`: only append `fps={fps}` to `-vf` when
    `fps is not None`.
- `docs/features/framerate-popup/plan.md` — this file.

## Implementation steps

### Step 1 — Proxy: accept missing `fps` as "source rate"

```python
def parse_video_params(query_dict):
    t    = float(query_dict.get("t", "0"))
    w    = int(query_dict.get("w",  V_DEFAULT_W))
    h    = int(query_dict.get("h",  V_DEFAULT_H))
    br   = query_dict.get("br",     V_DEFAULT_BR)
    # Missing fps => source rate (omit the fps= CFR filter downstream).
    # V_DEFAULT_FPS is no longer consulted for the client path, but
    # we keep it around for any out-of-band curl testing that wants
    # a sane 24 fps default via a different entry point.
    fps_arg = query_dict.get("fps")
    fps = float(fps_arg) if fps_arg is not None else None
    g    = int(query_dict.get("g",  V_DEFAULT_G))
    q_arg = query_dict.get("q")
    q = int(q_arg) if q_arg is not None else None
    crop_arg = query_dict.get("crop")
    return t, w, h, br, fps, g, q, crop_arg
```

Note `float(...)`, not `int(...)` — so the proxy also accepts
fractional rates like `23.976` or `29.97` from out-of-band curl
callers, even though the TigerTube popup only ships integers.

In `build_video_cmd`, the relevant lines become:

```python
vf = ""
if crop:
    vf += f"crop={crop},"
vf += (f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
       f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,"
       f"setpts=PTS-STARTPTS")
if fps is not None:
    vf += f",fps={fps}"
```

All other call sites of `build_video_cmd` (video yt + video file)
already pass `fps` through transparently — no signature change
needed beyond the "now may be None" contract.

### Step 2 — Client: add the popup to `buildWindow`

Between Quality and VSync, mirroring the other popup blocks:

```objective-c
float fpsLabelW = 72.0f;
NSTextField* fpsLabel = [[NSTextField alloc] initWithFrame:
    NSMakeRect(x, rowY, fpsLabelW, controlsH)];
[fpsLabel setStringValue:@"Framerate:"];
[fpsLabel setBezeled:NO];
[fpsLabel setDrawsBackground:NO];
[fpsLabel setEditable:NO];
[fpsLabel setSelectable:NO];
[fpsLabel setAutoresizingMask:NSViewMinYMargin];
ttCenterLabelInRow(fpsLabel, rowY, controlsH, fpsLabelW);
[content addSubview:fpsLabel];
[fpsLabel release];
x += fpsLabelW;

float fpsPopW = 75.0f;
NSPopUpButton* fpsPop = [[NSPopUpButton alloc] initWithFrame:
    NSMakeRect(x, rowY, fpsPopW, controlsH)];
[fpsPop addItemsWithTitles:[NSArray arrayWithObjects:
    @"Source", @"24", @"25", @"30", nil]];
[fpsPop selectItemWithTitle:@"Source"];
[fpsPop setAutoresizingMask:NSViewMinYMargin];
[content addSubview:fpsPop];
fpsPopup = fpsPop;   /* weak: retained by superview */
[fpsPop release];
x += fpsPopW + 16.0f;
```

Declare `NSPopUpButton* fpsPopup;` in `AppController.h` right
after `qualityPopup`.

Also in this step: apply the tightening numbers listed under
"Label and popup width tightening" to the existing labels and
gaps, and change `setMinSize:` to `NSMakeSize(820, 400)`.

### Step 3 — Client: branch on the popup in `playVideoAtIndex:`

After the existing res/quality popup parsing:

```objective-c
NSString* fpsTitle = [fpsPopup titleOfSelectedItem];
BOOL useSourceFps  = [fpsTitle isEqualToString:@"Source"];
/* For non-Source, fpsTitle is the rate string ("24", "25", "30")
   and the proxy accepts it as a query-string value verbatim. */
fprintf(stderr, "playVideoAtIndex: fps=%s\n",
        useSourceFps ? "Source" : [fpsTitle UTF8String]);
```

Then in the URL-building branch, for the YouTube case:

```objective-c
if (useSourceFps) {
    vURL = [NSString stringWithFormat:
        @"%@/v/yt/%@?w=%d&h=%d&q=%d&g=%d",
        proxyHost, videoId,
        width, height, qscale,
        TT_VIDEO_GOP];
} else {
    vURL = [NSString stringWithFormat:
        @"%@/v/yt/%@?w=%d&h=%d&q=%d&fps=%@&g=%d",
        proxyHost, videoId,
        width, height, qscale,
        fpsTitle,
        TT_VIDEO_GOP];
}
```

And the same fork for the `kind=file` branch. Audio URL is
unaffected (no fps for audio).

The `%@` format specifier preserves `23.976` as the literal
string the user picked, which avoids float-to-string rounding
surprises.

### Step 4 — Remove `TT_VIDEO_FPS` from the "always sent" path

`TT_VIDEO_FPS` is currently interpolated unconditionally into the
vURL format string. After Step 3 it's no longer consulted on the
happy path (the popup title is the source of truth). Leave the
`static const int TT_VIDEO_FPS = 24;` definition in place as
documentation of the historical default; delete it only if
nothing else references it by the end of the change.

## Validation

Manual, on imacg3 and imacg52, with a YouTube video that has a
known source rate (ideally a 30 fps or 60 fps upload, plus a
24 fps one for the default-case baseline):

1. **Default path (`Source`), 24 fps content.** Default popup =
   `Source`. Play a 24 fps YouTube upload. Stderr should show
   `fps=Source` and the URL in the proxy log should **omit**
   `fps=`. ffmpeg's `-vf` line should end
   `...setpts=PTS-STARTPTS` (no trailing `fps=`). Output should
   look identical to pre-feature playback because a 24 fps
   source with no CFR filter still emits 24 fps.

2. **Default path (`Source`), 30 fps content.** Play a 30 fps
   YouTube upload. G3 decoder headroom drops from ~11× to ~9×;
   drop count should stay at 0 at 320×240/q=2. imacg52 should
   play cleanly at single-digit CPU. Player log should show
   `dec=30.0fps / dis=30.0fps`.

3. **Default path (`Source`), 60 fps content.** Play a 60 fps
   YouTube upload. Expect imacg52 to play smoothly; the G3 may
   show drops — that's expected and documents where the
   headroom wall is. No crash, no A/V desync.

4. **Downconvert 30 → 24.** On the 30 fps content from step 2,
   pick `24` from the popup. Proxy URL should include `fps=24`.
   ffmpeg drops 6 frames/second via the CFR filter. Output
   should look slightly juddery vs. step 2 — that's what 30 →
   24 CFR looks like — and the decoder should report dec/dis=24.

5. **Downconvert 60 → 30.** On the 60 fps content from step 3,
   pick `30` from the popup. Proxy URL should include `fps=30`.
   Every other source frame is kept (clean 2:1 decimation), so
   motion should look smoother than the 30 → 24 case. G3 should
   have noticeably more headroom than at `Source`.

6. **Downconvert 50 → 25.** If a 50 fps PAL source is available
   (UK / EU broadcast rips tend to be 50p), repeat step 5 with
   `25`. Clean 2:1 decimation again; the point of `25`'s
   inclusion.

7. **Switching rates mid-session.** Play with `Source`, stop,
   pick `24`, play same video. Both plays should start cleanly;
   no stale-state crash, no proxy process-reuse problem (each
   play spawns a fresh ffmpeg, so there's nothing to carry
   over).

8. **Layout.** Screencap the controls row at 810 px window
   width. Verify: all four labels are readable with tight but
   non-touching spacing to their popups; no label text clips;
   popup arrows not obscured; Drops-frames label (if it appears)
   clips gracefully off the right edge rather than overlapping
   VSync.

9. **File-source path.** Play `file:/tmp/test.mp4` with the
   default `Source` selected. URL hitting the proxy's `/v/file`
   route should omit `fps=`. Then switch to `24` and replay;
   URL should now include `fps=24`. This proves the URL-builder
   fork applies to both `kind=yt` and `kind=file`.

10. **Out-of-band curl test.** `curl
    'http://uranium.local:5002/v/file?path=/tmp/test.mp4&w=320&h=240&q=2&g=12'`
    (no `fps=`, no `t=`). Should 200 and stream raw MPEG-1 at
    whatever the source rate is. Verifies the proxy change
    independent of the client.

## What's explicitly NOT in this feature

- No per-video automatic rate detection. The `Source` option
  lets ffmpeg figure it out; TigerTube doesn't pre-probe.
- No display of the actual output rate in the player window.
  The player log's `dec=…fps / dis=…fps` lines already show
  effective rate; that's enough for a dev diagnostic.
- No drop-frame rates (29.97, 59.94) as separate popup items.
  `Source` handles them implicitly when the source has one.
- No `29.97`-style exact entry in the popup. If someone needs
  that level of precision, they add a constant and rebuild.
- No change to the audio path. Audio rate stays at 44100 Hz.
- No change to `TT_VIDEO_GOP`. Keyframe spacing stays at 12
  frames, which is half a second at 24 fps and scales
  inversely at other rates (GOP=12 at 60 fps = 0.2 s keyframes,
  which is finer than needed but not a correctness problem).
  If keyframe density becomes an issue at very low rates, GOP
  knob is a separate feature.

## Open questions for the implementer

- Does the `NSPopUpButton` at 75 px comfortably render `Source`
  on Tiger's default system font? 13pt Lucida Grande "Source"
  is ~52 px text + popup chrome (~16 px arrow) = ~68 px needed;
  75 gives 7 px of padding. If the layout screenshot shows the
  arrow cramped against the text, bump to 80.
- Does libmpeg2 on the G3 handle a 50 or 60 fps MPEG-1 ES
  stream correctly when `Source` is chosen on high-rate
  content? MPEG-1 sequence headers legally include 50 and 60,
  but a G3 sized for 24 fps decoding may drop frames at the
  display timer (30 Hz) — which is a UX question, not a
  correctness one. Worth noting whatever the observed behavior
  is in the postmortem so the next person doesn't chase it as
  a bug. The `24` / `25` / `30` options exist precisely to
  escape this scenario if it turns out to be unpleasant.
