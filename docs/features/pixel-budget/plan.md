# Pixel-budget popup (experimental Mpx/s UI)

> **Status: first draft, pending review.** This plan was drafted with
> assumptions marked **[ASSUMPTION]** to leave placeholders for the
> user to steer. Assumptions are collected at the bottom for fast
> review.

## Problem

The Resolution popup picks a bounding box (e.g. `320×240`) that the
proxy fits the source into, aspect-preserving post-aspect-scale-and-crop.
That's easy to reason about, but the pixel count actually fed to the
G3's decoder still varies by:

- **Source aspect.** 320×240 max gives 76,800 pixels for 4:3,
  57,600 for 16:9 (320×180), 32,400 for 9:16 Shorts (135×240).
- **Framerate.** 320×240 at 24 fps is 1.84 Mpx/s; at 60 fps it's
  4.6 Mpx/s. Same box, 2.5× the decoder work.

For the G3, whose practical ceiling is ~5 Mpx/s (320×240@24 gives
~11× decoder headroom; beyond that it gets tight), the *pixel-rate
budget* is what actually matters — not the resolution label.

When a user picks "320×240" and loads a 60 fps source with `Source`
framerate, they unknowingly ask the decoder to process 2.5× what
the popup implies. Today they notice when frames start dropping and
have to manually downshift. An experimental UI that expresses
budget directly ("I want 2 Mpx/s") would let the proxy pick the
resolution that stays within that limit given the source's aspect
and framerate.

## Solution overview

### Client: new `Budget:` popup

A second `NSPopUpButton` in the controls row with items:

- `Off` (default; use the Resolution popup as-is)
- `1 Mpx/s` — very conservative, safe on any source
- `2 Mpx/s` — roughly today's 320×240@24 default
- `4 Mpx/s` — roughly today's 480×360@24
- `8 Mpx/s` — roughly today's 640×480@24
- `16 Mpx/s` — G5 territory; G3 will struggle

When set to anything other than `Off`, the client:

1. **Disables the Resolution popup** (setEnabled:NO) so it's visible
   that Budget is the active knob.
2. Omits `w=` and `h=` from the video URL.
3. Includes `&mpxs=<N>` where `<N>` is the numeric prefix from the
   popup title (e.g., `2`).

### Proxy: derive W×H from budget + source aspect + fps

When `mpxs` is present, the proxy:

1. Determines source aspect `A` — for YouTube, from the
   yt-dlp formats dict; for `file:` sources, via a cached
   `ffprobe` call.
2. Determines effective fps `F` — the client's `fps` value if
   present, else source fps (also from yt-dlp / ffprobe).
3. Solves for `target_h`:
   `target_h = round(sqrt(budget_mpxs * 1e6 / (F * A)))`.
   `target_w = round(A * target_h)`.
4. Rounds both to multiples of 16 for MPEG-1 encoder friendliness.
5. Clamps `target_h` to a minimum of 144 (matches the smallest
   existing Resolution popup tier).
6. Logs the chosen `W×H` to the proxy stderr.

Then uses `target_w` / `target_h` as the `w` / `h` for the existing
`scale=w:h:force_original_aspect_ratio=decrease` filter chain. No
other filter changes.

## Design decisions (and rationale)

### Why a **second** popup and not a replacement for Resolution

**[ASSUMPTION]** Resolution stays as-is, Budget sits alongside.

Rationale:
- The Resolution popup's "pick a max box" model is intuitive and
  sufficient for most users. Changing its labels to `1 Mpx/s` etc.
  would be a destructive UX change for anyone who prefers the
  spatial-resolution mental model.
- Making Budget a separate opt-in popup lets the user choose which
  mental model suits the moment: spatial (Resolution) or rate
  (Budget).
- `Off` as the default is a no-op change for every existing user.

An alternative the user may prefer: **replace** Resolution with
Budget items outright. That would simplify the UI (one popup) but
remove the current spatial-resolution knob entirely. Flag on review.

### Why `Budget:` as the label, not `Mpx/s:` or `Rate:`

Short English word for "a limit on pixel rate." Matches the
one-word-plus-colon pattern of the row's other labels. The popup
items themselves carry the unit (`1 Mpx/s`), so the label doesn't
have to.

Alternatives considered:
- `Mpx/s:` — technically precise but jargon-y.
- `Rate:` — too generic, might be confused with bitrate (the `br=`
  proxy knob) or framerate (the Framerate popup).
- `Pixels/s:` — verbose and would force a narrower popup.

### Why these six values (Off / 1 / 2 / 4 / 8 / 16)

Powers of 2, spanning the G3's actual operating range:

- **1 Mpx/s**: ~240×180@24 fps. Well under the G3's ceiling; useful
  for 60 fps Shorts that would otherwise bust the budget.
