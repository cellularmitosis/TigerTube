//
//  TTAudioPlayer.h
//  TigerTube
//
//  Plays raw s16be PCM through the Default Output AudioUnit.
//  Thread-safe: feedPCM is called from the network thread,
//  the render callback runs on CoreAudio's real-time thread.
//

#ifndef TT_AUDIO_PLAYER_H
#define TT_AUDIO_PLAYER_H

#import <Cocoa/Cocoa.h>
#import "TigerCompat.h"

/* Ring buffer size: 256 KB = ~1.5 sec at 44.1k stereo s16 */
#define TT_AUDIO_RING_SIZE (1 << 18)

@interface TTAudioPlayer : NSObject {
@public
    /* These are @public so the C render callback can access them
       directly via the inRefCon pointer without objc_msgSend. */
    unsigned char ring[TT_AUDIO_RING_SIZE];
    volatile unsigned int ringWr;
    volatile unsigned int ringRd;
    unsigned int channels;
    volatile unsigned long samplesOut;
@private
    void* audioUnit;     /* AudioUnit, typed void* to keep header clean */
    BOOL running;
    double sampleRate;
}

/* Init with sample rate (44100) and channel count (1 or 2). */
- (id)initWithSampleRate:(double)rate channels:(unsigned int)ch;
- (void)dealloc;

/* Start/stop the AudioUnit. */
- (BOOL)start;
- (void)stop;
- (BOOL)isRunning;

/* Feed raw s16be PCM from the network thread.
   Blocks (busy-waits with usleep) if the ring is full. */
- (void)feedPCM:(const unsigned char*)data length:(unsigned int)len;

/* Number of bytes available in the ring buffer. */
- (unsigned int)ringAvailable;

/* Number of free bytes in the ring buffer. */
- (unsigned int)ringFree;

/* Number of sample frames played so far (for the A/V clock). */
- (unsigned long)samplesPlayed;

/* Reset ring and sample counter (call after a seek). */
- (void)reset;

@end

#endif
