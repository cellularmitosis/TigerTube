//
//  AppController.m
//  TigerTube
//

#import "AppController.h"
#import "YTClient.h"
#import "NSString+.h"
#import "ResultCell.h"
#import "TTPlayerWindowController.h"
#import "Secrets.h"
#include <curl/curl.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* -[NSNetService port] isn't declared in the 10.4 SDK (added in 10.5),
   so pull the port out of the first resolved address instead -- each
   element of [service addresses] is an NSData wrapping a sockaddr. */
static int ttPortFromNetService(NSNetService* service) {
    NSArray* addrs = [service addresses];
    if ([addrs count] == 0) {
        return 0;
    }
    NSData* data = [addrs objectAtIndex:0];
    const struct sockaddr* sa = (const struct sockaddr*)[data bytes];
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in* sin = (const struct sockaddr_in*)sa;
        return (int)ntohs(sin->sin_port);
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6* sin6 = (const struct sockaddr_in6*)sa;
        return (int)ntohs(sin6->sin6_port);
    }
    return 0;
}

/* Vertically-center a non-bezeled NSTextField label within a control
   row of height rowH.  Needed because a plain NSTextField draws text
   at the top of its frame, while adjacent NSPopUpButtons (and bezeled
   text fields) vertically-center their text -- so shared frames leave
   the label text floating above the popup's title.  sizeToFit picks
   the label's natural height, then we re-center the frame within the
   row while preserving the caller's allocated label width. */
static void ttCenterLabelInRow(NSTextField* label, float rowY, float rowH,
                               float keepWidth) {
    [label sizeToFit];
    NSSize sz = [label frame].size;
    float x = [label frame].origin.x;
    [label setFrame:NSMakeRect(x,
                               rowY + (rowH - sz.height) / 2.0f,
                               keepWidth,
                               sz.height)];
}

/* Transcode parameters sent to the proxy.  Tuned for 320x240 @ 24fps
   playback on a 600 MHz iMac G3 without AltiVec -- the decoder has
   ~11x realtime headroom at these settings.

   TT_VIDEO_QSCALE selects constant-quality VBR (ffmpeg -q:v).  Range
   is 2-31 for MPEG-1, lower = better.  Preferred over bitrate mode
   on a wired LAN where bandwidth isn't the constraint -- avoids the
   pixelation spikes that a CBR target produces on high-motion frames. */
static const int TT_VIDEO_WIDTH    = 320;
static const int TT_VIDEO_HEIGHT   = 240;
static const int TT_VIDEO_QSCALE   = 2;      /* 2-31, lower=better */
static const int TT_VIDEO_FPS      = 24;
static const int TT_VIDEO_GOP      = 12;     /* I-frame every 0.5s at 24fps */
static const int TT_AUDIO_RATE     = 44100;  /* Hz */
static const int TT_AUDIO_CHANNELS = 2;

/* "file:<path>" search prefix -- a developer back door that skips
   YouTube entirely and streams a local file on the proxy host through
   the existing transcode pipeline.  The extension whitelist lives
   server-side in the proxy's _resolve_file_source (a mistyped or
   malicious path is rejected with HTTP 400 rather than passed through
   to ffmpeg).  See docs/features/file-source/. */
static NSString* const kTTFileScheme = @"file:";

/* If `query` starts with "file:", return the path portion (trimmed).
   Returns nil for non-file queries or an empty path. */
