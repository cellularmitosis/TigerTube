# Aspect-preserving scale + optional Crop checkbox

## Problem

Two related things, each small on its own — bundled into a single
plan because they touch the same controls row:

1. **The proxy pads streams to exactly `W×H` regardless of source
   aspect.** Today's `scale=W:H:force_original_aspect_ratio=decrease,
   pad=W:H:(ow-iw)/2:(oh-ih)/2` filter chain fits the source into
   the target box *and* fills the leftover axis with black. For
   anything that isn't 4:3 (most YouTube content is 16:9; Shorts are
   9:16) this bakes black bars into the MPEG-1 stream the client
   then decodes and renders. The bars waste pixels, cost the
   decoder extra work, and can't be "undone" downstream.
2. **The proxy already supports `?crop=auto` cropdetect for
   stripping baked pillarbox/letterbox bars from source content —
   but the client has no UI for it.** The knob lives in
   `resolve_crop` in `tigertube-proxy.py`; CLAUDE.md notes it exists
   but says "wire it in only if the double-bars case is a real user
   complaint." It is, occasionally — the classic case is old TV
   content uploaded with baked 4:3 pillarbox into a 16:9 frame.

## Solution overview

### Part 1 — drop the `pad=` filter

In `proxy/tigertube-proxy.py`, `build_video_cmd` drops the `pad=…`
step from the `-vf` chain. `scale=W:H:force_original_aspect_ratio=
decrease` alone treats `W×H` as a *bounding box* — the source is
scaled so it fits inside with aspect preserved, and the output
dimensions are whatever that math produces (not filled to the
target). Effects by source aspect, at the default `320×240` box:

| source | today (padded) | new (unpadded) | pixel count Δ |
|---|---|---|---|
| 4:3 (320×240) | 320×240 (filled) | 320×240 | — |
| 16:9 (426×240) | 320×240 w/ bars | 320×180 | 76,800 → 57,600 |
| 9:16 Shorts | 320×240 w/ bars | 135×240 | 76,800 → 32,400 |
| 1:1 | 320×240 w/ bars | 240×240 | 76,800 → 57,600 |

The client side needs **zero changes** — `TTPlayerView` already
letterboxes on any view-aspect-vs-stream-aspect mismatch
(`TTPlayerView.m:138-153`), `TTPlayerWindowController` auto-resizes
the window to the stream's actual dimensions on first frame
(`TTPlayerWindowController.m:928-942`), and libmpeg2 reads the
sequence dimensions from the stream (it was never hard-coded to the
request).

### Part 2 — Crop checkbox

A new `NSButton` (switch-style) labeled `Crop:` lives in the
controls row between `VSync:` and the drops label. When checked,
`playVideoAtIndex:` appends `&crop=auto` to the video URL for both
`kind=yt` and `kind=file`. When unchecked, the param is omitted
(the current fast-path behavior). Default: unchecked.

## Design decisions (and rationale)

### Why drop `pad=` instead of renaming the resolution popup to `<N>p`

The simpler-looking approach — "replace the popup items with
`240p`, `360p`, etc. and use `scale=-2:<h>`" — has a subtle
performance regression: `240p` for a 16:9 source gives 426×240 =
102,240 pixels/frame, bigger than today's padded 320×240 = 76,800.
On the G3 that's a decoder-budget bust. The user would then have
to manually downshift to a lower tier for 16:9 content, which is
annoying.

Keeping the `W×H` popup as a *bounding box* (drop-pad approach) has
the opposite effect: non-4:3 content gets **fewer** pixels than
today, because the black pad was never free. The G3 budget is
automatically preserved, and the user never has to think about
source aspect.

### Why leave the resolution popup labels unchanged

Items still say `320x240`, `640x480`, etc. Post-feature these
should be read as "the stream's output fits inside this box." A
tempted alternative is renaming to `320x240 max` or similar to
make the max-box semantics explicit, but:

- For 4:3 content (most legacy YouTube uploads), the label is
  still exactly accurate — output *is* 320×240.
- For non-4:3 content, the user's mental model "I picked 320×240
  and got something that fits" holds up.
- Renaming is cosmetic and can happen later if it turns out to
  confuse users.

### Why a separate Crop checkbox, not auto-detect

Auto-detection would mean always running cropdetect, which adds
1-2 s to first-frame latency (per the comment in `resolve_crop` and
the CLAUDE.md caveat). That's a tax most plays don't need — the
double-bars case isn't ubiquitous. A user-opt-in checkbox keeps
the fast path fast and lets people flip it on for the one clip
that needs it.

### Why `Crop:` as the label, not `Crop bars:` or `Auto-crop:`

`Crop:` matches the one-word-plus-colon pattern of the neighboring
controls (`Quality:`, `Framerate:`, `VSync:`). The proxy endpoint
it triggers is literally `?crop=auto` so the word matches the
vocabulary on that side too. Shorter is better for a checkbox
label; the user hovers / reads the docs / looks at the proxy log
if they want to know what it does.

### Where in the controls row Crop lives

After `VSync:` and before the hidden-by-default drops label — i.e.
at the right edge of the "user-input toggles." The drops label
stays in its current position (far right, anchored before margin).

### Layout and minWidth

Adding a `Crop:` label (~40 px) + checkbox (20) + inter-group gap
(16) = 76 px pushes the row total past today's 820 minWidth. The
existing minWidth was set exactly where the previous row ended;
we bump again to 900.

The alternative — reclaim space by shrinking the Resolution
popup — is tempting (the 150 px allocation has slack for
`1344x1008`) but deferred. That's a cosmetic tightening pass that
doesn't belong inside a feature plan.

## Files touched

- `proxy/tigertube-proxy.py` — delete the `pad=…` from
  `build_video_cmd`. No other proxy changes.
- `src/AppController.h` — one new ivar, `NSButton* cropCheckbox`.
- `src/AppController.m`:
  - `buildWindow`: add `Crop:` label + checkbox after the VSync
    block, bump `setMinSize` from (820, 400) to (900, 400).
  - `playVideoAtIndex:`: read `cropCheckbox` state, append
    `&crop=auto` to `vURL` in both `kind=yt` and `kind=file`
    branches when on.

No changes to the Resolution popup, the Framerate popup, or the
audio URL.

## Implementation steps

### Step 1 — Proxy: drop `pad=` from the video filter

```python
    vf = ""
    if crop:
        vf += f"crop={crop},"
    vf += (f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
           f"setpts=PTS-STARTPTS")
    if fps is not None:
        vf += f",fps={fps}"