- **2 Mpx/s**: ~320×240@24 fps. Matches today's default.
- **4 Mpx/s**: ~480×360@24 fps. Near the G3's sustainable upper
  bound with AltiVec absent.
- **8 Mpx/s**: ~640×480@24 fps. Strains the G3; comfortable on G5.
- **16 Mpx/s**: ~960×720@24 fps. G5 territory only; included for
  completeness on the G5 iMac.

Denser steps (1.5, 3, 6) aren't useful without finer-grained
feedback — we're already making a rough heuristic call. The
popup stays short.

### Why the proxy picks the resolution, not the client

The client doesn't know the source aspect or source fps for a given
YouTube ID until yt-dlp has resolved the formats — and the proxy
does that resolution. Asking the client to re-derive the aspect /
fps would require a second API call (e.g., `/probe/yt/<id>`) on
every play, which is wasteful.

For file: sources the same logic applies: the proxy can run
`ffprobe` on the file and cache the result per path. The client
has no access to server-side files at all.

Server-side derivation keeps the client dumb (sends `mpxs=2`, done)
and the proxy authoritative about what the source actually is.

### How `fps=Source` + `mpxs=N` interact

When both the Framerate popup is `Source` **and** Budget is
non-`Off`, the proxy needs the source's actual fps to compute the
budget. That data is already available:

- yt-dlp's format entry includes `fps`. Pick the chosen format,
  read its `fps`, use that as `F`.
- For file: sources, ffprobe's `stream=r_frame_rate` gives it as
  a fraction (e.g., `24000/1001`); the proxy evaluates and uses
  the float.

Fallback if either source fails: `F = 24`. Logged as a warning.

### Why round to multiples of 16

MPEG-1 encoders prefer dimensions that are multiples of 16
(matches the macroblock grid). ffmpeg will accept other dimensions
and pad internally, but multiples of 16 avoid the pad overhead
and produce slightly more efficient output. The rounding loses a
few pixels of budget precision — acceptable given the coarse tier
spacing.

### Why clamp to `target_h >= 144`

At very low budgets + high-fps + narrow aspects, the math can
produce pathological dimensions (e.g., 48×64 for 1 Mpx/s / 60 fps /
9:16). 144p is the lowest standard resolution the Resolution popup
exposes, so using it as a floor keeps output recognizable. Users
at that budget/fps/aspect combination are already getting worse
than 144p decoder headroom, so the floor isn't hiding a performance
win.

### Why disable the Resolution popup when Budget is active

**[ASSUMPTION]** — the less-destructive alternative is to leave it
enabled but silently ignore it.

Rationale for the assumption: if both popups are active the user
can set them to contradictory values (e.g., Resolution=640×480,
Budget=1 Mpx/s at 60 fps → proxy picks 240×180, ignoring
Resolution). Disabling the ignored popup makes the interaction
obvious. The alternative — leaving Resolution enabled — is lighter
weight but invites confusion.

## Files touched

- `src/AppController.h` — one new ivar, `NSPopUpButton* budgetPopup`.
- `src/AppController.m`:
  - `buildWindow`: add `Budget:` popup. Question: **between
    Framerate and VSync**, or **at the end of the row (after Crop)**.
    **[ASSUMPTION]** at the end, since it's experimental and users
    should get to the established knobs first.
  - `playVideoAtIndex:`: read `budgetPopup`, build URL with
    either `w=&h=` (Off) or `mpxs=<N>` (non-Off). Disable /
    re-enable `resolutionPopup` based on state.
- `proxy/tigertube-proxy.py`:
  - `parse_video_params`: parse `mpxs` query param; treat missing
    as `None`.
  - New helper `compute_budget_dims(mpxs, aspect, fps)`. Returns a
    `(w, h)` tuple.
  - `build_video_cmd` route handlers (`GET_video_yt`,
    `GET_video_file`): when `mpxs` is set, compute dims server-side
    instead of using query `w`/`h`.
  - yt-dlp format-fps / ffprobe source-fps lookup hooked in.
- No changes to the audio path.

## Implementation steps

### Step 1 — Proxy: `compute_budget_dims` helper

```python
def _round16(x):
    """Round to nearest multiple of 16, minimum 16."""
    return max(16, int(round(x / 16) * 16))

def compute_budget_dims(mpxs, aspect, fps):
    """Given a pixel-rate budget (Mpx/s), source aspect (w/h), and
    effective fps, return the largest (w, h) that fits, rounded to
    multiples of 16, with h clamped to >= 144."""
    budget = mpxs * 1_000_000.0
    # w*h*fps = budget, w = aspect*h  =>  h = sqrt(budget / (aspect*fps))
    h = math.sqrt(budget / (aspect * fps))
    h = max(144, _round16(h))
    w = _round16(aspect * h)
    return (w, h)
```

