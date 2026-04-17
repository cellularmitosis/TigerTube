# User-Overridable YouTube API Key

## Problem

TigerTube currently uses a single hard-coded YouTube Data API key
defined in `Secrets.h` (`.gitignored`, only committed locally).
The Data API v3 gives each key a daily quota of 10,000 "units," and
`search.list` costs **100 units** per call. A shared key would burn
out after ~100 searches across all users — even a handful of users
can exhaust the quota on a busy day.

We want the app to work out-of-the-box with a shared default key, but
let motivated users drop in their own key (which has its own private
10,000-unit quota) so they aren't bottlenecked on the shared pool.

## Solution overview

1. Commit the current key to the repo under a new name
   (`DEFAULT_YOUTUBE_API_KEY`) with a comment explaining its shared
   nature. Delete `Secrets.h` and un-gitignore it.
2. Before every API request, check for an override key at
   `~/.tigertube/youtube-api-key.txt`. Use it if present; fall back
   to the default otherwise.
3. When an API call comes back **403**, inspect the error body:
   - `quotaExceeded` / `dailyLimitExceeded` / `rateLimitExceeded` →
     shared quota is burned. Prompt the user for their own key.
   - `keyInvalid` / `badRequest` with a message about the API key,
     when the *override* file was in use → user's own key is wrong,
     re-prompt with "that key looked invalid" messaging.
   - `keyInvalid` when the *default* was in use → should never happen
     in practice (we control that key), but surface a generic error.
   - Other 403 reasons (`ipRefererBlocked`, `accessNotConfigured`,
     etc.) → log, but don't prompt — these aren't user-fixable by
     pasting a new key in the same form factor.
4. The prompt is an `NSAlert` with an `accessoryView` text field.
   Pasting + clicking "Save Key" writes the key to
   `~/.tigertube/youtube-api-key.txt` (creating `~/.tigertube/`
   with mode 0700 if needed, file with 0600).
5. Whichever UI operation triggered the 403 is abandoned. The user
   retries manually. No auto-retry.

## Design decisions (and rationale)

### Why parse the 403 error body instead of just prompting on any 403

YouTube's 403 covers many distinct situations. Showing the "paste
your own key" dialog for `ipRefererBlocked` or
`accessNotConfigured` would mislead the user — no key they can
paste fixes those. Parse `error.errors[0].reason` and gate the
prompt on the quota-related reasons (and `keyInvalid` when an
override was in use). Log the rest to `stderr`.

### Why a single `isShowingKeyPrompt` flag

A failed search triggers **two** API calls (`search.list` then a
chase `videos.list`), and both can return 403 back-to-back. Without
coalescing you'd stack two `NSAlert` sheets. Guard with a BOOL on
`AppController`; second and subsequent 403s while the prompt is up
become no-ops (just logged).

### Why `NSAlert` + `accessoryView` and not a custom window

10.4-friendly, zero nib surgery, modal run-loop handles focus &
escape automatically. One `NSTextField` (380 pt wide, 22 pt tall)
is enough. Matches Tiger UI conventions.

### Why `YTClient` owns the override-file check, not `AppController`

Keeps all API-key policy in one place. `AppController` passes the
default key into `YTClient` once at init and never thinks about
keys again. `YTClient -currentAPIKey` reads the override file fresh
on each request (cheap — tiny text file, Tiger disk is fine), so
the user can swap keys without restarting the app.

### Why read the override file per-request (no cache)

- Correctness: if the user pastes a new key mid-session, the next
  search picks it up immediately.
- Cost: one `stat` + short read per search. Negligible next to a
  network round-trip to googleapis.com.

### What about thumbnails

`ThumbnailCache` pulls from `i.ytimg.com` — no API key involved. No
changes needed there.

## Files touched

- `Secrets.h` — **delete**
- `.gitignore` — remove the `Secrets.h` line
- `TigerTube.xcodeproj/project.pbxproj` — remove two `Secrets.h`
  entries (PBXFileReference + group membership)
- `AppController.h` — add key-prompt state, delegate conformance
  if needed
- `AppController.m` — replace `#import "Secrets.h"` with an inline
  `#define DEFAULT_YOUTUBE_API_KEY`, add key-prompt handling,
  handle 403 results from search
