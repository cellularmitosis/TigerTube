//
//  TTScrubSlider.m
//  TigerTube
//

#import "TTScrubSlider.h"

@implementation TTScrubSlider

- (void)mouseDown:(NSEvent*)event {
    dragging = YES;
    [super mouseDown:event]; /* blocks until mouseUp; action fires there */
    dragging = NO;
}

- (BOOL)isDragging {
    return dragging;
}

@end
