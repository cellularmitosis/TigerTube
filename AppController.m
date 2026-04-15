//
//  AppController.m
//  TigerTube
//

#import "AppController.h"
#import "YTClient.h"
#import "NSString+.h"
#import "Secrets.h"
#include <curl/curl.h>

@interface AppController (Private)
- (void)buildWindow;
- (void)performSearchInBackground:(NSString *)query;
- (void)searchDidFinish:(NSArray *)newResults;
@end

@implementation AppController

- (id)init
{
    self = [super init];
    if (self != nil) {
        results = [[NSMutableArray alloc] init];
        searching = NO;
    }
    return self;
}

- (void)dealloc
{
    [client release];
    [results release];
    [window release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    curl_global_init(CURL_GLOBAL_DEFAULT);

    NSString *caPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (caPath == nil) {
        fprintf(stderr, "FATAL: cacert.pem not found in bundle\n");
        [NSApp terminate:nil];
        return;
    }

    NSString *apiKey = [NSString stringWithUTF8String:YOUTUBE_API_KEY];
    client = [[YTClient alloc] initWithAPIKey:apiKey caBundlePath:caPath];
    if (client == nil) {
        fprintf(stderr, "FATAL: YTClient init failed\n");
        [NSApp terminate:nil];
        return;
    }

    [self buildWindow];
}

- (void)buildWindow
{
    NSRect frame = NSMakeRect(120, 120, 700, 500);
    unsigned int style = NSTitledWindowMask
                       | NSClosableWindowMask
                       | NSMiniaturizableWindowMask
                       | NSResizableWindowMask;

    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"TigerTube"];
    [window setMinSize:NSMakeSize(420, 260)];
    [window setReleasedWhenClosed:NO];

    NSView *content = [window contentView];
    NSRect cb = [content bounds];
    float margin = 10.0f;
    float searchH = 22.0f;

    /* Search field -- top, full width, springs from top. */
    NSRect searchFrame = NSMakeRect(margin,
                                    cb.size.height - margin - searchH,
                                    cb.size.width - 2 * margin,
                                    searchH);
    NSSearchField *sf = [[NSSearchField alloc] initWithFrame:searchFrame];
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
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:scrollFrame];
    [sv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [sv setHasVerticalScroller:YES];
    [sv setHasHorizontalScroller:NO];
    [sv setBorderType:NSBezelBorder];

    NSTableView *tv = [[NSTableView alloc] initWithFrame:[[sv contentView] bounds]];
    [tv setAllowsColumnResizing:YES];
    [tv setAllowsColumnReordering:YES];
    [tv setAllowsMultipleSelection:NO];
    [tv setRowHeight:20.0f];

    NSTableColumn *durCol = [[NSTableColumn alloc] initWithIdentifier:@"duration"];
    [[durCol headerCell] setStringValue:@"Length"];
    [durCol setWidth:64.0f];
    [durCol setMinWidth:48.0f];
    [durCol setMaxWidth:100.0f];
    [[durCol dataCell] setAlignment:NSRightTextAlignment];
    [tv addTableColumn:durCol];
    [durCol release];

    NSTableColumn *titleCol = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    [[titleCol headerCell] setStringValue:@"Title"];
    [titleCol setWidth:420.0f];
    [titleCol setMinWidth:180.0f];
    [tv addTableColumn:titleCol];
    [titleCol release];

    NSTableColumn *chanCol = [[NSTableColumn alloc] initWithIdentifier:@"channel"];
    [[chanCol headerCell] setStringValue:@"Channel"];
    [chanCol setWidth:180.0f];
    [chanCol setMinWidth:100.0f];
    [tv addTableColumn:chanCol];
    [chanCol release];

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

- (void)searchAction:(id)sender
{
    if (searching) {
        return;
    }
    NSString *query = [[searchField stringValue] copy];
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

- (void)performSearchInBackground:(NSString *)query
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSArray *newResults = [client searchVideos:query maxResults:25];
    /* newResults may be nil on error.  Hop to main thread either way so
     * we re-enable the field. */
    [self performSelectorOnMainThread:@selector(searchDidFinish:)
                           withObject:newResults
                        waitUntilDone:NO];

    [pool release];
}

- (void)searchDidFinish:(NSArray *)newResults
{
    if (newResults != nil) {
        [results removeAllObjects];
        /* Pre-decode titles/channels and pre-format duration so the cell
         * data source is a pure lookup. */
        NSEnumerator *e = [newResults objectEnumerator];
        NSMutableDictionary *row;
        while ((row = [e nextObject]) != nil) {
            NSString *title = [row objectForKey:@"title"];
            NSString *channel = [row objectForKey:@"channelTitle"];
            NSString *duration = [row objectForKey:@"duration"];
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
            [results addObject:row];
        }
    }
    [tableView reloadData];
    searching = NO;
    [searchField setEnabled:YES];
    [window makeFirstResponder:searchField];
}

#pragma mark - NSTableView data source

- (int)numberOfRowsInTableView:(NSTableView *)tv
{
    return (int)[results count];
}

- (id)tableView:(NSTableView *)tv
      objectValueForTableColumn:(NSTableColumn *)col
                            row:(int)row
{
    if (row < 0 || row >= (int)[results count]) {
        return nil;
    }
    NSDictionary *item = [results objectAtIndex:row];
    NSString *ident = [col identifier];
    if ([ident isEqualToString:@"duration"]) {
        NSString *d = [item objectForKey:@"duration"];
        return d != nil ? d : @"";
    }
    if ([ident isEqualToString:@"title"]) {
        NSString *t = [item objectForKey:@"title"];
        return t != nil ? t : @"";
    }
    if ([ident isEqualToString:@"channel"]) {
        NSString *c = [item objectForKey:@"channelTitle"];
        return c != nil ? c : @"";
    }
    return @"";
}

@end