static NSString* TTParseFilePath(NSString* query) {
    if (![query hasPrefix:kTTFileScheme]) return nil;
    NSString* path = [query substringFromIndex:[kTTFileScheme length]];
    path = [path stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ([path length] > 0) ? path : nil;
}

@interface AppController (Private)
- (void)buildWindow;
- (void)performSearchInBackground:(NSString*)query;
- (void)searchDidFinish:(NSArray*)newResults;
- (void)handleFileSearch:(NSString*)filePath;
- (int)rowIndexForVideoId:(NSString*)videoId;
- (void)playVideoAtIndex:(int)index;
- (void)handleAPIKey403WithReason:(NSString*)reason
                     usedOverride:(BOOL)usedOverride;
- (void)saveOverrideKey:(NSString*)key;
- (NSString*)runKeyPromptWithTitle:(NSString*)title body:(NSString*)body;
- (void)keyPromptSave:(id)sender;
- (void)keyPromptCancel:(id)sender;
@end

@implementation AppController

- (id)init {
    self = [super init];
    if (self != nil) {
        results = [[NSMutableArray alloc] init];
        searching = NO;
        isShowingKeyPrompt = NO;
        playerController = nil;
        /* Fallback proxy host -- used if Bonjour discovery doesn't
           find one in time.  Will be replaced once a proxy is resolved.
           Deliberately set to a non-responsive IP so a failed discovery
           is obvious rather than silently working via the hardcoded one. */
        proxyHost = [@"http://192.168.1.2:5002" retain];
        proxyDiscovered = NO;
        proxyBrowser = nil;
        resolving = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [playerController release];
    [proxyHost release];
    [proxyBrowser stop];
    [proxyBrowser setDelegate:nil];
    [proxyBrowser release];
    {
        NSEnumerator* e = [resolving objectEnumerator];
        NSNetService* svc;
        while ((svc = [e nextObject]) != nil) {
            [svc stop];
            [svc setDelegate:nil];
        }
    }
    [resolving release];
    [client release];
    [thumbCache release];
    [results release];
    [window release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification*)note {
    fprintf(stderr, "=== TigerTube launched (build %s %s) ===\n", __DATE__, __TIME__);
    curl_global_init(CURL_GLOBAL_DEFAULT);

    NSString* caPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (caPath == nil) {
        fprintf(stderr, "FATAL: cacert.pem not found in bundle\n");
        [NSApp terminate:nil];
        return;
    }

    NSString* apiKey = [NSString stringWithUTF8String:YOUTUBE_API_KEY];
    client = [[YTClient alloc] initWithAPIKey:apiKey caBundlePath:caPath];
    if (client == nil) {
        fprintf(stderr, "FATAL: YTClient init failed\n");
        [NSApp terminate:nil];
        return;
    }

    thumbCache = [[ThumbnailCache alloc] initWithCABundlePath:caPath];
    if (thumbCache == nil) {
        fprintf(stderr, "FATAL: ThumbnailCache init failed\n");
        [NSApp terminate:nil];
        return;
    }
    [thumbCache setDelegate:self];

    [self buildWindow];

    /* Start Bonjour discovery for a proxy on the LAN.  Runs async on the
       main run loop; the first resolved service replaces proxyHost. */
    proxyBrowser = [[NSNetServiceBrowser alloc] init];
    [proxyBrowser setDelegate:self];
    [proxyBrowser searchForServicesOfType:@"_tigertube-proxy._tcp."
                                 inDomain:@"local."];
    fprintf(stderr, "proxy: bonjour browse started (fallback=%s)\n",
            [proxyHost UTF8String]);
}

- (void)buildWindow {
    unsigned int style = NSTitledWindowMask
                       | NSClosableWindowMask
                       | NSMiniaturizableWindowMask
                       | NSResizableWindowMask;

    /* Create with a placeholder content rect, then resize the outer frame
     * to the screen's visibleFrame (screen bounds minus menu bar & Dock).
     * Going through setFrame: keeps the title bar under the menu bar
     * instead of hidden behind it. */
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setFrame:[[NSScreen mainScreen] visibleFrame] display:NO];
    [window setTitle:@"TigerTube"];
    /* 900: fits the controls row at its minimum layout (margins +
       tightened labels + five popup/checkbox groups + drops label).
       Any narrower and the drops-frames label clips -- harmless
       since it's hidden until drops > 0, but annoying for debugging. */
    [window setMinSize:NSMakeSize(900, 400)];
    [window setReleasedWhenClosed:NO];

    NSView* content = [window contentView];
    NSRect cb = [content bounds];
    float margin = 10.0f;

    /* Search field -- bigger-than-default font so the query is
       readable from across the room.  Field height grows to match.

       Using plain NSTextField rather than NSSearchField: Tiger's aqua
       search-bar chrome is drawn at a fixed height and doesn't scale
       with the font, so a doubled-font NSSearchField ends up with its
       white text cell spilling out past the rounded bezel.  A plain
       bezeled NSTextField scales cleanly to any size. */
    float searchFontSize = [NSFont smallSystemFontSize] * 2.0f;
    float searchH = searchFontSize + 12.0f;

    /* Search field -- top.  Matches the labeled-popup pattern used by
       the controls row below: a static "Search:" label on the left and
       the field filling the rest of the row.  NSTextFieldCell's
       -setPlaceholderString: is a no-op at draw time on 10.4 for a
       plain NSTextField (it's documented to work, but AppKit only
       renders the placeholder for NSSearchFieldCell on Tiger), so we
       spell the prompt out as a sibling label instead. */
    float searchLabelW = 100.0f;
    NSRect searchLabelFrame = NSMakeRect(margin,
                                         cb.size.height - margin - searchH,
                                         searchLabelW,
                                         searchH);
    NSTextField* searchLabel = [[NSTextField alloc]
                                     initWithFrame:searchLabelFrame];
    [searchLabel setStringValue:@"Search:"];
    [searchLabel setFont:[NSFont systemFontOfSize:searchFontSize]];
    [searchLabel setBezeled:NO];
    [searchLabel setDrawsBackground:NO];
    [searchLabel setEditable:NO];
    [searchLabel setSelectable:NO];
    [searchLabel setAutoresizingMask:NSViewMinYMargin];
    ttCenterLabelInRow(searchLabel, cb.size.height - margin - searchH,
                       searchH, searchLabelW);
    [content addSubview:searchLabel];
    [searchLabel release];

    NSRect searchFrame = NSMakeRect(margin + searchLabelW,
                                    cb.size.height - margin - searchH,
                                    cb.size.width - 2 * margin - searchLabelW,
                                    searchH);
    NSTextField* sf = [[NSTextField alloc] initWithFrame:searchFrame];
    [sf setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [sf setFont:[NSFont systemFontOfSize:searchFontSize]];
    [sf setBezeled:YES];
    [sf setBezelStyle:NSTextFieldSquareBezel];
    [sf setDrawsBackground:YES];
    [sf setEditable:YES];
    [sf setSelectable:YES];
    [sf setTarget:self];
    [sf setAction:@selector(searchAction:)];
    /* NSTextField fires its action on commit (Return / end-editing),
       which is exactly what we want -- no per-keystroke fire. */
    [content addSubview:sf];
    searchField = sf;    /* weak: retained by superview */
    [sf release];

    /* Controls row -- below search field, above table.  Labels + popups
       for resolution and quality, all left-justified on the same line. */
    float controlsH = 26.0f;
    float rowY = cb.size.height - 2 * margin - searchH - controlsH;
    float x = margin;

    float resLabelW = 72.0f;
    NSTextField* resLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(x, rowY, resLabelW, controlsH)];
    [resLabel setStringValue:@"Resolution:"];
    [resLabel setBezeled:NO];
    [resLabel setDrawsBackground:NO];
    [resLabel setEditable:NO];
    [resLabel setSelectable:NO];
    [resLabel setAutoresizingMask:NSViewMinYMargin];
    ttCenterLabelInRow(resLabel, rowY, controlsH, resLabelW);
    [content addSubview:resLabel];
    [resLabel release];
    x += resLabelW;

    float resPopW = 150.0f;
    NSPopUpButton* resPop = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(x, rowY, resPopW, controlsH)];
    [resPop addItemsWithTitles:[NSArray arrayWithObjects:
        @"192x144", @"256x192", @"320x240", @"384x288",
        @"448x336", @"512x384", @"576x432", @"640x480",
        @"704x528", @"768x576", @"832x624", @"896x672",
        @"960x720", @"1024x768", @"1088x816", @"1152x864",
        @"1216x912", @"1280x960", @"1344x1008", nil]];
    [resPop selectItemWithTitle:@"320x240"];
    [resPop setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:resPop];
    resolutionPopup = resPop; /* weak: retained by superview */
    [resPop release];
    x += resPopW + 16.0f; /* gap before next label */

    float qLabelW = 48.0f;
    NSTextField* qLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(x, rowY, qLabelW, controlsH)];
    [qLabel setStringValue:@"Quality:"];
    [qLabel setBezeled:NO];
    [qLabel setDrawsBackground:NO];
    [qLabel setEditable:NO];
    [qLabel setSelectable:NO];
    [qLabel setAutoresizingMask:NSViewMinYMargin];
    ttCenterLabelInRow(qLabel, rowY, controlsH, qLabelW);
    [content addSubview:qLabel];
    [qLabel release];
    x += qLabelW;

    float qPopW = 60.0f;
    NSPopUpButton* qPop = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(x, rowY, qPopW, controlsH)];
    [qPop addItemsWithTitles:[NSArray arrayWithObjects:
        @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", nil]];
    [qPop selectItemWithTitle:@"2"];
    [qPop setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:qPop];
    qualityPopup = qPop; /* weak: retained by superview */
    [qPop release];
    x += qPopW + 16.0f;

    /* Framerate popup.  "Source" (default) tells the proxy to omit
       the fps= CFR filter so frames pass through at the source's
       native rate.  Numeric rates are downconversion targets for
       high-fps content: 24 generic cap, 25 = 50/2 PAL halving,
       30 = 60/2 desktop-capture halving.  See
       docs/features/framerate-popup/plan.md. */
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

    float fpsPopW = 85.0f;
    NSPopUpButton* fpsPop = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(x, rowY, fpsPopW, controlsH)];
    [fpsPop addItemsWithTitles:[NSArray arrayWithObjects:
        @"Source", @"24", @"25", @"30", nil]];
    [fpsPop selectItemWithTitle:@"Source"];
    [fpsPop setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:fpsPop];
    fpsPopup = fpsPop; /* weak: retained by superview */
    [fpsPop release];
    x += fpsPopW + 16.0f;

    /* VSync label + checkbox.  Read at play time and passed to the
       player's GL context; off (default) matches prior behavior. */
    float vsLabelW = 44.0f;
    NSTextField* vsLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(x, rowY, vsLabelW, controlsH)];
    [vsLabel setStringValue:@"VSync:"];
    [vsLabel setBezeled:NO];
    [vsLabel setDrawsBackground:NO];
    [vsLabel setEditable:NO];
    [vsLabel setSelectable:NO];
    [vsLabel setAutoresizingMask:NSViewMinYMargin];
    ttCenterLabelInRow(vsLabel, rowY, controlsH, vsLabelW);
    [content addSubview:vsLabel];
    [vsLabel release];
    x += vsLabelW;

    float vsBoxW = 20.0f;
    NSButton* vsBox = [[NSButton alloc] initWithFrame:
        NSMakeRect(x, rowY, vsBoxW, controlsH)];
    [vsBox setButtonType:NSSwitchButton];
    [vsBox setTitle:@""];
    [vsBox setState:NSOffState];
    [vsBox setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:vsBox];
    vsyncCheckbox = vsBox; /* weak: retained by superview */
    [vsBox release];
    x += vsBoxW + 16.0f;

    /* Crop toggle -- when checked, adds ?crop=auto to the video URL
       so the proxy runs cropdetect and strips baked pillarbox /
       letterbox bars from the source.  Off by default because the
       probe adds 1-2 s to first-frame latency.  Uses the checkbox's
       own title rather than a sibling NSTextField (one less widget,
       and puts the label in the button's hit area). */
    float cropBoxW = 62.0f;
    NSButton* cropBox = [[NSButton alloc] initWithFrame:
        NSMakeRect(x, rowY, cropBoxW, controlsH)];
    [cropBox setButtonType:NSSwitchButton];
    [cropBox setTitle:@"Crop"];
    [cropBox setState:NSOffState];
    [cropBox setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:cropBox];
    cropCheckbox = cropBox; /* weak: retained by superview */
    [cropBox release];
    x += cropBoxW + 16.0f;

    /* Drops label -- appears to the right of the vsync checkbox while a
       player is open, hidden otherwise.  Wide enough for a 6-digit
       count ("999999 dropped frames" ~= 170 px at 13pt system).  Left
       edge is anchored by setAutoresizingMask NSViewMinYMargin just
       like the other controls; the window's min width is plenty to
       keep the label onscreen. */
    float dropsW = 180.0f;
    NSTextField* dLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(x, rowY, dropsW, controlsH)];
    [dLabel setStringValue:@"0 dropped frames"];
    [dLabel setBezeled:NO];
    [dLabel setDrawsBackground:NO];
    [dLabel setEditable:NO];
    [dLabel setSelectable:NO];
    [dLabel setAutoresizingMask:NSViewMinYMargin];
    [dLabel setHidden:YES];
    ttCenterLabelInRow(dLabel, rowY, controlsH, dropsW);
    [content addSubview:dLabel];
    dropsLabel = dLabel; /* weak: retained by superview */
    [dLabel release];

    /* Table in a scroll view -- fills the rest, grows in both axes. */
    NSRect scrollFrame = NSMakeRect(margin,
                                    margin,
                                    cb.size.width - 2 * margin,
                                    cb.size.height - 4 * margin
                                        - searchH - controlsH);
    NSScrollView* sv = [[NSScrollView alloc] initWithFrame:scrollFrame];
    [sv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [sv setHasVerticalScroller:YES];
    [sv setHasHorizontalScroller:NO];
    [sv setBorderType:NSBezelBorder];

    NSTableView* tv = [[NSTableView alloc] initWithFrame:[[sv contentView] bounds]];
    [tv setAllowsColumnResizing:YES];
    [tv setAllowsColumnReordering:NO];
    [tv setAllowsMultipleSelection:NO];
    /* 320x180 medium thumbnails displayed at 1:1; 184px row leaves a
     * 2px gap top/bottom. */
    [tv setRowHeight:184.0f];
    /* No column headers -- both columns are unlabeled. */
    [tv setHeaderView:nil];

    /* Thumbnail column -- image cell, fixed 320px to match native. */
    NSTableColumn* thumbCol = [[NSTableColumn alloc] initWithIdentifier:@"thumb"];
    [thumbCol setWidth:320.0f];
    [thumbCol setMinWidth:320.0f];
    [thumbCol setMaxWidth:320.0f];
    NSImageCell* imageCell = [[NSImageCell alloc] init];
    [imageCell setImageScaling:NSScaleProportionally];
    [imageCell setImageFrameStyle:NSImageFrameNone];
    [thumbCol setDataCell:imageCell];
    [imageCell release];
    [tv addTableColumn:thumbCol];
    [thumbCol release];

    /* Info column -- custom cell draws title/channel/duration/views
     * stacked vertically.  Takes the rest of the row. */
    NSTableColumn* infoCol = [[NSTableColumn alloc] initWithIdentifier:@"info"];
    [infoCol setWidth:560.0f];
    [infoCol setMinWidth:240.0f];
    ResultCell* infoCell = [[ResultCell alloc] init];
    [infoCol setDataCell:infoCell];
    [infoCell release];
    [tv addTableColumn:infoCol];
    [infoCol release];

    [tv setDataSource:self];
    [tv setDelegate:self];
    [tv setTarget:self];
    [tv setAction:@selector(tableClick:)];

    [sv setDocumentView:tv];    /* sv retains tv */
    tableView = tv;             /* weak: retained by scroll view */
    [tv release];

    [content addSubview:sv];
    [sv release];

    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:searchField];
}

