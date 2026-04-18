//
//  ResultCell.m
//  TigerTube
//

#import "ResultCell.h"

@implementation ResultCell

- (void)dealloc {
    [info release];
    [super dealloc];
}

/* NSTableView copies the prototype data cell for each draw, via
 * -copyWithZone:.  NSCell's default copyWithZone: does a bitwise ivar
 * copy, which leaves the copy's `info` pointer aliasing ours without a
 * retain -- so we must retain it once on the copy to give it its own
 * ownership. */
- (id)copyWithZone:(NSZone*)zone {
    ResultCell* copy = (ResultCell*)[super copyWithZone:zone];
    copy->info = [info retain];
    return copy;
}

- (void)setObjectValue:(id)value {
    if (info != value) {
        [info release];
        info = [value retain];
    }
}

- (id)objectValue {
    return info;
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView*)view {
    if (![info isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString* title = [info objectForKey:@"title"];
    NSString* channel = [info objectForKey:@"channelTitle"];
    NSString* duration = [info objectForKey:@"duration"];
    NSString* views = [info objectForKey:@"viewCountDisplay"];
    if (title == nil) { title = @""; }
    if (channel == nil) { channel = @""; }
    if (duration == nil) { duration = @""; }
    if (views == nil) { views = @""; }

    BOOL hi = [self isHighlighted];
    NSColor* titleColor = hi ? [NSColor whiteColor] : [NSColor blackColor];
    NSColor* metaColor = hi ? [NSColor whiteColor] : [NSColor darkGrayColor];
    NSFont* titleFont = [NSFont boldSystemFontOfSize:18.0f];
    NSFont* metaFont = [NSFont systemFontOfSize:14.0f];

    /* Title wraps to (up to) two lines; meta lines always truncate. */
    NSMutableParagraphStyle* titlePara = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [titlePara setLineBreakMode:NSLineBreakByWordWrapping];
    [titlePara setAlignment:NSLeftTextAlignment];

    NSMutableParagraphStyle* metaPara = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [metaPara setLineBreakMode:NSLineBreakByTruncatingTail];
    [metaPara setAlignment:NSLeftTextAlignment];

    NSDictionary* titleAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
        titleFont, NSFontAttributeName,
        titleColor, NSForegroundColorAttributeName,
        titlePara, NSParagraphStyleAttributeName,
        nil];
    NSDictionary* metaAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
        metaFont, NSFontAttributeName,
        metaColor, NSForegroundColorAttributeName,
        metaPara, NSParagraphStyleAttributeName,
        nil];

    float padL = 10.0f;
    float padT = 10.0f;
    float padR = 8.0f;
    float x = frame.origin.x + padL;
    float w = frame.size.width - padL - padR;
    float y = frame.origin.y + padT;
    /* Row heights must clear the fonts' full line height (ascender +
     * descender + leading) or descenders get clipped.  Sized for the
     * current 18pt bold title and 14pt meta; bump these if the fonts
     * above grow.  titleH reserves two full lines so long titles can
     * wrap; anything past two lines gets clipped (no ellipsis in
     * word-wrap mode). */
    float titleH = 50.0f;
    float metaH = 19.0f;
    float gap = 4.0f;

    NSRect r;

    r = NSMakeRect(x, y, w, titleH);
    [title drawInRect:r withAttributes:titleAttrs];
    y += titleH + gap;

    r = NSMakeRect(x, y, w, metaH);
    [channel drawInRect:r withAttributes:metaAttrs];
    y += metaH;

    r = NSMakeRect(x, y, w, metaH);
    [duration drawInRect:r withAttributes:metaAttrs];
    y += metaH;

    r = NSMakeRect(x, y, w, metaH);
    [views drawInRect:r withAttributes:metaAttrs];
}

@end