- `YTClient.h` — change error surface (new out param or accessor),
  add a tiny `YTError`-ish type or status/reason accessors
- `YTClient.m` — implement override-file lookup, expose HTTP status
  + parsed error reason after a failed call

No new files unless you want a one-off `TTKeyPromptController.{h,m}`;
I'd avoid it — the prompt is small enough to inline in
`AppController.m` as a helper method.

## Implementation steps

Do these in order. Each step is independently buildable on imacg3 —
check `ssh imacg3 "cd tmp/TigerTube && xcodebuild -configuration Debug"`
before moving on.

### Step 1 — Inline the default key, delete `Secrets.h`

1. In `AppController.m`, replace the line `#import "Secrets.h"` with:

   ```c
   /* Default YouTube Data API v3 key, shared by all TigerTube users.
      The YouTube Data API gives each key a 10,000 unit/day quota, and
      search.list costs 100 units per call. This key will run out fast
      once TigerTube has more than a handful of users.

      Users who hit the shared quota can create their own free API key
      at https://console.cloud.google.com/ (enable "YouTube Data API
      v3") and drop it into ~/.tigertube/youtube-api-key.txt — TigerTube
      checks that file before every request and uses it when present,
      falling back to this default otherwise. When a 403 comes back,
      the app prompts the user with exactly that instruction. */
   #define DEFAULT_YOUTUBE_API_KEY "xxx"
   ```

2. Update the usage at `AppController.m:114` from `YOUTUBE_API_KEY`
   to `DEFAULT_YOUTUBE_API_KEY`.

3. Delete `Secrets.h`.

4. Remove `Secrets.h` from `.gitignore` (line 8).

5. In `TigerTube.xcodeproj/project.pbxproj`, remove both lines that
   reference `Secrets.h`:
   - The `PBXFileReference` entry (~line 73):
     `2B4C4AA32F850000000001AA /* Secrets.h */ = { ... };`
   - The group-membership entry (~line 191):
     `2B4C4AA32F850000000001AA /* Secrets.h */,`

   Use `Grep` with pattern `Secrets\.h` to confirm no stragglers
   remain.

**Build and run after Step 1.** Search should work exactly as before;
this change is purely a rename + un-ignore.

### Step 2 — `YTClient` owns the key, reads the override file

1. Add a private helper:

   ```objective-c
   /* Returns the contents of ~/.tigertube/youtube-api-key.txt
      (whitespace stripped) if the file exists and is non-empty;
      otherwise returns the default key set at init time. */
   - (NSString*)currentAPIKey;
   ```

   Implementation:
   - Expand `~/.tigertube/youtube-api-key.txt` via
     `stringByExpandingTildeInPath`.
   - Read with
     `+[NSString stringWithContentsOfFile:encoding:error:]`
     (available on 10.4).
   - If the read succeeds, trim with
     `stringByTrimmingCharactersInSet:
       [NSCharacterSet whitespaceAndNewlineCharacterSet]`.
   - If the trimmed string is non-empty, return it. Otherwise return
     the default.

2. In `searchVideos:maxResults:`, replace both in-URL uses of
   `apiKey` (lines ~119 and ~191) with `[self currentAPIKey]`.

3. Rename the `apiKey` ivar to `defaultAPIKey` to make it clear it's
   the fallback, not the effective key.

4. No change to `-initWithAPIKey:caBundlePath:` signature — callers
   still pass the default in.

**Build and run after Step 2.** Drop a test file at
`~/.tigertube/youtube-api-key.txt` containing your personal key
(or garbage, to test the 403 path in Step 4) and confirm the URL
printed on `stderr` (or via tcpdump) uses it.

### Step 3 — `YTClient` surfaces HTTP status + reason on failure

The current `-httpGet:bytes:` swallows 403 as a generic nil return.
We need to bubble the status code and parsed error reason back to
`AppController` so it can decide whether to prompt.

Pick **one** of these shapes; option A is the least invasive.

**Option A — accessor methods on `YTClient`** (recommended):