```

The comment block above `vf =` currently justifies the
`setpts=PTS-STARTPTS` rebase with a reference to the `fps=N` CFR
filter. That's still accurate — no comment edit required.

### Step 2 — Client: add the crop checkbox to `buildWindow`

After the VSync checkbox block (which currently ends with
`x += vsBoxW + 16.0f;`):

```objective-c
/* Crop: toggle -- when checked, adds ?crop=auto to the video URL
   so the proxy runs cropdetect and strips baked pillarbox/letterbox
   bars from the source.  Off by default because the probe adds
   1-2 s to first-frame latency. */
float cropLabelW = 40.0f;
NSTextField* cropLabel = [[NSTextField alloc] initWithFrame:
    NSMakeRect(x, rowY, cropLabelW, controlsH)];
[cropLabel setStringValue:@"Crop:"];
[cropLabel setBezeled:NO];
[cropLabel setDrawsBackground:NO];
[cropLabel setEditable:NO];
[cropLabel setSelectable:NO];
[cropLabel setAutoresizingMask:NSViewMinYMargin];
ttCenterLabelInRow(cropLabel, rowY, controlsH, cropLabelW);
[content addSubview:cropLabel];
[cropLabel release];
x += cropLabelW;

float cropBoxW = 20.0f;
NSButton* cropBox = [[NSButton alloc] initWithFrame:
    NSMakeRect(x, rowY, cropBoxW, controlsH)];
[cropBox setButtonType:NSSwitchButton];
[cropBox setTitle:@""];
[cropBox setState:NSOffState];
[cropBox setAutoresizingMask:NSViewMinYMargin];
[content addSubview:cropBox];
cropCheckbox = cropBox; /* weak: retained by superview */
[cropBox release];
x += cropBoxW + 16.0f;
```

Add the ivar to `AppController.h` right after `vsyncCheckbox`:

```objective-c
NSButton* cropCheckbox;         /* weak; when on, appends
                                   &crop=auto to the video URL */
```

Bump `setMinSize` from `NSMakeSize(820, 400)` to
`NSMakeSize(900, 400)`.

### Step 3 — Client: append `&crop=auto` in `playVideoAtIndex:`

Right after the `fpsTitle` / `useSourceFps` block, read the
checkbox:

```objective-c
BOOL cropOn = ([cropCheckbox state] == NSOnState);
fprintf(stderr, "playVideoAtIndex: crop=%s\n",
        cropOn ? "auto" : "off");
