# Transport bar UI

## Problem

The player window is chromeless — there's no visible play/pause
control, no scrub bar, and no time readout. Pause landed as a
spacebar-only binding in `605796d`, but users who don't know the
keybindings see a bare video frame with no indication that anything
is controllable. Seeking is arrow-key-only (`+/-15s`, `+/-60s`) and
coarse: there's no way to jump to a specific timecode.

We want a standard-looking transport bar pinned to the bottom of the
windowed player, carrying a play/pause button, a scrub slider, and a
`M:SS / M:SS` time readout. Fullscreen stays completely chromeless
(no bar).


## Decisions already made (from the design discussion)

- **Video stays at 1× scale.** The video view keeps its native
  `vw × vh` pixel size. The window **grows** by the bar height to
  accommodate — new window content size is `vw × (vh + 32)`. No
  scaling of the decoded frames.
- **Bar height: 32 px.**
- **Fullscreen: no chrome at all.** The bar is a subview of the
  titled window's content view. Fullscreen already moves the
  `TTPlayerView` to a separate borderless window
  (`TTFullscreenWindow`); the bar stays behind on the titled window,
  invisible. No re-parenting of the bar. On exit-fullscreen,
  `TTPlayerView` goes back to the titled window's content above the
  bar — the bar is still there.
- **Pause semantics match the existing spacebar pause.** Stop the
  AudioUnit, set `paused`, rely on natural fetch-thread blocking.
  The play/pause button just calls the already-shipped
  `-togglePause`.


## Widget tree and layout

All programmatic — no nib changes. Inside the titled window's
content view:

```
content view (vw × vh+32)
┌────────────────────────────────────────────┐ y=32
│                                            │
│             TTPlayerView                   │   (vw × vh)
│                                            │
├────────────────────────────────────────────┤ y=32  ← bar top
│ [▶]   [━━━●────────────────]   0:23 / 3:42 │   (vw × 32)
└────────────────────────────────────────────┘ y=0
```

Frames at width W (computed at bar build time; recomputed via
autoresize when window grows on video-dim change):

| widget | frame | autoresize mask |
|---|---|---|
| bar (NSView) | `(0, 0, W, 32)` | `WidthSizable \| MaxYMargin` |
| TTPlayerView | `(0, 32, W, H-32)` | `WidthSizable \| HeightSizable` |
| play button | `(6, 4, 28, 24)` | `MaxXMargin` |
| scrub slider | `(40, 6, W-136, 20)` | `WidthSizable` |
| time label | `(W-92, 8, 86, 16)` | `MinXMargin` |


## Widget configuration

**Play button** (`NSButton`):
- `bezelStyle = NSShadowlessSquareBezelStyle`
- `title = @"▶"` initially; flipped to `@"❚❚"` when playing
- `font = [NSFont systemFontOfSize:11]` (Lucida Grande renders both
  glyphs cleanly at this size)
- `target = controller`, `action = @selector(playButtonClicked:)`
- The button's action just calls `-togglePause` and updates its own
  title from the resulting `paused` state.

**Scrub slider** (`TTScrubSlider`, a thin `NSSlider` subclass — see
below):
- `minValue = 0`, `maxValue = duration` (in seconds)
- `continuous = NO` — action fires on `mouseUp` only
- `target = controller`, `action = @selector(scrubDidFire:)`
- The action reads `[slider doubleValue]`, computes `delta = new -
  current`, calls `-[self seekBy:delta]`.

**Time label** (`NSTextField`):
- `bordered = NO`, `editable = NO`, `selectable = NO`,
  `drawsBackground = NO`
- `alignment = NSRightTextAlignment`
- `font = [NSFont labelFontOfSize:11]` (accept slight digit-jitter;
  Monaco is an alternative if it bothers us)
