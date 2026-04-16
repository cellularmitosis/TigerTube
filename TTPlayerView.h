//
//  TTPlayerView.h
//  TigerTube
//
//  NSOpenGLView subclass that displays UYVY frames via GL_APPLE_ycbcr_422.
//  Power-of-2 texture sized to the next power of 2 above the video dims.
//

#ifndef TT_PLAYER_VIEW_H
#define TT_PLAYER_VIEW_H

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import "TigerCompat.h"

@interface TTPlayerView : NSOpenGLView {
    GLuint tex;
    BOOL glReady;
    unsigned int srcW;     /* actual video width */
    unsigned int srcH;     /* actual video height */
    unsigned int texW;     /* power-of-2 texture width */
    unsigned int texH;     /* power-of-2 texture height */
}

- (id)initWithFrame:(NSRect)frame;

/* Call once when the video sequence header arrives. */
- (void)setupTextureWithWidth:(unsigned int)w height:(unsigned int)h;

/* Upload a UYVY frame and draw it.  Thread-safe: must be called on
   the main thread (via performSelectorOnMainThread or a timer). */
- (void)displayFrame:(const unsigned char*)uyvy
               width:(unsigned int)w
              height:(unsigned int)h
              stride:(unsigned int)stride;

@end

#endif