```

Build a reusable suffix once, then apply it to both the yt and
file URLs:

```objective-c
NSString* cropSuffix = cropOn ? @"&crop=auto" : @"";
```

And interpolate it at the end of each `vURL` format string.
E.g., the YouTube-with-explicit-fps case:

```objective-c
vURL = [NSString stringWithFormat:
    @"%@/v/yt/%@?w=%d&h=%d&q=%d&fps=%@&g=%d%@",
    proxyHost, videoId,
    width, height, qscale,
    fpsTitle, TT_VIDEO_GOP,
    cropSuffix];
```

Apply the same `%@` tail to the three other `vURL` branches
(yt+Source, file+explicit-fps, file+Source). Audio URL is
unaffected.

### Step 4 — No client-side display work needed

`TTPlayerView.displayFrame:` already letterboxes. The window auto-
resizes to the stream's dimensions when `setupTextureWithWidth:
height:` fires on the first frame. A 16:9 stream at 320×180 will
open a 320×180-sized player window (plus transport bar). Nothing to
touch in the player code.

## Validation

Manual, on imacg3 and imacg52.

1. **Pre-existing 4:3 content path still works.** Play a legacy
   4:3 YouTube clip (the classic Twilight Zone intro is perfect —
   `yt-dlp -F ORbseYAkzRM` shows it's 4:3 all the way down).
   Default Resolution = `320x240`. Proxy log should show the new
   `-vf scale=320:240:force_original_aspect_ratio=decrease,setpts=
   PTS-STARTPTS` (no `pad=`). Client window opens as 320×240. No
   black bars visible.

2. **16:9 content gives narrower output.** Play any modern
   16:9 YouTube upload at `320x240`. Stream dims arrive as 320×180
   (or very close — ffmpeg may round). Player window opens as
   320×180 + bar. No black bars in the stream; *if* the user
   manually enlarges the window to a different aspect, the GL view
   letterboxes correctly.

3. **Shorts / 9:16 content.** If convenient, play a vertical
   Short. Stream dims should arrive as roughly 135×240 (the box
   height, width following aspect). Window opens narrow-and-tall.
   Aspect letterbox in fullscreen.

4. **Crop off (default) — baked-pillarbox case.** Play a
   16:9-container-with-baked-4:3-pillarbox upload (old TV content
   re-uploaded). Expect the double-bars effect to persist — today's
   behavior. This documents the baseline the Crop checkbox is
   meant to fix.

5. **Crop on, same source.** Flip Crop to checked, replay. Proxy
   log URL should now include `&crop=auto`, and the stream should
   come through with the baked bars stripped. First-frame latency
   should be visibly higher (1-2 s probe) vs. step 4 — that's the
   documented cost.

6. **Crop on with content that doesn't need crop.** Check the box
   and play an ordinary 16:9 video. `cropdetect` should either no-op
   or produce a zero-border result; output identical to step 2
   (modulo the ~1-2 s startup tax). No visual regression.

7. **Layout at minWidth.** Resize the main window down to its
   new 900 minWidth. Verify all controls remain visible; the drops
   label clips gracefully off the right edge.

8. **Switching crop mid-session.** Play with Crop off, stop (close
   player window), toggle Crop on, play the same video. Each play
   spawns a fresh ffmpeg, so there's no state carried over; both
   should start cleanly.

## What's explicitly NOT in this feature

- No change to the Resolution popup labels. `320x240` still reads
  as `320x240`, with the post-feature meaning "output fits inside
  this box."
- No change to how the proxy picks the source height for YouTube
  (`compute_src_height` still derives from `h`, unaffected by the
  filter-chain edit).
- No manual-crop UI. The proxy supports `?crop=W:H:X:Y` for
  explicit crop regions; the checkbox only exposes `auto`. Adding a
  manual form would be a separate feature.
- No proxy-side caching story for the cropdetect probe beyond
  what already exists (it caches per source, see the
  `resolve_crop` implementation).
- No changes to the window's initial size calculation in
  `buildWindow`. The main app window bounds are independent of the
  player window.
- No changes to the Framerate popup.

## Open questions for the implementer

- Does `40 px` comfortably render `Crop:` at 13 pt Lucida Grande?
  The framerate-popup postmortem noted Tiger's font metrics
  render a little wider than the estimator predicts. If the
  layout screenshot shows `Crop:` kissing the checkbox, bump to
  44 or 48.
- If Crop is checked while a bad/corrupt source is being played,
  cropdetect may return unusable results. The proxy's existing
  behavior in that case is documented in `resolve_crop`; worth
  confirming during validation that TigerTube doesn't crash or
  hang on the bad-cropdetect path. (Expected: the proxy returns a
  400 or a reasonable fallback; the client's existing HTTP-error
  handling covers it.)
