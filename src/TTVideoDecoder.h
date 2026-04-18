//
//  TTVideoDecoder.h
//  TigerTube
//
//  Thin wrapper around libmpeg2.  Feed it raw MPEG-1 elementary stream
//  bytes; it calls back with UYVY frames ready for GL upload.
//

#ifndef TT_VIDEO_DECODER_H
#define TT_VIDEO_DECODER_H

#import <Cocoa/Cocoa.h>
#import "TigerCompat.h"

/* Skip modes for setSkipMode:.  Values match libmpeg2's MPEG2_SKIP_*
   constants so the wrapper is a straight passthrough -- we expose our
   own names here so callers don't need to pull in mpeg2.h. */
#define TT_SKIP_NONE 0  /* decode everything (default) */
#define TT_SKIP_B    1  /* skip B frames */
#define TT_SKIP_PB   3  /* skip P and B; decode I only */

@class TTVideoDecoder;

@protocol TTVideoDecoderDelegate
- (void)videoDecoder:(TTVideoDecoder*)decoder
      didDecodeFrame:(const unsigned char*)uyvyData
               width:(unsigned int)width
              height:(unsigned int)height
              stride:(unsigned int)stride;
@end

@interface TTVideoDecoder : NSObject {
    void* decoder;         /* mpeg2dec_t*, typed void* to keep header clean */
    const void* info;      /* const mpeg2_info_t* */
    unsigned int vidWidth;
    unsigned int vidHeight;
    BOOL sequenceReady;
    id <TTVideoDecoderDelegate> delegate;  /* weak */
    unsigned long framesDecoded;
}

- (id)init;
- (void)dealloc;

- (void)setDelegate:(id <TTVideoDecoderDelegate>)d;
- (id <TTVideoDecoderDelegate>)delegate;

/* Feed raw MPEG-1 ES data.  Decoded frames are delivered via the
   delegate callback synchronously (on the caller's thread). */
- (void)feedData:(const unsigned char*)data length:(unsigned int)len;

/* Reset decoder state (call after a seek). */
- (void)reset;

/* Tell libmpeg2 which picture types to skip.  Pass TT_SKIP_NONE /
   TT_SKIP_B / TT_SKIP_PB.  Cheap; safe to call mid-stream. */
- (void)setSkipMode:(int)mode;

- (unsigned int)width;
- (unsigned int)height;
- (BOOL)isSequenceReady;
- (unsigned long)framesDecoded;
/* Frames per second from the MPEG sequence header.  0 until isSequenceReady. */
- (double)fps;

@end

#endif