#pragma mark -

- (void)searchAction:(id)sender {
    fprintf(stderr, "searchAction: fired\n");
    if (searching) {
        return;
    }
    NSString* query = [[searchField stringValue] copy];
    if ([query length] == 0) {
        [query release];
        return;
    }

    /* file:<path> back-door -- synchronous, no YouTube round-trip. */
    NSString* filePath = TTParseFilePath(query);
    if (filePath != nil) {
        [self handleFileSearch:filePath];
        [query release];
        return;
    }

    searching = YES;
    [searchField setEnabled:NO];

    [NSThread detachNewThreadSelector:@selector(performSearchInBackground:)
                             toTarget:self
                           withObject:[query autorelease]];
}

- (void)handleFileSearch:(NSString*)filePath {
    fprintf(stderr, "file: accepted \"%s\"\n", [filePath UTF8String]);

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

- (void)performSearchInBackground:(NSString*)query {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

    NSArray* newResults = [client searchVideos:query maxResults:25];
    /* newResults may be nil on error.  Hop to main thread either way so
     * we re-enable the field. */
    [self performSelectorOnMainThread:@selector(searchDidFinish:)
                           withObject:newResults
                        waitUntilDone:NO];

    [pool release];
}

- (void)searchDidFinish:(NSArray*)newResults {
    fprintf(stderr, "searchDidFinish: %d results\n",
            newResults ? (int)[newResults count] : -1);
    if (newResults != nil) {
        [results removeAllObjects];
        /* Pre-decode titles/channels and pre-format duration and view
         * count so the cell data source is a pure lookup. */
        NSEnumerator* e = [newResults objectEnumerator];
        NSMutableDictionary* row;
        while ((row = [e nextObject]) != nil) {
            NSString* title = [row objectForKey:@"title"];
            NSString* channel = [row objectForKey:@"channelTitle"];
            NSString* duration = [row objectForKey:@"duration"];
            NSString* viewCount = [row objectForKey:@"viewCount"];
            if (title != nil) {
                [row setObject:[title htmlDecoded] forKey:@"title"];
            }
            if (channel != nil) {
                [row setObject:[channel htmlDecoded] forKey:@"channelTitle"];
            }
            /* Livestreams have no meaningful duration -- substitute
               a status label in the cell's duration slot.  Checked
               before the ISO 8601 path because YouTube returns
               duration="P0D" for live items, which would otherwise
               render as "0:00". */
            NSString* liveState = [row objectForKey:@"liveBroadcastContent"];
            if ([liveState isEqualToString:@"live"]) {
                [row setObject:[NSNumber numberWithInt:0]
                        forKey:@"durationSeconds"];
                [row setObject:@"LIVE" forKey:@"duration"];
            } else if ([liveState isEqualToString:@"upcoming"]) {
                [row setObject:[NSNumber numberWithInt:0]
                        forKey:@"durationSeconds"];
                [row setObject:@"UPCOMING" forKey:@"duration"];
            } else if (duration != nil) {
                /* Stash raw seconds for the player's transport bar
                   before overwriting "duration" with the display form. */
                int durSec = [duration iso8601DurationSeconds];
                [row setObject:[NSNumber numberWithInt:durSec]
                        forKey:@"durationSeconds"];
                [row setObject:[duration iso8601DurationDisplay]
                        forKey:@"duration"];
            }
            if (viewCount != nil) {
                [row setObject:[viewCount viewCountDisplay]
                        forKey:@"viewCountDisplay"];
            }
            [results addObject:row];
        }
    }
    [tableView reloadData];
    /* Scroll to the top -- otherwise a second search while scrolled
       mid-list leaves the user looking at row 15 of the new results. */
    if ([results count] > 0) {
        [tableView scrollRowToVisible:0];
    }
    searching = NO;
    [searchField setEnabled:YES];
    [window makeFirstResponder:searchField];

    /* If the search failed with 403, surface the key prompt.  Done
       after the UI reset so the modal doesn't leave the search field
       disabled or the spinner locked. */
    if (newResults == nil && [client lastHTTPStatus] == 403) {
        [self handleAPIKey403WithReason:[client lastErrorReason]
                           usedOverride:[client lastErrorUsedOverrideKey]];
    }
}

#pragma mark - YouTube API key override

- (void)handleAPIKey403WithReason:(NSString*)reason
                     usedOverride:(BOOL)usedOverride
{
    if (isShowingKeyPrompt) {
        fprintf(stderr, "api key: 403 received while prompt already up, ignoring\n");
        return;
    }

    BOOL isQuota = [reason isEqualToString:@"quotaExceeded"]
                || [reason isEqualToString:@"dailyLimitExceeded"]
                || [reason isEqualToString:@"rateLimitExceeded"];
    BOOL overrideRejected = usedOverride
                         && ([reason isEqualToString:@"keyInvalid"]
                             || [reason isEqualToString:@"badRequest"]);
    BOOL defaultRejected = !usedOverride
                        && [reason isEqualToString:@"keyInvalid"];

    if (!isQuota && !overrideRejected) {
        fprintf(stderr, "api key: 403 reason='%s' usedOverride=%d "
                        "-- not user-fixable via key paste, skipping prompt\n",
                reason ? [reason UTF8String] : "(nil)",
                usedOverride ? 1 : 0);
        if (defaultRejected) {
            NSAlert* a = [[[NSAlert alloc] init] autorelease];
            [a setMessageText:@"YouTube API error"];
            [a setInformativeText:@"The default YouTube API key was "
                                   @"rejected by YouTube. This is "
                                   @"unexpected -- please report it."];
            [a runModal];
        }
        return;
    }

    NSString* title;
    NSString* body;
    if (isQuota) {
        title = @"YouTube API quota reached";
        body = @"TigerTube ships with a shared YouTube API key, and "
               @"today's quota has been used up across all users.\n\n"
               @"You can continue searching immediately by creating "
               @"your own free API key:\n"
               @"  1. Go to https://console.cloud.google.com/\n"
               @"  2. Create a project (or pick an existing one)\n"
               @"  3. Enable \"YouTube Data API v3\"\n"
               @"  4. Create an API key under Credentials\n"
               @"  5. Paste it below.\n\n"
               @"Your key is saved to ~/.tigertube/youtube-api-key.txt "
               @"and only used from this machine.";
    } else {
        title = @"Your YouTube API key was rejected";
        body = @"The personal API key at "
               @"~/.tigertube/youtube-api-key.txt was rejected by "
               @"YouTube. Paste a replacement below, or delete that "
               @"file to go back to the shared default key.";
    }

    isShowingKeyPrompt = YES;
    NSString* pasted = [self runKeyPromptWithTitle:title body:body];
    isShowingKeyPrompt = NO;

    if (pasted == nil) {
        return;
    }
    NSString* trimmed = [pasted stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0) {
        return;
    }

    [self saveOverrideKey:trimmed];
}

/* Modal key-prompt window.  NSAlert's -setAccessoryView: is 10.5+
   (runtime confirmed: NSAlert on Tiger does not implement it), so
   we build a plain NSWindow with a title label, wrapped body, text
   field, and two buttons.  Runs via -[NSApp runModalForWindow:];
   Save/Cancel buttons stop the modal with code 1/0.  Returns the
   entered string on Save, or nil on Cancel. */
- (NSString*)runKeyPromptWithTitle:(NSString*)title body:(NSString*)body {
    float width = 460.0f;
    float height = 290.0f;
    NSRect wf = NSMakeRect(0, 0, width, height);
    NSWindow* panel = [[NSWindow alloc]
        initWithContentRect:wf
                  styleMask:NSTitledWindowMask
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [panel setTitle:@"TigerTube"];
    [panel setReleasedWhenClosed:NO];

    NSView* cv = [panel contentView];
    float pad = 20.0f;

    /* Title, bold. */
    float titleH = 20.0f;
    NSTextField* titleLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(pad, height - pad - titleH,
                   width - 2 * pad, titleH)];
    [titleLabel setStringValue:title];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:13.0f]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [cv addSubview:titleLabel];
    [titleLabel release];

    /* Body, wrapped, selectable. */
    float inputH = 22.0f;
    float btnH = 32.0f;
    float bodyY = pad + btnH + 10.0f + inputH + 10.0f;
    float bodyH = (height - pad - titleH - 6.0f) - bodyY;
    NSTextField* bodyLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(pad, bodyY, width - 2 * pad, bodyH)];
    [bodyLabel setStringValue:body];
    [bodyLabel setFont:[NSFont systemFontOfSize:11.0f]];
    [bodyLabel setBezeled:NO];
    [bodyLabel setDrawsBackground:NO];
    [bodyLabel setEditable:NO];
    [bodyLabel setSelectable:YES];
    [[bodyLabel cell] setWraps:YES];
    [cv addSubview:bodyLabel];
    [bodyLabel release];

    /* Text field. */
    NSTextField* input = [[NSTextField alloc] initWithFrame:
        NSMakeRect(pad, pad + btnH + 10.0f,
                   width - 2 * pad, inputH)];
    [input setBezeled:YES];
    [input setBezelStyle:NSTextFieldSquareBezel];
    [input setDrawsBackground:YES];
    [input setEditable:YES];
    [input setSelectable:YES];
    [[input cell] setScrollable:YES];
    [cv addSubview:input];

    /* Buttons bottom-right: [Cancel] [Save Key]. */
    float btnW = 95.0f;
    float btnGap = 10.0f;
    float saveX = width - pad - btnW;
    float cancelX = saveX - btnGap - btnW;

    NSButton* cancel = [[NSButton alloc] initWithFrame:
        NSMakeRect(cancelX, pad, btnW, btnH)];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];  /* Esc */
    [cancel setTarget:self];
    [cancel setAction:@selector(keyPromptCancel:)];
    [cv addSubview:cancel];
    [cancel release];

    NSButton* save = [[NSButton alloc] initWithFrame:
        NSMakeRect(saveX, pad, btnW, btnH)];
    [save setTitle:@"Save Key"];
    [save setBezelStyle:NSRoundedBezelStyle];
    [save setKeyEquivalent:@"\r"];  /* Return -- becomes default button */
    [save setTarget:self];
    [save setAction:@selector(keyPromptSave:)];
    [cv addSubview:save];
    [save release];

    [panel setInitialFirstResponder:input];
    [panel center];

    int rc = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];

    NSString* result = nil;
    if (rc == 1) {
        result = [[[input stringValue] copy] autorelease];
    }
    [input release];
    [panel release];
    return result;
}

