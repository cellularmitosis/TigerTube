//
//  AppController.h
//  TigerTube
//
//  Owns the main window and drives the search flow.  Built programmatically;
//  the stock MainMenu.nib is only used for the default menu bar.
//

#ifndef APP_CONTROLLER_H
#define APP_CONTROLLER_H

#import <Cocoa/Cocoa.h>
#import "TigerCompat.h"
#import "ThumbnailCache.h"

@class YTClient;
@class TTPlayerWindowController;

@interface AppController : NSObject <ThumbnailCacheDelegate> {
    YTClient* client;             /* strong */
    ThumbnailCache* thumbCache;   /* strong */
    NSMutableArray* results;      /* strong, array of NSMutableDictionary */
    NSWindow* window;             /* strong */
    NSTextField* searchField;     /* weak (retained by view hierarchy) */
    NSPopUpButton* resolutionPopup; /* weak */
    NSPopUpButton* qualityPopup;    /* weak */
    NSPopUpButton* fpsPopup;        /* weak; "Source" => omit fps= from
                                       proxy URL (source-rate passthrough),
                                       else numeric rate ("24", "25", "30")
                                       goes into fps= verbatim */
    NSButton* vsyncCheckbox;        /* weak; passed to the player at play
                                       time as the initial swap-interval
                                       setting */
    NSTextField* dropsLabel;        /* weak; shows "N dropped frames"
                                       to the right of vsyncCheckbox,
                                       hidden unless a player is open */
    NSTimer* dropsPollTimer;        /* strong (retained by run loop);
                                       updates dropsLabel every 0.25s
                                       while the player is open */
    NSTableView* tableView;       /* weak (retained by NSScrollView) */
    BOOL searching;
    BOOL isShowingKeyPrompt;      /* coalesces back-to-back 403s */
    TTPlayerWindowController* playerController;  /* strong, current player */
    NSString* proxyHost;          /* strong */
    BOOL proxyDiscovered;         /* YES once Bonjour resolved a proxy */

    /* Bonjour proxy discovery.  Browser finds _tigertube-proxy._tcp
       services; each found NSNetService is retained in resolving[] long
       enough for resolveWithTimeout: to complete (NSNetService gets
       deallocated mid-resolution if nobody keeps a strong reference). */
    NSNetServiceBrowser* proxyBrowser;  /* strong */
    NSMutableArray* resolving;          /* strong, of NSNetService */
}

/* NSApplication delegate */
- (void)applicationDidFinishLaunching:(NSNotification*)note;

/* NSSearchField action */
- (void)searchAction:(id)sender;

/* Table click action -- starts playback of the clicked row. */
- (void)tableClick:(id)sender;

/* NSTableView data source */
- (int)numberOfRowsInTableView:(NSTableView*)tv;
- (id)tableView:(NSTableView*)tv
      objectValueForTableColumn:(NSTableColumn*)col
                            row:(int)row;

@end

#endif
