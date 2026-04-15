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

@class YTClient;

@interface AppController : NSObject {
    YTClient* client;           /* strong */
    NSMutableArray* results;    /* strong, array of NSMutableDictionary */
    NSWindow* window;           /* strong */
    NSSearchField* searchField; /* weak (retained by view hierarchy) */
    NSTableView* tableView;     /* weak (retained by NSScrollView) */
    BOOL searching;
}

/* NSApplication delegate */
- (void)applicationDidFinishLaunching:(NSNotification*)note;

/* NSSearchField action */
- (void)searchAction:(id)sender;

/* NSTableView data source */
- (int)numberOfRowsInTableView:(NSTableView*)tv;
- (id)tableView:(NSTableView*)tv
      objectValueForTableColumn:(NSTableColumn*)col
                            row:(int)row;

@end

#endif
