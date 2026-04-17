---
name: leopard-adc-docs
description: Access to a local mirror of Apple's July 2009 ADC Reference Library — the full HTML documentation set from the last Leopard-era ADC DVD, including the complete Cocoa / Carbon / Foundation / AppKit API reference, 1,400+ Apple sample projects, conceptual programming guides, release notes, technical notes/Q&As, and — crucially for 10.4 work — the Objective-C 1.0 Programming Language book (OOPandObjC1) and Objective-C 1.0 Runtime Reference (ObjCRuntimeRef1). Consult this skill whenever the task involves Cocoa / Carbon / AppKit / Foundation / Objective-C development for Mac OS X 10.4 Tiger or 10.5 Leopard, looking up "is method X available on 10.4", finding canonical Apple sample code for an API, reading the ObjC 1.0 runtime spec, or when current developer.apple.com docs have removed a deprecated API (QuickTime, Carbon Events, old printing, pre-block Cocoa idioms). Pairs with `imacg3-dev` — if the target is imacg3, read that too.
---

# Leopard ADC Reference Library (July 2009)

A local mirror of the full Apple Developer Connection Reference Library as of July 2009. It's the last Apple-published HTML doc set to cover the pre-ObjC-2.0 world with first-class status — 10.5 Leopard is the "current" OS, 10.4 Tiger is still a first-class target for most docs, and the legacy material Apple has since deleted from developer.apple.com (QuickTime, Carbon Events, old printing, pre-block Cocoa patterns) is all still present.

## Three ways to reach it

The docs live on a Linux host named `files` on the local network, and are also published via github.io and a plain HTTP mirror (the latter so that actual PowerPC Macs with ancient Safari can reach them).

| Access | Use when |
|---|---|
| **`ssh files '...'`** — path: `/mnt/F/github/cellularmitosis/ADC-reference-library-2009-july` | **Default.** Remote grep is fast; only hits come back over the wire. Use for any search. Key is in `authorized_keys`, no password prompt. |
| **`WebFetch https://leopard-adc.pepas.com/<path>`** | You already know the exact path and want to read one page. Plain HTTP mirror (also works from imacg3 via old Safari). |
| **`https://github.com/cellularmitosis/ADC-reference-library-2009-july`** | Sharing URLs with humans, or `git clone` for offline use. |

The path tail after `ADC-reference-library-2009-july/` on the ssh host is the **same** as the URL path on pepas.com. So `documentation/Cocoa/Reference/Foundation/Classes/NSString_Class/Reference/NSString.html` → `https://leopard-adc.pepas.com/documentation/Cocoa/Reference/Foundation/Classes/NSString_Class/Reference/NSString.html`.

## The two master flat indexes

These are the single most useful files in the whole library, because they're flat lists of (almost) every doc with grep-able titles in one HTML file each.

```
referencelibrary/index-date0.html                   # "everything" index
    47k lines, 7,310 links. Every current-in-2009 doc in the library.
    First grep target for topic discovery.

referencelibrary/LegacyTechnologies/index-date0.html  # "legacy" index  
    23k lines, 3,244 links. Everything Apple had demoted to "legacy" by 2009.
```

**Counterintuitive but important:** for a Tiger developer, the **legacy** index is often the *better* starting point. "Legacy in 2009" is a strong proxy for "pre-ObjC-2.0, pre-Leopard-framework-redesign, written in the Tiger era." The two Tiger-gold documents — the ObjC 1.0 Language book and the ObjC 1.0 Runtime Reference — are **only** in the legacy index. So are tutorials with `104` suffixes (Tiger-targeted versions), Carbon managers, and pre-block Cocoa idioms.

Canonical two-tier grep pattern:

```bash
ssh files 'cd /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july && \
  grep -i "<topic>" referencelibrary/index-date0.html; \
  echo ---; \
  grep -i "<topic>" referencelibrary/LegacyTechnologies/index-date0.html'
```

## Key entry points

