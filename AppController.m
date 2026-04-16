//
//  AppController.m
//  TigerTube
//

#import "AppController.h"
#import "YTClient.h"
#import "NSString+.h"
#import "ResultCell.h"
#import "Secrets.h"
#include <curl/curl.h>

@interface AppController (Private)
- (void)buildWindow;
- (void)performSearchInBackground:(NSString*)query;
- (void)searchDidFinish:(NSArray*)newResults;
- (int)rowIndexForVideoId:(NSString*)videoId;
@end

@implementation AppController

- (id)init {
    self = [super init];
    if (self != nil) {
        results = [[NSMutableArray alloc] init];
        searching = NO;
    }
    return self;
}

- (void)dealloc {
    [client release];
    [thumbCache release];
    [results release];
    [window release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification*)note {
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
    [window setMinSize:NSMakeSize(700, 400)];
    [window setReleasedWhenClosed:NO];

    NSView* content = [window contentView];
    NSRect cb = [content bounds];
    float margin = 10.0f;
    float searchH = 22.0f;

    /* Search field -- top, full width, springs from top. */
    NSRect searchFrame = NSMakeRect(margin,
                                    cb.size.height - margin - searchH,
                                    cb.size.width - 2 * margin,
                                    searchH);
    NSSearchField* sf = [[NSSearchField alloc] initWithFrame:searchFrame];
    [sf setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [sf setTarget:self];
    [sf setAction:@selector(searchAction:)];
    [[sf cell] setPlaceholderString:@"Search YouTube..."];
    /* Only fire the action on Return, not on every keystroke. */
    [[sf cell] setSendsWholeSearchString:YES];
    [content addSubview:sf];
    searchField = sf;    /* weak: retained by superview */
    [sf release];

    /* Table in a scroll view -- fills the rest, grows in both axes. */
    NSRect scrollFrame = NSMakeRect(margin,
                                    margin,
                                    cb.size.width - 2 * margin,
                                    cb.size.height - 3 * margin - searchH);
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
    if (searching) {
        return;
    }
    NSString* query = [[searchField stringValue] copy];
    if ([query length] == 0) {
        [query release];
        return;
    }

    searching = YES;
    [searchField setEnabled:NO];

    [NSThread detachNewThreadSelector:@selector(performSearchInBackground:)
                             toTarget:self
                           withObject:[query autorelease]];
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
            if (duration != nil) {
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
    searching = NO;
    [searchField setEnabled:YES];
    [window makeFirstResponder:searchField];
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