- Updated from `displayTimerFired:` each tick from the audio clock
  (or the slider's live value while dragging — see below).


## Scrub-drag feedback — `TTScrubSlider`

For the time label to track the knob while the user drags (without
firing a seek per pixel), we need to know the slider is mid-drag.
`NSSlider`'s `-mouseDown:` spins a modal tracking loop; we can
subclass to bracket it:

```objc
@interface TTScrubSlider : NSSlider { BOOL dragging; }
- (BOOL)isDragging;
@end

@implementation TTScrubSlider
- (void)mouseDown:(NSEvent*)event {
    dragging = YES;
    [super mouseDown:event];  // blocks until mouseUp, fires action
    dragging = NO;
}
- (BOOL)isDragging { return dragging; }
@end
```

Then in `displayTimerFired:` the time label chooses its source:

```
double t = ([scrubSlider isDragging])
    ? [scrubSlider doubleValue]
    : startTime + [audioPlayer samplesPlayed] / 44100.0;
```

The slider's knob position during drag reflects `[slider
doubleValue]` automatically (AppKit updates it in the tracking
loop), so the knob and the label move together. The action fires
exactly once on mouseUp.


## Duration plumbing

The player window controller currently takes `title, videoURL,
audioURL` and has no duration. We need to add a `duration`
parameter.

YouTube API returns duration as ISO 8601 (`"PT12M53S"`) in
`contentDetails.duration`. `NSString+.h` already has
`-iso8601DurationDisplay` (returns `"12:53"` for UI). We need the
raw seconds.

Two options:
1. **Add `-iso8601DurationSeconds` to `NSString+`** returning `int
   seconds`. Parse the same PT(?:\dH)(?:\dM)(?:\dS) format. Cleanest.
2. Pass the raw ISO string to the player and parse there. More
   coupling.

Go with (1). AppController has the raw ISO string in the row dict
before formatting for display (around `AppController.m:413-423` —
confirm when implementing); grab it there and pass seconds to
`-[TTPlayerWindowController initWithTitle:videoURL:audioURL:duration:]`.

If duration is unknown (e.g., row dict is missing it), pass `0`;
the slider gets `maxValue = 1` and is effectively a noop until the
user seeks with arrow keys. The time label shows `0:23 / --:--`.


## Window sizing

Current `buildWindow` creates a 320×240 content and then
`displayTimerFired:` resizes once video dims arrive:

```
TTPlayerWindowController.m:596-602
frame.size.width = (float)vw;
frame.size.height = (float)vh + titleBarH;
```

Change to include the bar: content height = `vh + 32`, so frame
height = `vh + 32 + titleBarH`. Initial `buildWindow` content also
grows to `320, 272` so the bar is visible before the first video
frame arrives.

The autoresize masks above mean a user-resized window keeps the bar
fixed-height at the bottom, the video view fills above, and the bar
widgets anchor correctly (play left, slider stretches, time right).


## Time formatting

Tiny helper, file-local to `TTPlayerWindowController.m`:

```c
static void ttFormatTime(double sec, char* out, size_t outLen);
```

Behavior:
- `sec < 0` clamps to 0.
- `sec < 3600` → `"M:SS"` (e.g. `"0:23"`, `"12:53"`).
- `sec >= 3600` → `"H:MM:SS"` (e.g. `"1:02:47"`).
- The label shows `"%s / %s"` — current / total. If total duration
  is unknown (0), show `"--:--"` on the right side.


## End-of-stream behavior

When streams end (`streamDidEnd`), `stop` is called. The play
button title stays at `❚❚` (technically incorrect) until the window
closes. Out of scope to fix — the window is about to close anyway.
If we want to be tidy: in `streamDidEnd` set the button back to
`▶` before calling `stop`.


## Files touched

- `TTPlayerWindowController.h` — new ivars (`NSView* bar`,
  `NSButton* playButton`, `TTScrubSlider* scrubSlider`,
  `NSTextField* timeLabel`, `double duration`); new init signature
  with `duration:`; new `-playButtonClicked:` and `-scrubDidFire:`
  action methods (may stay private-interface if we prefer).
- `TTPlayerWindowController.m` — bar construction in
  `-buildWindow`; window resize updated to account for bar height;
  display-timer update to refresh time label + slider position;
  action methods for play button and scrub slider; `ttFormatTime`
  helper.
- `TTPlayerView.{h,m}` — no changes; keyDown bindings keep working
  alongside the new UI.
- New files: `TTScrubSlider.{h,m}` — ~30 lines each for the
  drag-aware slider subclass.
- `TigerTube.xcodeproj/project.pbxproj` — add `TTScrubSlider.m` to
  the compile phase and its `.h` to the sources (four sections:
  `PBXFileReference`, `PBXBuildFile`, `PBXSourcesBuildPhase`,
  `PBXGroup` membership).
- `NSString+.{h,m}` — add `-iso8601DurationSeconds`.
- `AppController.m` — grab raw ISO duration from the row dict before
  it's overwritten with the display form (~line 413-423); pass the
  integer seconds to the new init.


## Ordered implementation steps

1. **`NSString+ iso8601DurationSeconds`** with a couple of inline
   self-tests (`fprintf` if the parse disagrees with a known
   expected value, in a `#ifdef DEBUG` block or a one-shot
   assertion).
