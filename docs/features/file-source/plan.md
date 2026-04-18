# Local-file source via `file:` search prefix

## Problem

YouTube periodically puts the shared proxy's IP into their bot-detection
path, at which point yt-dlp starts returning auth / 403 errors and no
new videos can be played until the block lifts. During those windows
there's no way to exercise the rest of the pipeline (proxy transcode →
libmpeg2 decode → GL render → CoreAudio) on imacg3 or imacg52.

We want a testing back-door that skips YouTube entirely: the user types
`file:<path>` in the search field and a single-row result appears for
that local video file; clicking it streams through the existing
transcode path with no yt-dlp involvement.

The proxy already has `/v/file?path=…` and `/a/file?path=…` routes
from earlier development work (see `GET_video_file` /
`GET_audio_file` in `proxy/tigertube-proxy.py`), so this is almost
entirely a client-side change.

## Solution overview

1. In the search field's action handler, detect a leading `file:`
   prefix **before** delegating to `YTClient`. If present, short-circuit
   the YouTube search path entirely.
2. Validate the filename portion against a client-side extension
   whitelist (`.mp4`, `.m4v`, `.mov`, `.mkv`, `.avi`, `.mpg`,
   `.mpeg`, `.webm`, `.ogv`, `.ogm`, `.wmv`, `.flv`, `.ts`, `.m2ts`,
   `.mts`, `.3gp`, `.3g2`). Case-insensitive.
3. On pass, synthesize a single-row result dict tagged with
   `kind=file` and push it into `results` exactly like a YouTube search
   result — so the table cell, keyboard navigation, and click-to-play
   all work unchanged.
4. On click, `playVideoAtIndex:` branches on `kind`: for `yt` it
   builds the existing `/v/yt/<id>` URL, for `file` it builds
   `/v/file?path=…` with the same `w=&h=&q=&fps=&g=` params (and
   `/a/file?path=…` for audio).
5. Validation failure (bad extension, empty path) logs to stderr and
   leaves the results table as-is. No modal dialog — this is a
   developer-facing shortcut, not user-facing UI.

Both input styles route through the same logic:

- `file:foo.mp4` → proxy resolves `foo.mp4` relative to its own cwd.
  The proxy's `_resolve_file_source` already does
  `os.path.abspath(ident)` so this falls out for free.
- `file:/tmp/foo.mp4` → proxy treats it as absolute and runs the
  same `isfile()` check.

## Design decisions (and rationale)

### Why the client does the extension check, not the proxy

The proxy already guarantees the file exists and is readable. The
client-side check is a *UX safety rail*, not a security boundary — it
stops `file:notes.txt` from becoming a request to the proxy that will
fail later with ffmpeg demux errors and a cryptic stderr line. Keeping
the check client-side means the error shows up at the moment of typing,
not seconds later after a round-trip. The proxy's existing `isfile()`
check handles the "file doesn't exist" case; the client's extension
check handles the "this is plainly not a video file" case.

### Why no modal error dialog on bad extension

This feature is a testing / diagnostic workaround. The user is the
developer. Logging to stderr is how the rest of the app surfaces
unusual conditions (`fprintf(stderr, …)` is already the established
pattern per CLAUDE.md). A modal `NSAlert` is overkill; it also would
have to be dismissed on every accidental typo. Silent-ish failure with
a log line is correct here.

### Why `file:` specifically, not a more elaborate syntax

It's unambiguous (YouTube IDs are never 4 chars with a colon), it
mirrors familiar URL-scheme conventions, and it's short enough to type
into the search field hundreds of times without friction. Rejected
alternatives:

- `/file foo.mp4` (leading slash) — too easy to fat-finger into a
  real search for "/file"
- A second "Mode" popup next to Resolution/Quality — adds permanent
  UI weight for a dev-only feature

### Why tag the row with `kind`, not sniff the URL

