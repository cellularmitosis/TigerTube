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

- (unsigned int)width;
- (unsigned int)height;
- (BOOL)isSequenceReady;
- (unsigned long)framesDecoded;
/* Frames per second from the MPEG sequence header.  0 until isSequenceReady. */
- (double)fps;

@end

#endif