- (void)keyPromptSave:(id)sender {
    [NSApp stopModalWithCode:1];
}

- (void)keyPromptCancel:(id)sender {
    [NSApp stopModalWithCode:0];
}

- (void)saveOverrideKey:(NSString*)key {
    NSString* dir = [@"~/.tigertube" stringByExpandingTildeInPath];
    NSString* path = [dir stringByAppendingPathComponent:
                              @"youtube-api-key.txt"];
    NSFileManager* fm = [NSFileManager defaultManager];

    /* Create ~/.tigertube mode 0700 if it doesn't exist.  The 10.4
       signature is createDirectoryAtPath:attributes:; the newer
       withIntermediateDirectories: variant is 10.5+. */
    if (![fm fileExistsAtPath:dir]) {
        NSDictionary* dirAttrs = [NSDictionary dictionaryWithObject:
            [NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions];
        if (![fm createDirectoryAtPath:dir attributes:dirAttrs]) {
            fprintf(stderr, "api key: failed to create %s\n",
                    [dir UTF8String]);
            NSAlert* a = [[[NSAlert alloc] init] autorelease];
            [a setMessageText:@"Could not save key"];
            [a setInformativeText:[NSString stringWithFormat:
                @"Failed to create directory %@", dir]];
            [a runModal];
            return;
        }
    }

    NSError* err = nil;
    if (![key writeToFile:path
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&err]) {
        NSString* msg = [err localizedDescription];
        if (msg == nil) msg = @"(unknown error)";
        fprintf(stderr, "api key: failed to write %s: %s\n",
                [path UTF8String], [msg UTF8String]);
        NSAlert* a = [[[NSAlert alloc] init] autorelease];
        [a setMessageText:@"Could not save key"];
        [a setInformativeText:[NSString stringWithFormat:
            @"Failed to write %@: %@", path, msg]];
        [a runModal];
        return;
    }

    /* chmod 0600. */
    NSDictionary* fileAttrs = [NSDictionary dictionaryWithObject:
        [NSNumber numberWithInt:0600] forKey:NSFilePosixPermissions];
    [fm changeFileAttributes:fileAttrs atPath:path];

    /* Deliberately do not log the key bytes themselves. */
    fprintf(stderr, "api key: saved override key (%lu bytes) to %s\n",
            (unsigned long)[key lengthOfBytesUsingEncoding:
                                NSUTF8StringEncoding],
            [path UTF8String]);
}

#pragma mark - NSTableView data source

- (int)numberOfRowsInTableView:(NSTableView*)tv {
    return (int)[results count];
}

- (id)tableView:(NSTableView*)tv
      objectValueForTableColumn:(NSTableColumn*)col
                            row:(int)row
{
    if (row < 0 || row >= (int)[results count]) {
        return nil;
    }
    NSDictionary* item = [results objectAtIndex:row];
    NSString* ident = [col identifier];
    if ([ident isEqualToString:@"thumb"]) {
        /* file: rows have no thumbnail source -- return nil so the
           image cell renders blank instead of kicking the cache. */
        NSString* kind = [item objectForKey:@"kind"];
        if ([kind isEqualToString:@"file"]) {
            return nil;
        }
        /* Lazy load: asking the cache kicks off a fetch if it's not
         * already cached.  Returns nil (blank cell) until the delegate
         * callback fires and we reload. */
        NSString* vid = [item objectForKey:@"videoId"];
        NSString* url = [item objectForKey:@"thumbnailURL"];
        return [thumbCache imageForVideoId:vid url:url];
    }
    if ([ident isEqualToString:@"info"]) {
        /* ResultCell reads title/channelTitle/duration/viewCountDisplay
         * directly off the dict. */
        return item;
    }
    return @"";
}

- (int)rowIndexForVideoId:(NSString*)videoId {
    NSUInteger n = [results count];
    NSUInteger i;
    for (i = 0; i < n; i++) {
        NSDictionary* row = [results objectAtIndex:i];
        if ([[row objectForKey:@"videoId"] isEqualToString:videoId]) {
            return (int)i;
        }
    }
    return -1;
}

#pragma mark - Video playback

- (void)tableClick:(id)sender {
    int row = [tableView clickedRow];
    fprintf(stderr, "tableClick: clickedRow=%d\n", row);
    if (row < 0 || row >= (int)[results count]) {
        return;
    }
    [self playVideoAtIndex:row];
}

- (void)playVideoAtIndex:(int)index {
    fprintf(stderr, "playVideoAtIndex: %d\n", index);
    NSDictionary* item = [results objectAtIndex:index];
    NSString* kind = [item objectForKey:@"kind"];
    if (kind == nil) kind = @"yt";
    NSString* videoId = [item objectForKey:@"videoId"];
    NSString* filePath = [item objectForKey:@"filePath"];
    NSString* title = [item objectForKey:@"title"];
    fprintf(stderr, "playVideoAtIndex: kind=%s videoId=%s filePath=%s title=%s\n",
            [kind UTF8String],
            videoId ? [videoId UTF8String] : "(nil)",
            filePath ? [filePath UTF8String] : "(nil)",
            title ? [title UTF8String] : "(nil)");
    if ([kind isEqualToString:@"yt"] && videoId == nil) {
        fprintf(stderr, "playVideoAtIndex: no videoId, aborting\n");
        return;
    }
    if ([kind isEqualToString:@"file"] && filePath == nil) {
        fprintf(stderr, "playVideoAtIndex: no filePath, aborting\n");
        return;
    }

    /* Close any existing player window before opening a new one.
       -stop on its own halts playback but leaves the NSWindow ordered
       front (AppKit retains it), so the old window would stick around
       with a dangling delegate pointer after we release the controller.
       -closePlayer exits fullscreen if needed and calls -[window close],
       which triggers windowWillClose: -> stop via the delegate path. */
    if (playerController != nil) {
        [playerController closePlayer];
        [playerController release];
        playerController = nil;
    }

    /* Read the resolution/quality popup selections.  The popups are
       populated with known-good strings in buildWindow, so we don't
       need defensive parsing -- just split "WxH" on "x" and atoi the
       quality.  Fall back to the constants if anything looks off. */
    int width  = TT_VIDEO_WIDTH;
    int height = TT_VIDEO_HEIGHT;
    int qscale = TT_VIDEO_QSCALE;
    NSString* resTitle = [resolutionPopup titleOfSelectedItem];
    NSArray* wh = [resTitle componentsSeparatedByString:@"x"];
    if ([wh count] == 2) {
        width  = [[wh objectAtIndex:0] intValue];
        height = [[wh objectAtIndex:1] intValue];
    }
    NSString* qTitle = [qualityPopup titleOfSelectedItem];
    int qParsed = [qTitle intValue];
    if (qParsed >= 2 && qParsed <= 31) {
        qscale = qParsed;
    }
    /* Framerate popup: "Source" => omit fps= so the proxy drops
       the fps= CFR filter (source-rate passthrough).  Any other
       title goes into fps= verbatim via %@, so "24" stays "24"
       with no float-format surprises. */
    NSString* fpsTitle = [fpsPopup titleOfSelectedItem];
    BOOL useSourceFps  = [fpsTitle isEqualToString:@"Source"];
    /* Crop checkbox: when on, appends ?crop=auto so the proxy runs
       cropdetect to strip baked pillarbox / letterbox bars.  One
       suffix reused by all four vURL branches below. */
    BOOL cropOn = ([cropCheckbox state] == NSOnState);
    NSString* cropSuffix = cropOn ? @"&crop=auto" : @"";
    fprintf(stderr, "playVideoAtIndex: res=%dx%d q=%d fps=%s crop=%s\n",
            width, height, qscale,
            useSourceFps ? "Source" : [fpsTitle UTF8String],
            cropOn ? "auto" : "off");

    /* src_h (YouTube source-height cap) is derived proxy-side from h=
       so the client doesn't need to know about yt-dlp's tier list. */
    NSString* vURL;
    NSString* aURL;
    if ([kind isEqualToString:@"file"]) {
        /* stringByAddingPercentEscapesUsingEncoding: is deprecated post
           10.8 but is the 10.4-appropriate API; the modern replacement
           stringByAddingPercentEncodingWithAllowedCharacters: is 10.9+. */
        NSString* escaped = [filePath
            stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (useSourceFps) {
            vURL = [NSString stringWithFormat:
                @"%@/v/file?path=%@&w=%d&h=%d&q=%d&g=%d%@",
                proxyHost, escaped,
                width, height, qscale,
                TT_VIDEO_GOP, cropSuffix];
        } else {
            vURL = [NSString stringWithFormat:
                @"%@/v/file?path=%@&w=%d&h=%d&q=%d&fps=%@&g=%d%@",
                proxyHost, escaped,
                width, height, qscale,
                fpsTitle, TT_VIDEO_GOP, cropSuffix];
        }
        aURL = [NSString stringWithFormat:
            @"%@/a/file?path=%@&rate=%d&ch=%d",
            proxyHost, escaped,
            TT_AUDIO_RATE, TT_AUDIO_CHANNELS];
    } else {
        if (useSourceFps) {
            vURL = [NSString stringWithFormat:
                @"%@/v/yt/%@?w=%d&h=%d&q=%d&g=%d%@",
                proxyHost, videoId,
                width, height, qscale,
                TT_VIDEO_GOP, cropSuffix];
        } else {
            vURL = [NSString stringWithFormat:
                @"%@/v/yt/%@?w=%d&h=%d&q=%d&fps=%@&g=%d%@",
                proxyHost, videoId,
                width, height, qscale,
                fpsTitle, TT_VIDEO_GOP, cropSuffix];
        }
        aURL = [NSString stringWithFormat:
            @"%@/a/yt/%@?rate=%d&ch=%d",
            proxyHost, videoId,
            TT_AUDIO_RATE, TT_AUDIO_CHANNELS];
    }

    NSNumber* durBox = [item objectForKey:@"durationSeconds"];
    int durSec = (durBox != nil) ? [durBox intValue] : 0;
    BOOL vsyncOn = ([vsyncCheckbox state] == NSOnState);
    playerController = [[TTPlayerWindowController alloc]
        initWithTitle:title
             videoURL:vURL
             audioURL:aURL
             duration:durSec
                width:width
               height:height
                vsync:vsyncOn];
    if (playerController != nil) {
        [playerController play];
        [self startDropsPolling];
    }
}

#pragma mark - Drops label (while a player is open)

/* Called from playVideoAtIndex once the new player is created.  The
   label stays hidden until the player reports a non-zero drop count
   -- it only shows when drops are actually happening.  The 4 Hz poll
   mirrors the player's framesDropped counter into the label text and
   notices when the player's window has been closed, tearing itself
   down in place of a delegate back to AppController. */
- (void)startDropsPolling {
    if (dropsLabel == nil) {
        return;
    }
    [dropsLabel setHidden:YES];
    if (dropsPollTimer != nil) {
        [dropsPollTimer invalidate];
        [dropsPollTimer release];
        dropsPollTimer = nil;
    }
    dropsPollTimer = [[NSTimer
        scheduledTimerWithTimeInterval:0.25
                                target:self
                              selector:@selector(dropsTick:)
                              userInfo:nil
                               repeats:YES] retain];
}

- (void)dropsTick:(NSTimer*)timer {
    (void)timer;
    if (playerController == nil
        || ![[playerController window] isVisible])
    {
        [dropsLabel setHidden:YES];
        if (dropsPollTimer != nil) {
            [dropsPollTimer invalidate];
            [dropsPollTimer release];
            dropsPollTimer = nil;
        }
        return;
    }
    unsigned long n = [playerController framesDropped];
    if (n == 0) {
        [dropsLabel setHidden:YES];
        return;
    }
    [dropsLabel setStringValue:
        [NSString stringWithFormat:@"%lu dropped frames", n]];
    [dropsLabel setHidden:NO];
}

#pragma mark - Bonjour proxy discovery

/* NSNetServiceBrowser delivers an unresolved NSNetService (name only).
   We have to call resolveWithTimeout: on it to get the hostname and
   port, then pick the first one that resolves.  The service object
   must stay retained for the duration of the resolve, so we stash it
   in resolving[] until its delegate callback fires. */

- (void)netServiceBrowser:(NSNetServiceBrowser*)browser
            didFindService:(NSNetService*)service
                moreComing:(BOOL)moreComing
{
    fprintf(stderr, "proxy: found '%s' in domain '%s', resolving...\n",
            [[service name] UTF8String], [[service domain] UTF8String]);
    [service setDelegate:self];
    [resolving addObject:service]; /* retain until resolution finishes */
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)browser
          didRemoveService:(NSNetService*)service
                moreComing:(BOOL)moreComing
{
    fprintf(stderr, "proxy: service '%s' went away\n",
            [[service name] UTF8String]);
    /* We don't revert proxyHost -- the user may already be mid-playback
       and the old URL might still work briefly.  If playback fails they
       can restart the app. */
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)browser
              didNotSearch:(NSDictionary*)errorInfo
{
    fprintf(stderr, "proxy: bonjour browse failed: %s\n",
            [[errorInfo description] UTF8String]);
}

- (void)netServiceDidResolveAddress:(NSNetService*)service {
    NSString* host = [service hostName];
    int port = ttPortFromNetService(service);
    if (host == nil || port <= 0) {
        fprintf(stderr, "proxy: resolved '%s' but host/port missing\n",
                [[service name] UTF8String]);
        [resolving removeObject:service];
        return;
    }
    /* hostName often has a trailing dot (e.g. "macmini.local.").
       Trim it -- harmless for DNS but ugly in URLs/logs. */
    if ([host hasSuffix:@"."]) {
        host = [host substringToIndex:[host length] - 1];
    }

    NSString* url = [NSString stringWithFormat:@"http://%@:%d", host, port];
    fprintf(stderr, "proxy: resolved '%s' -> %s\n",
            [[service name] UTF8String], [url UTF8String]);

    if (!proxyDiscovered) {
        proxyDiscovered = YES;
        [proxyHost release];
        proxyHost = [url retain];
        [window setTitle:[NSString stringWithFormat:
                             @"TigerTube (proxy: %@:%d)", host, port]];
    }

    [service stop];
    [service setDelegate:nil];
    [resolving removeObject:service];
}

- (void)netService:(NSNetService*)service didNotResolve:(NSDictionary*)err {
    fprintf(stderr, "proxy: failed to resolve '%s': %s\n",
            [[service name] UTF8String], [[err description] UTF8String]);
    [service setDelegate:nil];
    [resolving removeObject:service];
}

#pragma mark - ThumbnailCacheDelegate

- (void)thumbnailCache:(ThumbnailCache*)cache
    didLoadImageForVideoId:(NSString*)videoId
{
    /* Redraw just the affected row -- full reloadData stutters
     * while many thumbs are streaming in. */
    int row = [self rowIndexForVideoId:videoId];
    if (row >= 0) {
        [tableView setNeedsDisplayInRect:[tableView rectOfRow:row]];
    }
}

@end
