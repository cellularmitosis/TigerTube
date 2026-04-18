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
#import "TTScrubSlider.h"

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
    double startTime;              /* seconds into the video for the
                                      current fetch batch.  Absolute
                                      position = startTime + samplesPlayed/44100. */
    volatile BOOL videoStreamDone;
    volatile BOOL audioStreamDone;
    volatile BOOL stopRequested;
@private
    NSWindow* window;              /* strong */
    TTPlayerView* playerView;      /* weak (retained by current window) */
    NSWindow* fullscreenWindow;    /* strong, nil when windowed */
    BOOL isFullscreen;
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
    int duration;                  /* total seconds, 0 if unknown */
    int initialWidth;              /* user-selected resolution, used to
                                      size the window before the first
                                      decoded frame arrives */
    int initialHeight;
    BOOL initialVSync;             /* user-selected vsync, applied to the
                                      GL context right after the view is
                                      created */
    volatile BOOL seeking;         /* drop repeated arrow-key presses
                                      while a seek is still in flight */
    volatile BOOL paused;          /* spacebar pause: AU is stopped, the
                                      audio clock is frozen, displayTimer
                                      early-returns.  Fetch threads block
                                      naturally on ring-full / queue-full. */

    /* Transport bar (windowed only -- bar lives on the titled window;
       fullscreen reparents the playerView to a borderless window and
       leaves the bar invisible behind). */
    NSView* bar;                   /* strong (retained by content view) */
    NSButton* playButton;          /* weak (retained by bar) */
    TTScrubSlider* scrubSlider;    /* weak (retained by bar) */
    NSTextField* timeLabel;        /* weak (retained by bar) */

    /* Frame accounting / stats */
    unsigned long framesDisplayed;   /* frames actually pushed to GL */
    unsigned long framesDropped;     /* source-timeline frames that never
                                        reached the screen (includes both
                                        decoder stalls and queue-overflow
                                        drops).  Derived each display tick
                                        from the audio clock -- see
                                        computeDrops below. */
    unsigned long framesDroppedBanked;   /* framesDropped value snapshotted
                                            at the start of the current
                                            segment (just-after-seek).
                                            Per-segment drops are added on
                                            top. */
    unsigned long framesDisplayedAtSeek; /* framesDisplayed at the start of
                                            the current segment, so the
                                            derived drops formula can take
                                            "displayed since seek" rather
                                            than the cumulative. */
    unsigned long segmentDropsHighWater; /* max currentSegmentDrops seen so
                                            far this segment.  Latched
                                            monotonic so the surface counter
                                            never decreases on transient
                                            queueCount dips (it oscillates
                                            0..3 between display ticks and
                                            decoder pushes). */
    unsigned long samplesAtSegmentStart; /* samplesPlayed at the moment the
                                            first frame of this segment
                                            actually displays.  Used as the
                                            audio-clock baseline for drop
                                            accounting so the startup gap
                                            (audio ring fills before the
                                            decoder produces its first
                                            post-seek frame) doesn't get
                                            counted as CPU-bound drops.
                                            ULONG_MAX = not yet snapshotted
                                            for this segment. */
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

    /* Skip-decode state.  When the decoder falls too far behind the
       audio clock, we flip libmpeg2 to TT_SKIP_PB (I-frames only) so
       it can catch up; once caught up we flip back to TT_SKIP_NONE.
       Hysteresis thresholds live at file scope in the .m.  Decision
       logic is in -videoDecoder:didDecodeFrame:. */
    int decoderSkipMode;
}

/* Create and show a player window for the given video.
   baseURL is the proxy base like "http://192.168.1.240:5002".
   videoId is the YouTube video ID (or "file" for local files). */
- (id)initWithTitle:(NSString*)title
            videoURL:(NSString*)vURL
            audioURL:(NSString*)aURL
            duration:(int)durSec
               width:(int)w
              height:(int)h
               vsync:(BOOL)vsync;
- (void)dealloc;

/* Start playback. */
- (void)play;

/* Stop playback and close. */
- (void)stop;

/* Key-event entry points called by TTPlayerView. */
- (void)toggleFullscreen;
- (void)handleEscape;
- (void)closePlayer;

/* Seek by delta seconds relative to current audio clock position.
   Positive = forward, negative = backward; clamps at 0.  mplayer-style
   keyboard bindings: left/right = +/-15s, up/down = +/-60s. */
- (void)seekBy:(double)delta;

/* Toggle pause/resume.  Spacebar binding from TTPlayerView. */
- (void)togglePause;

/* Transport-bar action methods. */
- (void)playButtonClicked:(id)sender;
- (void)scrubDidFire:(id)sender;

/* Accessors for the owner (AppController) to poll and surface in UI. */
- (NSWindow*)window;
- (unsigned long)framesDropped;

@end

#endif
