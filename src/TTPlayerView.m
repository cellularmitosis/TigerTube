//
//  TTPlayerView.m
//  TigerTube
//

#import "TTPlayerView.h"
#import "TTPlayerWindowController.h"
#import <OpenGL/OpenGL.h>

#ifndef GL_YCBCR_422_APPLE
#define GL_YCBCR_422_APPLE 0x85B9
#endif
#ifndef GL_UNSIGNED_SHORT_8_8_REV_APPLE
#define GL_UNSIGNED_SHORT_8_8_REV_APPLE 0x85BB
#endif

static unsigned int nextPow2(unsigned int v) {
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    return v + 1;
}

@implementation TTPlayerView

+ (NSOpenGLPixelFormat*)defaultPixelFormat {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24,
        0
    };
    return [[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] autorelease];
}

- (id)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormat* pf = [TTPlayerView defaultPixelFormat];
    self = [super initWithFrame:frame pixelFormat:pf];
    if (self != nil) {
        glReady = NO;
        tex = 0;
        srcW = 0;
        srcH = 0;
        texW = 0;
        texH = 0;
        controller = nil;
    }
    return self;
}

- (void)setController:(TTPlayerWindowController*)c {
    controller = c; /* weak */
}

- (void)dealloc {
    if (tex != 0) {
        [[self openGLContext] makeCurrentContext];
        glDeleteTextures(1, &tex);
    }
    [super dealloc];
}

- (void)setupGL {
    [[self openGLContext] makeCurrentContext];

    /* Disable vsync -- we pace off the audio clock, not the display. */
    long swapInterval = 0;
    [[self openGLContext] setValues:&swapInterval
                      forParameter:NSOpenGLCPSwapInterval];

    glEnable(GL_TEXTURE_2D);
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glReady = YES;
}

- (void)setupTextureWithWidth:(unsigned int)w height:(unsigned int)h {
    if (!glReady) {
        [self setupGL];
    }
    [[self openGLContext] makeCurrentContext];

    srcW = w;
    srcH = h;
    texW = nextPow2(w);
    texH = nextPow2(h);

    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, texW, texH, 0,
                 GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, NULL);

    /* Set up orthographic projection matching the view bounds. */
    NSRect bounds = [self bounds];
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, bounds.size.width, 0, bounds.size.height, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
}

- (void)displayFrame:(const unsigned char*)uyvy
               width:(unsigned int)w
              height:(unsigned int)h
              stride:(unsigned int)stride
{
    if (!glReady || tex == 0 || srcW == 0) {
        return;
    }
    [[self openGLContext] makeCurrentContext];

    glBindTexture(GL_TEXTURE_2D, tex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h,
                    GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE,
                    uyvy);

    /* Compute tex coords (sub-region of power-of-2 texture). */
    float u = (float)srcW / (float)texW;
    float v = (float)srcH / (float)texH;

    NSRect bounds = [self bounds];
    float bw = bounds.size.width;
    float bh = bounds.size.height;

    /* Letterbox: fit src aspect inside the view, black bars on the
       leftover axis.  Matters for fullscreen (where view aspect is
       the screen's, not the video's) and for freely-resized windows. */
    float srcAspect = (float)srcW / (float)srcH;
    float viewAspect = bw / bh;
    float dx, dy, dw, dh;
    if (viewAspect > srcAspect) {
        /* view wider than video -- bars on left/right */
        dh = bh;
        dw = bh * srcAspect;
        dx = (bw - dw) * 0.5f;
        dy = 0;
    } else {
        /* view taller than video (or equal) -- bars top/bottom */
        dw = bw;
        dh = bw / srcAspect;
        dx = 0;
        dy = (bh - dh) * 0.5f;
    }

    glClear(GL_COLOR_BUFFER_BIT);
    glBegin(GL_QUADS);
        glTexCoord2f(0, v); glVertex2f(dx,      dy);
        glTexCoord2f(u, v); glVertex2f(dx + dw, dy);
        glTexCoord2f(u, 0); glVertex2f(dx + dw, dy + dh);
        glTexCoord2f(0, 0); glVertex2f(dx,      dy + dh);
    glEnd();

    [[self openGLContext] flushBuffer];
}

- (void)reshape {
    [[self openGLContext] makeCurrentContext];
    NSRect bounds = [self bounds];
    glViewport(0, 0, (GLsizei)bounds.size.width, (GLsizei)bounds.size.height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, bounds.size.width, 0, bounds.size.height, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
}

- (void)drawRect:(NSRect)rect {
    /* Initial draw before any frame arrives -- black. */
    if (!glReady) {
        [self setupGL];
    }
    [[self openGLContext] makeCurrentContext];
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    [[self openGLContext] flushBuffer];
}

/* Become first responder so we can receive keyDown: events. */
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent*)event {
    NSString* chars = [event charactersIgnoringModifiers];
    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        if (c == 'f' || c == 'F') {
            [controller toggleFullscreen];
            return;
        }
        if (c == 27 /* Esc */) {
            /* Exit fullscreen if fullscreen; close otherwise. */
            [controller handleEscape];
            return;
        }
        if (c == 'q' || c == 'Q') {
            [controller closePlayer];
            return;
        }
        if (c == ' ') {
            [controller togglePause];
            return;
        }
        /* mplayer-style seek bindings. */
        if (c == NSRightArrowFunctionKey) {
            [controller seekBy:+15.0];
            return;
        }
        if (c == NSLeftArrowFunctionKey) {
            [controller seekBy:-15.0];
            return;
        }
        if (c == NSUpArrowFunctionKey) {
            [controller seekBy:+60.0];
            return;
        }
        if (c == NSDownArrowFunctionKey) {
            [controller seekBy:-60.0];
            return;
        }
    }
    [super keyDown:event];
}

@end
