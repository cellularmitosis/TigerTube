//
//  main.m
//  TigerTube
//

#import <Cocoa/Cocoa.h>
#import "AppController.h"

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    [NSApplication sharedApplication];

    AppController *controller = [[AppController alloc] init];
    [NSApp setDelegate:controller];

    /* Load MainMenu.nib for the default menu bar only.  All window/view
     * construction happens in AppController programmatically. */
    [NSBundle loadNibNamed:@"MainMenu" owner:NSApp];

    [NSApp run];

    [controller release];
    [pool release];
    return 0;
}