```objective-c
/* After a failed searchVideos:, these reflect the last HTTP response.
   Both return 0 / nil if the last call succeeded or failed non-HTTP. */
- (int)lastHTTPStatus;
- (NSString*)lastErrorReason;   /* e.g. "quotaExceeded", "keyInvalid" */
- (BOOL)lastErrorUsedOverrideKey; /* true iff the override file was
                                     read successfully for that call */
```

Ivars: `int lastHTTPStatus; NSString* lastErrorReason;
BOOL lastErrorUsedOverrideKey;`.

Reset them at the start of `searchVideos:`. Populate them in
`httpGet:bytes:` on non-200 by parsing the body as JSON and pulling
`error.errors[0].reason`. If JSON parse fails, leave
`lastErrorReason` nil but still record `lastHTTPStatus`.

`lastErrorUsedOverrideKey` is set by having `currentAPIKey` also
set an ivar `currentKeyIsOverride` each time it's called, and
copying that into `lastErrorUsedOverrideKey` on failure.

**Option B — structured error via out param:**

```objective-c
- (NSArray*)searchVideos:(NSString*)query
              maxResults:(int)maxResults
                   error:(NSError**)error;
```

Populate `NSError` with a custom domain (`TigerTubeYTErrorDomain`)
and `userInfo` keys for HTTP status, reason string, and
usedOverrideKey flag. Cleaner but more boilerplate.

Go with **A** unless you want to pull in NSError machinery.

### Step 4 — `AppController` handles 403 and shows the prompt

At the call site for `[client searchVideos:...]` in `AppController.m`
(search the file for it; look near the search-box action handler):

```objective-c
NSArray* results = [client searchVideos:q maxResults:N];
if (results == nil) {
    if ([client lastHTTPStatus] == 403) {
        NSString* reason = [client lastErrorReason];
        BOOL wasOverride = [client lastErrorUsedOverrideKey];
        [self handleAPIKey403WithReason:reason usedOverride:wasOverride];
    } else {
        /* existing nil-result UI path — no change */
    }
    return;
}
```

Then add `-handleAPIKey403WithReason:usedOverride:` on
`AppController`:

1. If `isShowingKeyPrompt` is already YES, return immediately.
   (Coalesce concurrent 403s.)
2. Decide whether this reason warrants the prompt:
   - `quotaExceeded`, `dailyLimitExceeded`, `rateLimitExceeded` → yes
   - `keyInvalid`, `badRequest` (when `usedOverride == YES`) → yes,
     with "that key looked invalid" messaging
   - `keyInvalid` (when `usedOverride == NO`) → fall through to
     generic error (we shipped a broken default — not user-fixable)
   - Anything else → log + generic error
3. If prompting: set `isShowingKeyPrompt = YES`, build and run the
   `NSAlert`, clear the flag before returning.

### Step 5 — The key-prompt `NSAlert`

In `-handleAPIKey403WithReason:usedOverride:`:

```objective-c
NSAlert* alert = [[[NSAlert alloc] init] autorelease];
[alert setMessageText:@"YouTube API quota reached"];

NSString* body;
if (quotaReason) {
    body = @"TigerTube ships with a shared YouTube API key, and "
           @"today's quota has been used up across all users.\n\n"
           @"You can continue searching immediately by creating your "
           @"own free API key:\n"
           @"  1. Go to https://console.cloud.google.com/\n"
           @"  2. Create a project (or pick an existing one)\n"
           @"  3. Enable \"YouTube Data API v3\"\n"
           @"  4. Create an API key under Credentials\n"
           @"  5. Paste it below.\n\n"
           @"Your key is saved to ~/.tigertube/youtube-api-key.txt "
           @"and only used from this machine.";
} else if (keyInvalidReason) {
    body = @"The personal API key at "
           @"~/.tigertube/youtube-api-key.txt was rejected by "
           @"YouTube. Paste a replacement below, or delete that file "
           @"to go back to the shared default key.";
}
[alert setInformativeText:body];

NSTextField* field = [[[NSTextField alloc]
    initWithFrame:NSMakeRect(0, 0, 380, 22)] autorelease];
[[field cell] setScrollable:YES];
[alert setAccessoryView:field];

[alert addButtonWithTitle:@"Save Key"];  /* default, returns NSAlertFirstButtonReturn */
[alert addButtonWithTitle:@"Cancel"];

isShowingKeyPrompt = YES;
int rc = [alert runModal];
isShowingKeyPrompt = NO;

if (rc != NSAlertFirstButtonReturn) return;

NSString* pasted = [[field stringValue]
    stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
if ([pasted length] == 0) return;

[self saveOverrideKey:pasted];
```