| What | Path |
|---|---|
| **ObjC 1.0 Programming Language book** | `documentation/Cocoa/Conceptual/OOPandObjC1/index.html` (+ `.pdf`) |
| **ObjC 1.0 Runtime Reference** | `documentation/Cocoa/Reference/ObjCRuntimeRef1/index.html` (+ `.pdf`) |
| Foundation class list (ObjC) | `documentation/Cocoa/Reference/Foundation/ObjC_classic/index.html` (201 links) |
| AppKit class list (ObjC) | `documentation/Cocoa/Reference/ApplicationKit/ObjC_classic/index.html` |
| Foundation functions | `documentation/Cocoa/Reference/Foundation/Miscellaneous/Foundation_Functions/Reference/reference.html` |
| Foundation data types | `documentation/Cocoa/Reference/Foundation/Miscellaneous/Foundation_DataTypes/Reference/reference.html` |
| Foundation constants | `documentation/Cocoa/Reference/Foundation/Miscellaneous/Foundation_Constants/Reference/reference.html` |
| AppKit functions | `documentation/Cocoa/Reference/ApplicationKit/Miscellaneous/AppKit_Functions/Reference/reference.html` |
| "What's New in Mac OS X" (= inverse-whitelist for Tiger) | `releasenotes/MacOSX/WhatsNewInOSX/WhatsNewInOSX.html` (+ `.pdf`) |
| Sample code root | `samplecode/<ProjectName>/` — each has `index.html`, `listing*.html`, and the original `.zip`/`.dmg` |
| Root curated index (human-browsable) | `/index.html` — also https://leopard-adc.pepas.com/ |

### Class reference path convention

Individual class docs follow a strict pattern:

```
documentation/Cocoa/Reference/<Framework>/Classes/<ClassName>_Class/Reference/<ClassName>.html
```

For example, `NSString` is at `documentation/Cocoa/Reference/Foundation/Classes/NSString_Class/Reference/NSString.html`. Same shape for protocols (`_Protocol` suffix) and categories. Once you know the class name you can jump directly to its reference page without going through any index.

## Filtering for Tiger: the availability-marker grep trick

Every per-method section in a class reference has a consistent availability marker. Exact strings that appear:

```
Available in Mac OS X v10.0 and later.
Available in Mac OS X v10.0 through Mac OS X v10.4.
Available in Mac OS X v10.2 and later.
Available in Mac OS X v10.3 and later.
Available in Mac OS X v10.4 and later.
Available in Mac OS X v10.5 and later.     ← not on Tiger
```

To check "is this method available on Tiger?" grep the class's reference HTML for the method name plus nearby context:

```bash
ssh files 'grep -n -B1 -A3 "mySelector" \
  /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/documentation/Cocoa/Reference/Foundation/Classes/NSString_Class/Reference/NSString.html'
```

Anything marked `10.5 and later` or `10.6` is off-limits for Tiger. `10.0`/`10.1`/`10.2`/`10.3`/`10.4 and later` is fine. `10.0 through 10.4` is Tiger-only and has been removed.

NSString alone has 125 availability markers; this filtering scales to any Cocoa class.

## The inverse whitelist: WhatsNewInOSX.html

`releasenotes/MacOSX/WhatsNewInOSX/WhatsNewInOSX.html` is Apple's own list of what's new in 10.5 Leopard. For Tiger work, **every API mentioned there is off-limits** — it's a concrete list of things to steer away from. Read it once at the start of a new Cocoa-on-Tiger project and you'll skip a lot of dead ends. In particular it enumerates Core Animation, `NSOperationQueue`, Garbage Collection, most ObjC 2.0 features at the framework level, Objective-C Garbage Collection, FSEvents, DTrace, and the Leopard AppKit additions.

## Sample code: 1,431 Apple projects

```
samplecode/<ProjectName>/
    <ProjectName>/     # UNPACKED source tree — raw .h / .m / .xcodeproj etc.
    index.html         # description + file listing + "What's New" dates
    listing1.html, listing2.html, ...  # source files inlined as HTML for browsing
    images/            # screenshots
    <ProjectName>.zip  # original archive
    <ProjectName>.dmg  # original disk image
```

**Every `.zip` has been pre-unpacked into a sibling subdirectory.** That means the raw `.h` / `.m` / `.xcodeproj` files are sitting right there as plain files — you do **not** need to `scp` the zip down and unpack it locally, and you do **not** need to parse the HTML-escaped `listing*.html` files. Just grep the unpacked tree directly, which gives clean source hits with no HTML tag noise.

To search across all 1,431 samples for an API usage pattern, filter the grep to `.h`/`.m` files so you only hit real source:

```bash
# Which samples use NSTableViewDataSource? (clean source-only hits)
ssh files 'grep -rl --include="*.[hm]" "NSTableViewDataSource" \
  /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/samplecode/ 2>/dev/null | head'

# Read a specific file directly (no unpack step):
ssh files 'cat /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/samplecode/CALayerEssentials/CALayerEssentials/AppController.m'
```

If you want the whole unpacked tree for one sample on the main Mac for editing/building:

```bash
rsync -a files:/mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/samplecode/<Name>/<Name>/ ./<Name>/
# (note the doubled path component — outer dir vs the unpacked inner dir)
```

No need to `scp` the `.zip` and unpack it — the inner subdirectory **is** the unpack.