Add unit-test-style self-checks at module load time for a few known
points (e.g., `compute_budget_dims(2, 4/3, 24)` near 320×240).

### Step 2 — Proxy: aspect + fps lookup

```python
def lookup_source_aspect_and_fps(kind, ident, src_h=YT_DEFAULT_SRC_HEIGHT):
    """Return (aspect, fps) for the source.  aspect = w/h, fps = float."""
    if kind == "yt":
        info = yt_extract_info(ident)
        fmt = pick_video_format_info(info, src_h)  # (new) returns the full dict
        w = int(fmt.get("width") or 640)
        h = int(fmt.get("height") or 360)
        fps = float(fmt.get("fps") or 24.0)
        return (w / h, fps)
    if kind == "file":
        # Reuse / extend the probe cache used by resolve_crop.
        meta = _cached_file_probe(_resolve_file_source(ident))
        return (meta["aspect"], meta["fps"])
    abort(400, f"unknown kind: {kind}")
```

Both branches should fall back to `(16/9, 24.0)` with a warning if
the lookup throws.

### Step 3 — Proxy: wire into the route handlers

```python
def GET_video_yt(handler):
    ...
    t, w, h, br, fps, g, qv, crop_arg, mpxs = parse_video_params(q)
    if mpxs is not None:
        aspect, src_fps = lookup_source_aspect_and_fps("yt", youtube_id, ...)
        effective_fps = fps if fps is not None else src_fps
        w, h = compute_budget_dims(mpxs, aspect, effective_fps)
        print(f"--- budget: mpxs={mpxs} aspect={aspect:.3f} "
              f"fps={effective_fps} -> {w}x{h}", flush=True)
    src_h = compute_src_height(h)
    ...  # existing path
```

Same pattern in `GET_video_file`.

### Step 4 — Client: `Budget:` popup in `buildWindow`

After the Crop checkbox block (at the end of the controls row, per
assumption):

```objective-c
/* Budget: experimental pixel-rate popup.  When non-Off, the client
   sends mpxs=<N> and the proxy derives W×H from the source aspect
   and fps.  Overrides the Resolution popup. */
float bgLabelW = 56.0f;
NSTextField* bgLabel = [[NSTextField alloc] initWithFrame:
    NSMakeRect(x, rowY, bgLabelW, controlsH)];
[bgLabel setStringValue:@"Budget:"];
/* ...bezeled/drawsBackground/etc same as other labels... */
ttCenterLabelInRow(bgLabel, rowY, controlsH, bgLabelW);
[content addSubview:bgLabel];
[bgLabel release];
x += bgLabelW;

float bgPopW = 95.0f;  // "16 Mpx/s" is widest
NSPopUpButton* bgPop = [[NSPopUpButton alloc] initWithFrame:
    NSMakeRect(x, rowY, bgPopW, controlsH)];
[bgPop addItemsWithTitles:[NSArray arrayWithObjects:
    @"Off", @"1 Mpx/s", @"2 Mpx/s", @"4 Mpx/s",
    @"8 Mpx/s", @"16 Mpx/s", nil]];
[bgPop selectItemWithTitle:@"Off"];
[bgPop setTarget:self];
[bgPop setAction:@selector(budgetChanged:)];
[bgPop setAutoresizingMask:NSViewMinYMargin];
[content addSubview:bgPop];
budgetPopup = bgPop;
[bgPop release];
x += bgPopW + 16.0f;
```

New action handler:

```objective-c
- (void)budgetChanged:(id)sender {
    BOOL active = ![[budgetPopup titleOfSelectedItem]
                      isEqualToString:@"Off"];
    [resolutionPopup setEnabled:!active];
}
```

Adding the label+popup widens the row by ~167 px (56 label + 95
popup + 16 gap). Current row max is ~893; new total ~1060. Bump
`setMinSize:` from (900, 400) to **(1070, 400)** — pushing past
iMac G3's 1024 screen, which means the drops label WILL clip at
minWidth. That's already hidden by default and only matters when
drops > 0; acceptable for an experimental knob.

### Step 5 — Client: wire `playVideoAtIndex:`

After the fps / crop block, parse budget:

```objective-c
NSString* bgTitle = [budgetPopup titleOfSelectedItem];
BOOL budgetOff = [bgTitle isEqualToString:@"Off"];
int mpxs = 0;
if (!budgetOff) {
    /* Titles are "N Mpx/s" -- intValue stops at the space. */
    mpxs = [bgTitle intValue];
}
```

Build the URL fork:

```objective-c
if (budgetOff) {
    /* existing Resolution-based URL */
} else {
    vURL = [NSString stringWithFormat:
        @"%@/v/yt/%@?mpxs=%d&q=%d%@&g=%d%@",
        proxyHost, videoId, mpxs, qscale,
        (useSourceFps ? @"" :
            [NSString stringWithFormat:@"&fps=%@", fpsTitle]),
        TT_VIDEO_GOP, cropSuffix];
}
```