2. **Plumb duration through** — add `duration:` to the init, store
   it as an ivar, update `AppController.m` to pass it. Build; run;
   confirm no regression.
3. **`TTScrubSlider`** — new files, pbxproj wiring. Build.
4. **Add the transport bar** — build the container view, play
   button, scrub slider, time label. Add to content view in
   `-buildWindow`. Resize window in the video-dim-change branch
   (displayTimerFired) to include bar height. At this point the bar
   is visible but does nothing. Verify layout via
   `screencapture` + scp per the CLAUDE.md iteration loop.
5. **Wire play button** → `togglePause` + title flip. Manual test:
   click toggles pause; spacebar still toggles pause; both keep
   button title in sync.
6. **Wire scrub slider action** → `seekBy:` delta. Manual test:
   drag knob, release, verify seek fires and lands near the
   dropped position.
7. **Wire time label** — update from `displayTimerFired:` using
   audio clock or slider-drag value depending on
   `[scrubSlider isDragging]`. Also update the slider's position
   (non-dragging case) so the knob tracks playback.
8. **Autoresize verification** — drag the window corner, confirm
   bar stays pinned, video view fills, widgets anchor correctly.
9. **Fullscreen verification** — enter/exit fullscreen,
   confirm bar disappears/reappears cleanly and the video view
   moves between windows without leaving the bar stranded.
10. **Edge cases** — pause-at-start (before first frame), pause-
    during-drag (shouldn't interact), seek-while-paused (click
    scrub, should seek and stay paused), unknown-duration case
    (show `--:--`, slider inert).


## Validation checklist

- [ ] Play button click toggles pause; title reflects state
- [ ] Spacebar still works and keeps button title in sync
- [ ] Scrub drag shows live time in label; seek fires on release
- [ ] Slider knob tracks playback during normal play
- [ ] Time label shows `M:SS / M:SS` (or `H:MM:SS / H:MM:SS` for
      long videos)
- [ ] Unknown duration: `0:23 / --:--`, slider inert
- [ ] Window resize: bar stays 32px at bottom, widgets anchored
- [ ] Fullscreen enter: bar gone; exit: bar back
- [ ] End of stream: playback stops cleanly (button state drift is
      cosmetic, acceptable)
- [ ] No regression in existing keyboard bindings (arrows, f, q,
      Esc, space)


## Open questions

- **Play button glyph.** Unicode `▶` U+25B6 and `❚❚` (two U+275A).
  If Lucida Grande at 11pt renders either glyph poorly on Tiger,
  fall back to bundled PNG/TIFF in `Resources/`. Decide during
  step 5 by looking at a `screencapture`.
- **Slider tick marks.** Default `NSSlider` has none; leaving it
  that way.
- **Volume control.** Out of scope for this feature. Open in a
  follow-up if it comes up.
- **Auto-hide during windowed playback.** Not proposed — the
  windowed bar stays visible always. Fullscreen has no bar. If we
  ever want auto-hide in windowed mode too, that's a separate
  feature.


## Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Tiger's Lucida Grande renders ▶/❚❚ poorly at 11pt | Fall back to bundled PNG/TIFF; decide empirically in step 5 |
| 2 | `[super mouseDown:]` doesn't return until mouseUp, so we're inside a modal tracking loop the whole time — any action fired during the drag is synchronous | Scrub action `continuous=NO` so it only fires once on mouseUp; display timer on main is blocked during the drag, but that's fine — the drag is usually <1 s and the slider's own tracking redraws the knob |
| 3 | Duration plumbing touches `AppController.m`, easy to break the row-dict handling | Grab the raw ISO before the display-format overwrite; add a guard for missing/nil duration |
| 4 | Window grows mid-playback when first frame dims arrive — bar height needs to be included in that resize | Covered in step 4; existing resize already computes `titleBarH` dynamically |
