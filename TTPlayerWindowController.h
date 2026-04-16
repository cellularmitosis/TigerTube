//
//  TTPlayerWindowController.h
//  TigerTube
//
//  Orchestrates video playback: two HTTP streams (video ES + audio PCM),
//  libmpeg2 decode, UYVY GL rendering, CoreAudio output, A/V sync.
//

#ifndef TT_PLAYER_WINDOW_CONTROLLER_H
#define TT_PLAYER_WINDOW_CONTROLLER_H

#import <Cocoa/Cocoa.h>
#include <pthread.h>
#import "TigerCompat.h"
#import "TTVideoDecoder.h"
#import "TTAudioPlayer.h"
#import "TTPlayerView.h"

/* Depth of the decoder->display UYVY frame queue.  Needs to be at least
   2 so a single slow display tick doesn't starve the decoder into
   dropping.  3 gives a bit of headroom for GL spikes without adding
   noticeable latency (3 frames at 24fps = 125ms). */
#define TT_FRAME_QUEUE_SIZE 3

@interface TTPlayerWindowController : NSObject <TTVideoDecoderDelegate> {
@public
    /* @public: accessed from C thread functions and curl callbacks */
    TTVideoDecoder* videoDecoder;  /* strong */
    TTAudioPlayer* audioPlayer;    /* strong */
    NSString* videoURL;            /* strong */
    NSString* audioURL;            /* strong */
    volatile BOOL videoStreamDone;
    volatile BOOL audioStreamDone;
    volatile BOOL stopRequested;
@private
    NSWindow* window;              /* strong */
    TTPlayerView* playerView;      /* weak (retained by window) */
    NSTimer* displayTimer;         /* strong (retained by run loop) */

    /* Decoder -> display UYVY frame queue.  Decoder blocks on
       queueNotFull when all slots are in use; display timer
       non-blocking-dequeues and skips the tick when empty. */
    unsigned char* frameSlots[TT_FRAME_QUEUE_SIZE]; /* malloc'd UYVY buffers */
    unsigned int frameWidth;
    unsigned int frameHeight;
    unsigned int frameStride;
    unsigned int queueHead;        /* next slot to display */
    unsigned int queueTail;        /* next slot to fill */
    unsigned int queueCount;       /* full slots */
    pthread_mutex_t queueMutex;
    pthread_cond_t queueNotFull;   /* decoder waits on this when full */
    BOOL texSetup;                 /* texture created for this sequence */

    /* Playback info */
    NSString* videoTitle;          /* strong */
    double startTime;              /* seconds into the video to start */

    /* Frame accounting / stats */
    unsigned long framesDisplayed;   /* frames actually pushed to GL */
    unsigned long framesDropped;     /* decoded frames overwritten undisplayed */
    double statsWall0;               /* wall time at play start */
    double statsCpu0;                /* CPU seconds at play start */
    double statsWallLast;            /* wall time of last stats log */
    double statsCpuLast;             /* user+sys CPU seconds at last log */
    unsigned long statsDecLast;      /* framesDecoded at last log */
    unsigned long statsDispLast;     /* framesDisplayed at last log */
    BOOL firstDecodeLogged;          /* for first-decode diagnostic */
    BOOL firstDisplayLogged;         /* for first-display diagnostic */

    /* Tick-cadence instrumentation (reset every 0.5s stats window). */
    double tickLastWall;             /* wall time of previous tick start */
    unsigned int tickCount;          /* ticks since last stats print */
    double tickIntervalSum;          /* sum of tick intervals (sec) */
    double tickIntervalMax;          /* max tick interval (sec) */
    double glTimeSum;                /* sum of displayFrame: wall time (sec) */
    double glTimeMax;                /* max displayFrame: wall time (sec) */
    unsigned int glTickCount;        /* ticks that ran displayFrame: */
    double otherTimeSum;             /* sum of non-GL tick work (sec) */
}

/* Create and show a player window for the given video.
   baseURL is the proxy base like "http://192.168.1.240:5002".
   videoId is the YouTube video ID (or "file" for local files). */
- (id)initWithTitle:(NSString*)title
            videoURL:(NSString*)vURL
            audioURL:(NSString*)aURL;
- (void)dealloc;

/* Start playback. */
- (void)play;

/* Stop playback and close. */
- (void)stop;

@end

#endif