Same branch for `kind=file`.

## Validation

Manual, on imacg3 and imacg52. `Off` path should be byte-identical
to today's (validates no regression).

1. **Default path (Off).** Default popup = `Off`. Every existing
   validation from the aspect-scale-and-crop plan should still pass
   unchanged.
2. **Budget=2 on a 4:3 / 24 fps source.** Expect proxy to derive
   `(320, 240)` (or close). Resolution popup is disabled.
3. **Budget=2 on a 16:9 / 24 fps source.** Expect `(368, 208)` or
   similar (2 Mpx/s at 16:9 @ 24 fps). Player window opens at the
   computed size.
4. **Budget=2 with fps=Source on a 60 fps source.** Proxy reads
   source fps from yt-dlp, derives a smaller `(W, H)` to fit the
   60 fps budget. Should be ~ `(240, 144)` or similar.
5. **Budget=1 with an extreme source.** 9:16 Shorts, 60 fps.
   Budget math would want tiny dimensions; clamp-to-144 kicks in,
   resulting output is `(~80, 144)`.
6. **File-source with Budget.** Requires ffprobe; verify proxy
   logs the `(aspect, fps)` it read.
7. **Switching between Off and a Budget.** Resolution popup
   enables/disables correctly. Mid-session switch works (each
   play is independent).
8. **Out-of-band curl test.** `curl '…/v/yt/<id>?mpxs=2&q=2&g=12'`
   (no `w`, no `h`, no `fps`). Should 200 and stream at the
   server-computed dims.

## What's explicitly NOT in this feature

- No dynamic re-adjustment mid-stream. Budget is set at play
  time; the proxy spawns one ffmpeg with fixed `W×H` and the
  stream stays that size until the next play.
- No display of the derived `W×H` in the client UI. The proxy
  logs it; the user can check the log or just observe the player
  window size.
- No budget mode for audio. Audio bitrate is unchanged.
- No saving of the Budget selection across sessions.

## Open questions / assumptions to confirm

### UX

- **A1. Popup placement.** Assumed: at the right end of the row
  after Crop. Alternative: between Framerate and VSync. Which?
- **A2. Label text.** Assumed: `Budget:`. Alternative: `Mpx/s:`,
  `Rate:`, `Pixel rate:`.
- **A3. Tier values.** Assumed: Off / 1 / 2 / 4 / 8 / 16. Any
  different granularity? Include 0.5 or 32?
- **A4. Resolution popup when Budget is active.** Assumed:
  disabled. Alternative: left enabled but ignored.
- **A5. Budget replaces Resolution?** Assumed: stays as a second
  popup. Alternative: swap Resolution items to Budget items (one
  popup, destructive change).
- **A6. minWidth bump to 1070.** On a 1024-wide iMac G3 this means
  the drops label clips at minWidth. Acceptable, or should we cut
  something else to stay under 1024?

### Derivation logic

- **B1. Round to multiples of 16?** Assumed yes for MPEG-1
  efficiency. Multiples of 8 or no rounding also work.
- **B2. Floor of 144p.** Assumed. Alternative: no floor (let tiny
  dims happen), or a different floor like 192p.
- **B3. Fallback aspect/fps when lookup fails.** Assumed
  `(16/9, 24)`. Might prefer `(4/3, 24)` if most legacy content is
  4:3, or abort with 500.
- **B4. Budget interpretation when Resolution knob "bounds" conflict.**
  With Resolution disabled, this is moot. But if the user prefers
  A4 = "enabled but ignored", we should document whether the
  Resolution value is used as an additional upper bound (e.g., never
  let Budget-derived dims exceed the Resolution cap). Adds
  complexity; default assumption is "no."

### Operational

- **C1. Where does the ffprobe cache live?** Assumed: extend the
  one that `resolve_crop` already uses. If that doesn't currently
  cache aspect/fps, we'll need to expand what it stores. The
  alternative is a second cache keyed the same way — slight
  duplication.
- **C2. yt-dlp format selection.** The proxy currently picks a
  format given `src_h`. For Budget mode we don't have `src_h` at
  lookup time (we're trying to compute it). Options:
  (a) Use a default `src_h` (e.g., 720) for the aspect/fps lookup,
      then re-pick after computing target h.
  (b) yt-dlp's `info` dict has all formats; read aspect/fps off
      any one (they're consistent per video).
  Option (b) is cleaner; assumed.
- **C3. Exposing the derived W×H to the client.** Assumed
  proxy-log-only. A `?debug=1` response header or a tiny
  `GET /budget-preview` endpoint could echo the derivation for
  client UI. Follow-up, not in this feature.