`playVideoAtIndex:` currently assumes every row is a YouTube result
and does `[item objectForKey:@"videoId"]`. For `kind=file` rows we
store the path in a distinct key (`filePath`) and leave `videoId`
absent. Branching on an explicit `kind` field is clearer than
inferring from which keys happen to be set, and it leaves room for
future source kinds (e.g., `kind=rtsp`, `kind=http`) without another
refactor.

### Why skip the thumbnail column for file: rows

The `ThumbnailCache` fetches from `i.ytimg.com`. For a local file we
have no thumbnail URL and don't want to invent one. The cache is
called from the data source with `nil` URL — we either (a) audit
`ThumbnailCache.imageForVideoId:url:` to confirm a nil URL returns
nil cleanly, or (b) short-circuit in `tableView:
objectValueForTableColumn:row:` when `kind=file` and return nil
directly. Option (b) is simpler and doesn't depend on cache behavior.
The cell will render empty / with whatever NSImageCell does on nil —
probably blank, which is fine for a dev feature.

### Why duration=0 (unknown) instead of ffprobing

Probing the file to fill in duration would need either (a) a client-
side `ffprobe` binary on the Mac (we don't ship one) or (b) a new
proxy route like `/probe/file`. Both are overkill — the transport bar
already tolerates unknown duration (the scrub slider just shows total
time = 0 and the elapsed label counts up). Users testing this path
know what file they're playing; they don't need the duration in the
table row.

### Why the whitelist lives on the client, hardcoded

It's a typo filter. We're not trying to limit the user — ffmpeg will
happily demux something esoteric like `.ts` or `.asf` that we didn't
list, and the user can trivially extend the whitelist or remove the
check. No config file, no runtime toggle, no env var. The list is
eight lines in `AppController.m`.

### Why re-use the existing Resolution / Quality / VSync popups

They're user-intent knobs — the user wants the file transcoded at,
say, 640×480 q=2 with vsync on. That's no different from a YouTube
video. No new UI needed for the file path; the popups apply as-is.
(This is consistent with the proxy-owns-derivation memory: Resolution
is a legitimate user-intent client knob.)

## Files touched

- `src/AppController.h` — no signature changes expected. One new ivar
  only if we hoist the extension list to a class member (unlikely).
- `src/AppController.m` — all the real work:
  - `searchAction:` (or a new private helper called from it): detect
    `file:` prefix, validate, synthesize result row
  - `playVideoAtIndex:`: branch on `kind` when building the URL
  - `tableView:objectValueForTableColumn:row:` (around line 782):
    skip the thumbnail fetch when `kind=file`
- No proxy changes.
- No other source files.

## Implementation steps

### Step 1 — Extension whitelist + path parser

Add two file-scope helpers near the top of `AppController.m`:

```objective-c
static NSString* const kTTFileScheme = @"file:";

/* Extension whitelist (lowercased, no leading dot).  Sole purpose
   is to catch typos like "file:notes.txt" before we hit the proxy. */
static NSArray* TTAllowedFileExtensions(void) {
    static NSArray* s = nil;
    if (s == nil) {
        s = [[NSArray alloc] initWithObjects:
            @"mp4", @"m4v", @"mov", @"mkv", @"avi",
            @"mpg", @"mpeg", @"webm", @"ogv", @"ogm",
            @"wmv", @"flv", @"ts", @"m2ts", @"mts",
            @"3gp", @"3g2", nil];
    }
    return s;
}

/* If `query` starts with "file:", return the path portion (trimmed).
   Returns nil for non-file queries.  Doesn't validate the extension. */
static NSString* TTParseFilePath(NSString* query) {
    if (![query hasPrefix:kTTFileScheme]) return nil;
    NSString* path = [query substringFromIndex:[kTTFileScheme length]];
    path = [path stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ([path length] > 0) ? path : nil;
}

/* True if `path` ends in one of the whitelisted extensions. */
static BOOL TTIsAllowedFileExtension(NSString* path) {
    NSString* ext = [[path pathExtension] lowercaseString];
    return [TTAllowedFileExtensions() containsObject:ext];
}
```

No `NSRegularExpression` — that's 10.7+. Tiger's Foundation gives us
`pathExtension` and array membership, which is all this needs.

### Step 2 — Short-circuit in `searchAction:`

At the top of `-searchAction:` (after the empty-query guard, before
the `searching = YES` path):

```objective-c
NSString* filePath = TTParseFilePath(query);
if (filePath != nil) {
    [self handleFileSearch:filePath];
    [query release];
    return;
}
```

Then add `-handleFileSearch:`:

```objective-c
- (void)handleFileSearch:(NSString*)filePath {
    if (!TTIsAllowedFileExtension(filePath)) {
        fprintf(stderr,
                "file: rejected \"%s\" (unsupported extension)\n",
                [filePath UTF8String]);
        return;
    }
    fprintf(stderr, "file: accepted \"%s\"\n", [filePath UTF8String]);

    /* Synthesize a single-row result.  Keys match what the table
       data source / playVideoAtIndex: expect, except for the `kind`
       and `filePath` additions. */
    NSString* title = [filePath lastPathComponent];
    NSMutableDictionary* row = [NSMutableDictionary dictionary];
    [row setObject:@"file" forKey:@"kind"];
    [row setObject:filePath forKey:@"filePath"];
    [row setObject:title forKey:@"title"];
    [row setObject:@"(local file)" forKey:@"channelTitle"];
    [row setObject:[NSNumber numberWithInt:0]
            forKey:@"durationSeconds"];
    [row setObject:@"" forKey:@"duration"];

    [results removeAllObjects];
    [results addObject:row];
    [tableView reloadData];
    [tableView scrollRowToVisible:0];
}
```

Do **not** set the `searching` flag or disable the search field —
this path is synchronous and trivial.

### Step 3 — Branch in `playVideoAtIndex:`

Around `AppController.m:820`, just after reading `item`:

```objective-c
NSString* kind = [item objectForKey:@"kind"];
if (kind == nil) kind = @"yt";  /* default, for YouTube rows */
```

Replace the existing URL-building block with:

```objective-c
NSString* vURL;
NSString* aURL;
if ([kind isEqualToString:@"file"]) {
    NSString* path = [item objectForKey:@"filePath"];
    NSString* escaped = [path stringByAddingPercentEscapesUsingEncoding:
                             NSUTF8StringEncoding];
    vURL = [NSString stringWithFormat:
        @"%@/v/file?path=%@&w=%d&h=%d&q=%d&fps=%d&g=%d",
        proxyHost, escaped,
        width, height, qscale,
        TT_VIDEO_FPS, TT_VIDEO_GOP];
    aURL = [NSString stringWithFormat:
        @"%@/a/file?path=%@&rate=%d&ch=%d",
        proxyHost, escaped,
        TT_AUDIO_RATE, TT_AUDIO_CHANNELS];
} else {
    NSString* videoId = [item objectForKey:@"videoId"];
    vURL = [NSString stringWithFormat:
        @"%@/v/yt/%@?w=%d&h=%d&q=%d&fps=%d&g=%d",
        proxyHost, videoId,
        width, height, qscale,
        TT_VIDEO_FPS, TT_VIDEO_GOP];
    aURL = [NSString stringWithFormat:
        @"%@/a/yt/%@?rate=%d&ch=%d",
        proxyHost, videoId,
        TT_AUDIO_RATE, TT_AUDIO_CHANNELS];
}
```

`stringByAddingPercentEscapesUsingEncoding:` is deprecated on later
macOS but is the 10.4-appropriate API — the modern
`stringByAddingPercentEncodingWithAllowedCharacters:` is 10.9+.

The window title currently uses `title` from the row, which for a
file: row is the filename. Good enough — no code change needed.

### Step 4 — Skip thumbnail fetch for file: rows

Around `AppController.m:782`, in the table data source:

```objective-c
NSString* kind = [item objectForKey:@"kind"];
if ([kind isEqualToString:@"file"]) {
    return nil;  /* no thumbnail for local files */
}
NSString* vid = [item objectForKey:@"videoId"];
NSString* url = [item objectForKey:@"thumbnailURL"];
return [thumbCache imageForVideoId:vid url:url];
```

The image cell renders blank for nil — fine for a dev feature.

### Step 5 — Verify no other row-shape assumptions break

Grep `AppController.m` for `objectForKey:@"videoId"` and
`objectForKey:@"thumbnailURL"`. Audit each:

- If the site is reached from the play path, either it's under the
  `kind == "yt"` branch (safe) or it needs a nil-guard.
- If the site is reached from the cell/data-source path, add a
  `kind == "file"` early-return (like Step 4).

Expected hit count after Step 4: 1–2 sites, both safe.

## Validation

Manual, on imacg3 and/or imacg52:

1. **Happy path, relative.** Put a small test clip at
   `<proxy cwd>/test.mp4` on uranium. Type `file:test.mp4` in the
   search field, press Return. Expect a single-row result titled
   `test.mp4`. Click it; it plays.

2. **Happy path, absolute.** `cp` the clip to `/tmp/test.mp4` on
   uranium. Type `file:/tmp/test.mp4`. Same behavior.

3. **Path with spaces.** `cp` it to `/tmp/my test.mp4`. Type
   `file:/tmp/my test.mp4`. Expect the URL in stderr to show
   `%20` for the space, and playback to work.

4. **Wrong extension.** Type `file:notes.txt`. Expect a stderr line
   `file: rejected "notes.txt" (unsupported extension)` and the
   results table unchanged (whatever YouTube results it showed
   before are still visible).

5. **Missing file.** Type `file:/tmp/does-not-exist.mp4`. Expect
   the row to appear (extension is valid), the click to fire, and
   the proxy to respond `404 not a file: …`. TigerTube should log
   the HTTP error and not crash — matches behavior when a YouTube
   stream 404s mid-playback.

6. **Empty / whitespace.** Type `file:` or `file:  `. Expect no row
   added, no stderr error (the query is effectively empty).

7. **Resolution / Quality / VSync respected.** Set Resolution to
   640×480, Quality to 3, VSync on. Play `file:test.mp4`. Confirm
   in stderr (proxy side) that ffmpeg was invoked with `w=640 h=480
   q=3`, and that the client's GL context has swap interval = 1
   (check the `TTPlayerView: vsync=…` line if one exists, or just
   eyeball for tearing).

8. **Switching back.** Do step 1, then type a normal YouTube search.
   Expect the file row to be cleared and replaced with YouTube
   results. No stale state.

9. **Case-insensitive extension.** `file:/tmp/test.MP4` should
   accept.

## What's explicitly NOT in this feature

- No ffprobe-based duration or resolution detection. Duration shows
  as 0; resolution is whatever the user's Resolution popup says, and
  ffmpeg scales the source to fit.
- No thumbnail generation from the source file. The thumbnail cell
  is blank for `file:` rows.
- No recursive directory listing or multi-file mode. One row per
  typed `file:` query.
- No URL shorthand other than `file:`. No `ytdl:`, no `http:`, no
  `rtsp:`. If we ever want those, they're separate features.
- No persistence of recent file paths. Each session starts fresh.
- No config file for the extension whitelist. It's hardcoded.
- No proxy-side allowlist for filesystem paths. The proxy already
  accepts any absolute path via `/v/file`; adding a path-allowlist
  is a separate defense-in-depth concern, not part of this feature.

## Open questions for the implementer

- `ThumbnailCache.imageForVideoId:url:` — does it gracefully handle
  a nil URL, or does it warn / crash? Step 4 sidesteps the question
  by returning nil before the cache is asked, but if a future path
  does hit the cache with a file: row, the audit there becomes
  load-bearing. A one-minute read of `ThumbnailCache.m` while
  implementing Step 4 is worth doing.
- Windowed mode inherits `title` from the row dict. For
  `file:/very/long/path/to/some/deeply/nested/clip.mp4`,
  `lastPathComponent` gives just `clip.mp4`, which is the right call
  for the window title. Keep it that way.
- The proxy logs every file request. Nothing sensitive, but worth
  knowing if the user is testing against a path they'd rather not
  appear in logs.
