//
//  TTScrubSlider.h
//  TigerTube
//
//  Drag-aware NSSlider subclass.  -[NSSlider mouseDown:] runs a modal
//  tracking loop that doesn't return until mouseUp; we bracket it with
//  a flag so the display timer (which does get to run between modal
//  loop iterations -- AppKit pumps the run loop) can tell whether the
//  user is currently dragging the knob and pull the time label from
//  the slider's live value instead of the audio clock.
//

#ifndef TT_SCRUB_SLIDER_H
#define TT_SCRUB_SLIDER_H

#import <Cocoa/Cocoa.h>
#import "TigerCompat.h"

@interface TTScrubSlider : NSSlider {
    BOOL dragging;
}

- (BOOL)isDragging;

@end

#endif