### Step 6 — Write the override key safely

Add `-(void)saveOverrideKey:(NSString*)key` on `AppController`:

1. Expand `~/.tigertube` via `stringByExpandingTildeInPath`.
2. Create the dir if missing, mode 0700, via
   `-[NSFileManager createDirectoryAtPath:attributes:]` with
   attribute dict `@{ NSFilePosixPermissions: @(0700) }`.
   (Use the old `createDirectoryAtPath:attributes:` — the
   `withIntermediateDirectories:` version is 10.5+.)
3. Write the file at `~/.tigertube/youtube-api-key.txt` via
   `-[NSString writeToFile:atomically:encoding:error:]` (10.4+).
4. Chmod the file to 0600 via
   `-[NSFileManager changeFileAttributes:atPath:]`.
5. Log success on stderr: `"api key: saved override key (%zu bytes)"`.
6. On any failure, log and show a second `NSAlert` with the error.
   No retry loop.

**Do not** print the key bytes to stderr — ever.

### Step 7 — Sweep for stragglers

After Steps 1–6 land and build:

1. `Grep` for `YOUTUBE_API_KEY` and `Secrets\.h` in the repo. Only
   expected hits: `DEFAULT_YOUTUBE_API_KEY` in `AppController.m`
   and this plan doc. Anything else (docs, README, release notes)
   should be updated.
2. Confirm the Debug build is clean on imacg3 and `run_and_log.sh`
   produces a working search.
3. `git status` should show `Secrets.h` deleted, not "untracked" —
   since it was .gitignored, it lived outside git. After removing
   the `.gitignore` entry, git won't spontaneously track a missing
   file; that's fine.

## Validation

Manual, on imacg3:

1. **Default-key path.** No `~/.tigertube/` on the imacg3. Search
   works as before. stderr shows the default key in URLs.
2. **Override path.** Drop your real key at
   `~/.tigertube/youtube-api-key.txt`. Search works. stderr URLs
   contain the override key, not the default.
3. **Whitespace tolerance.** Add trailing newlines + leading spaces
   to the override file. Still works.
4. **Empty override file.** Override file exists but is empty.
   Falls back to default.
5. **Quota 403.** Hardest to induce naturally. Simplest: use `curl`
   on the laptop to blow the default key's quota (run `search.list`
   100× in a row), then do a search in TigerTube. Expect the quota
   dialog. Paste a fresh key. Confirm
   `~/.tigertube/youtube-api-key.txt` contains it (and is 0600).
   Confirm the next search succeeds.
6. **Invalid-override 403.** Put garbage in the override file.
   Search. Expect the "that key looked invalid" variant of the
   dialog.
7. **Coalescing.** Both `search.list` and the chase `videos.list`
   should fail with 403 on a quota miss, but only one dialog pops.
   (If the chase succeeds, the search already returned data — the
   coalesce case is when *both* fail.)

## What's explicitly NOT in this feature

- No auto-retry of the UI operation after a key is saved. User
  retries their search manually.
- No UI in Preferences/Menu for managing the override key. File on
  disk is the source of truth; we only *write* it via the prompt,
  and we never read or display an existing key (for paranoia —
  keeps pasted keys off the screen on subsequent launches).
- No background quota watchdog — we react to 403s only.
- No change to thumbnail fetches (they don't use the API).
- No migration of existing `Secrets.h` contents for users on
  imacg3; the default key's value is the same as what's currently
  in their local `Secrets.h`, so they'll see no behavior change.

## Open questions for the implementer

- The pbxproj has two UUIDs referring to `Secrets.h`. Plain text
  deletion of both lines should be sufficient, but re-open the
  project in Xcode on imacg3 after the edit to confirm no
  "missing file" warning surfaces.
- The exact copy of the dialog body is a first draft — feel free
  to tighten. Keep it short; Tiger's `NSAlert` wraps aggressively.