Tiger-safety rules of thumb for samples:

- Samples whose `listing*.html` contains `@property`, `@synthesize`, `for (.* in .*)`, `instancetype`, `@[`, `@{`, `^{`, `dispatch_`, `CALayer`, `NSOperationQueue`, `@autoreleasepool` → need backport work (see notes on ObjC 2.0→1.0 transforms if pairing with the `imacg3-dev` workflow)
- Samples whose `index.html` mentions the revision history dating back to 10.4 or earlier → usually Tiger-clean
- When in doubt, pull down `<Name>.zip` with `scp files:<path> .`, unpack locally, and try to build with `gcc-4.0` + `MacOSX10.4u.sdk` — compiler errors tell you the rest

## The legacy technologies section: what's actually in there

Worth knowing about specifically because Apple has removed most of this from developer.apple.com:

- **Objective-C 1.0** — `OOPandObjC1/` (language book) and `ObjCRuntimeRef1/` (runtime reference)
- **Carbon managers** — Dictionary Manager, Appearance Manager, Drag Manager, Resource Manager, Event Manager (Carbon Events), Apple Event Manager, etc. First-class docs for Carbon APIs that are gone or severely deprecated in modern macOS but fully supported on Tiger.
- **Pre-block Cocoa tutorials** — `NSPersistentDocumentTutorial104`, others with `104` suffixes
- **QuickTime** — essentially all of it. Apple has deleted QuickTime docs from their current site; this is one of the few places to still get the real API reference.
- **Classic Cocoa bindings / controller** idioms that predate blocks-based APIs
- **CoreAudio** reference (`MusicAudio/Reference/CoreAudio`)
- **WebObjects** 3.5/4.0/4.5

If you're writing code for Tiger and an API feels "vintage" in a way the current developer.apple.com site doesn't describe well, the legacy index is where to look first.

## Workflow example: "I need to use `NSTask` on Tiger, does it work there?"

```bash
# 1. Jump straight to the class ref via the path convention.
ssh files 'grep -H "Available in Mac OS X" \
  /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/documentation/Cocoa/Reference/Foundation/Classes/NSTask_Class/Reference/Reference.html' \
  | head

# 2. If the class itself is pre-10.5, grep for specific methods to confirm each one is Tiger-safe.
ssh files 'grep -B1 -A2 "launchedTaskWithLaunchPath" \
  /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/documentation/Cocoa/Reference/Foundation/Classes/NSTask_Class/Reference/Reference.html'

# 3. Find Apple sample code that uses it.
ssh files 'grep -lr "NSTask" \
  /mnt/F/github/cellularmitosis/ADC-reference-library-2009-july/samplecode/ 2>/dev/null | head -5'

# 4. Read one of the hits in full.
WebFetch https://leopard-adc.pepas.com/samplecode/<HitName>/index.html
```

## tl;dr cheat sheet

```
Host (ssh):     files:/mnt/F/github/cellularmitosis/ADC-reference-library-2009-july
HTTP mirror:    https://leopard-adc.pepas.com/
GitHub:         https://github.com/cellularmitosis/ADC-reference-library-2009-july

Master indexes (grep these first):
  referencelibrary/index-date0.html                   # 7,310 current docs
  referencelibrary/LegacyTechnologies/index-date0.html  # 3,244 legacy (= often Tiger-era)

Tiger-gold ObjC 1.0 material (both in LegacyTechnologies):
  documentation/Cocoa/Conceptual/OOPandObjC1/           # language book
  documentation/Cocoa/Reference/ObjCRuntimeRef1/         # runtime reference

Framework class lists:
  documentation/Cocoa/Reference/Foundation/ObjC_classic/index.html
  documentation/Cocoa/Reference/ApplicationKit/ObjC_classic/index.html

Class ref path convention:
  documentation/Cocoa/Reference/<Fwk>/Classes/<Name>_Class/Reference/<Name>.html

Availability filter:
  grep "Available in Mac OS X v10\.[0-4]"    # Tiger-safe
  grep "Available in Mac OS X v10\.5"        # NOT on Tiger

Inverse whitelist (things to avoid on Tiger):
  releasenotes/MacOSX/WhatsNewInOSX/WhatsNewInOSX.html

Sample code (1,431 projects):
  samplecode/<Name>/<Name>/       # UNPACKED source tree — raw .h/.m, grep directly
  samplecode/<Name>/index.html    # description
  samplecode/<Name>/*.zip, *.dmg  # original archives (don't need these — already unpacked)
  grep -rl --include="*.[hm]" "<api>" samplecode/   # find canonical usage in source
```
