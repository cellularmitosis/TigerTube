# api-key-override — postmortem

Shipped 2026-04-16 / 2026-04-17 against
[`plan.md`](plan.md).

## What shipped vs. the plan

Two deviations from the plan. The first is flagged in the plan doc's
preamble; the second is new here.

### Step 1 — `Secrets.h` pattern was kept, not replaced

**Plan:** Inline the default key as a `#define DEFAULT_YOUTUBE_API_KEY`
directly in `AppController.m`, delete `Secrets.h`, un-gitignore it,
and remove its two entries from `TigerTube.xcodeproj/project.pbxproj`.

**Shipped:** `Secrets.h` stayed (gitignored) and continues to provide
`YOUTUBE_API_KEY`. `AppController.m` still `#import`s it. Everything
else about Step 1 — renaming the define, wiring it through to
`YTClient.initWithAPIKey:` — applies to the kept file instead.

### Step 4 — `NSAlert` + `setAccessoryView:` → custom modal `NSWindow`

**Plan:** Present the key prompt as an `NSAlert` with an
`accessoryView` text field.

**Shipped:** `-[NSAlert setAccessoryView:]` is 10.5+; it does not exist
in the 10.4 AppKit symbol table (confirmed via `otool -ov` on Tiger's
AppKit binary). `runKeyPromptWithTitle:body:` in `AppController.m`
builds a plain titled `NSWindow` with a wrapped body label, text
field, and Save/Cancel buttons, and drives it via
`-[NSApp runModalForWindow:]`. Button actions stop the modal with
codes 1 (Save) and 0 (Cancel); the method returns the pasted string
or `nil`. Visually close enough to an alert that users shouldn't
notice the difference.

## What went well

- **Module split was accurate.** `YTClient` owns key resolution
  (default + override-file lookup) and error parsing (`lastHTTPStatus`
  / `lastErrorReason` / `lastErrorUsedOverrideKey`); `AppController`
  owns the 403 dispatch to the modal. No race conditions during
  bring-up.
- **Parsing `error.errors[0].reason`** turned out to be the right
  granularity for deciding whether to surface the prompt
  (`quotaExceeded` / `dailyLimitExceeded` / `rateLimitExceeded` /
  `keyInvalid` when override was in use) vs. just logging
  (`ipRefererBlocked` / `accessNotConfigured` / etc.).
- **`isShowingKeyPrompt` coalescing** earned its keep on the first
  real 403: a single failed search fires both `search.list` and
  `videos.list`, both return 403 back-to-back, and without the flag
  the prompt would have stacked two modals.

## Surprises

- **10.4 NSFileManager directory-create signature.** The plan
  implicitly assumed the modern
  `createDirectoryAtPath:withIntermediateDirectories:attributes:error:`,
  which is 10.5+. Tiger is `createDirectoryAtPath:attributes:` (no
  intermediates, no error-out). Compiler flagged the mismatch; easy
  fix.
- **`NSFilePosixPermissions` expects an `NSNumber`.** Passing an
  integer literal typechecks (it's an `id` dict value) but
  `NSFileManager` silently ignores it. Wrap in
  `[NSNumber numberWithInt:0600]`. Caught at runtime when the
  created file came out world-readable.

## What to do differently next time

- **Spot-check AppKit 10.5-only APIs during planning, not during
  implementation.** `-[NSAlert setAccessoryView:]` would have been
  caught by a quick grep against the Tiger AppKit header (or the
  `leopard-adc-docs` availability markers) before the plan shipped.
  A one-line availability check per Cocoa call in the plan is cheap
  insurance.
- **Run `-[NSFileManager]` calls against the 10.4 class reference
  before typing, not after.** Same skill, same cost. The directory-
  create + `NSFilePosixPermissions` gotchas are both documented in
  the Tiger reference if you look them up first.
