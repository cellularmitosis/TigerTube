//
//  TTPlayerWindowController.m
//  TigerTube
//

#import "TTPlayerWindowController.h"
#import <Carbon/Carbon.h> /* SetSystemUIMode */
#include <pthread.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <curl/curl.h>

/* Borderless NSWindow subclass that's allowed to become key.
   Default NSWindow returns NO from -canBecomeKeyWindow for borderless
   style, which would leave -makeKeyAndOrderFront: a no-op and starve
   our fullscreen view of keyDown: events. */
@interface TTFullscreenWindow : NSWindow
@end

@implementation TTFullscreenWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

/* Wall-clock seconds since the epoch. */
static double ttWallSec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

/* Sum of user + system CPU seconds for this process across all threads. */
static double ttCpuSec(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double u = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1000000.0;
    double s = (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1000000.0;
    return u + s;
}

/* ---- curl write callback ---- */

static size_t curlWriteVideo(void* ptr, size_t size, size_t nmemb, void* userdata);
static size_t curlWriteAudio(void* ptr, size_t size, size_t nmemb, void* userdata);

/* ---- Thread entry points ---- */

static void* videoThreadFunc(void* arg);
static void* audioThreadFunc(void* arg);

@interface TTPlayerWindowController (Private)
- (void)buildWindow;
- (void)displayTimerFired:(NSTimer*)timer;
- (void)streamDidEnd;
@end

@implementation TTPlayerWindowController

- (id)initWithTitle:(NSString*)title
            videoURL:(NSString*)vURL
            audioURL:(NSString*)aURL
{
    self = [super init];
    if (self != nil) {
        videoTitle = [title copy];
        videoURL = [vURL copy];
        audioURL = [aURL copy];
        startTime = 0;

        videoDecoder = [[TTVideoDecoder alloc] init];
        if (videoDecoder == nil) {
            fprintf(stderr, "TTPlayerWindowController: decoder init failed\n");
            [self release];
            return nil;
        }
        [videoDecoder setDelegate:self];

        audioPlayer = [[TTAudioPlayer alloc] initWithSampleRate:44100.0
                                                       channels:2];
        if (audioPlayer == nil) {
            fprintf(stderr, "TTPlayerWindowController: audio init failed\n");
            [self release];
            return nil;
        }

        {
            int i;
            for (i = 0; i < TT_FRAME_QUEUE_SIZE; i++) {
                frameSlots[i] = NULL;
            }
        }
        frameWidth = 0;
        frameHeight = 0;
        frameStride = 0;
        queueHead = 0;
        queueTail = 0;
        queueCount = 0;
        pthread_mutex_init(&queueMutex, NULL);
        pthread_cond_init(&queueNotFull, NULL);
        texSetup = NO;
        videoStreamDone = NO;
        audioStreamDone = NO;
        stopRequested = NO;
        seeking = NO;
        paused = NO;
        displayTimer = nil;
        fullscreenWindow = nil;
        isFullscreen = NO;

        framesDisplayed = 0;
        framesDropped = 0;
        statsWall0 = 0;
        statsCpu0 = 0;
        statsWallLast = 0;
        statsCpuLast = 0;
        statsDecLast = 0;
        statsDispLast = 0;
        firstDecodeLogged = NO;
        firstDisplayLogged = NO;

        tickLastWall = 0;
        tickCount = 0;
        tickIntervalSum = 0;
        tickIntervalMax = 0;
        glTimeSum = 0;
        glTimeMax = 0;
        glTickCount = 0;
        otherTimeSum = 0;

        [self buildWindow];
    }
    return self;
}

- (void)dealloc {
    [self stop]; /* also exits fullscreen if needed */
    [videoDecoder release];
    [audioPlayer release];
    [videoURL release];
    [audioURL release];
    [videoTitle release];
    [window release];
    [fullscreenWindow release]; /* usually nil; safety net */
    {
        int i;
        for (i = 0; i < TT_FRAME_QUEUE_SIZE; i++) {
            if (frameSlots[i] != NULL) {
                free(frameSlots[i]);
            }
        }
    }
    pthread_cond_destroy(&queueNotFull);
    pthread_mutex_destroy(&queueMutex);
    [super dealloc];
}

- (void)buildWindow {
    unsigned int style = NSTitledWindowMask
                       | NSClosableWindowMask
                       | NSMiniaturizableWindowMask
                       | NSResizableWindowMask;

    /* 320x240 content + some room for the title bar */
    NSRect contentRect = NSMakeRect(100, 100, 320, 240);
    window = [[NSWindow alloc] initWithContentRect:contentRect
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:(videoTitle != nil ? videoTitle : @"TigerTube Player")];
    [window setReleasedWhenClosed:NO];
    [window setDelegate:self];

    NSView* content = [window contentView];
    NSRect cb = [content bounds];

    playerView = [[TTPlayerView alloc] initWithFrame:cb];
    [playerView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [playerView setController:self];
    [content addSubview:playerView];
    [playerView release]; /* retained by superview */

    [window makeKeyAndOrderFront:nil];
    /* Make the player view first responder so keyDown: (f, ESC, q) fires. */
    [window makeFirstResponder:playerView];
}

#pragma mark - Fullscreen

/* Enter/exit fullscreen by moving the single playerView between the
   titled window and a borderless screen-sized window.  The GL context
   (and its uploaded texture) belong to the view, so they ride along
   across the move; an -[NSOpenGLContext update] after re-parenting
   rebinds the drawable to the new window's surface. */

- (void)enterFullscreen {
    if (isFullscreen) {
        return;
    }

    NSRect screenFrame = [[window screen] frame];
    fullscreenWindow = [[TTFullscreenWindow alloc]
                            initWithContentRect:screenFrame
                                      styleMask:NSBorderlessWindowMask
                                        backing:NSBackingStoreBuffered
                                          defer:NO];
    [fullscreenWindow setBackgroundColor:[NSColor blackColor]];
    [fullscreenWindow setLevel:NSScreenSaverWindowLevel];
    [fullscreenWindow setReleasedWhenClosed:NO];
    [fullscreenWindow setDelegate:self];

    /* Hide menu bar + Dock.  Carbon call; Cocoa's equivalent
       (NSApplicationPresentationHideMenuBar) is 10.6+. */
    SetSystemUIMode(kUIModeAllHidden, 0);

    /* Re-parent playerView.  Retain across removeFromSuperview
       because the titled window's content view is its current owner. */
    [playerView retain];
    [playerView removeFromSuperview];
    NSView* fsContent = [fullscreenWindow contentView];
    [playerView setFrame:[fsContent bounds]];
    [playerView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [fsContent addSubview:playerView];
    [playerView release]; /* now retained by fsContent */
    [[playerView openGLContext] update];
    [playerView reshape]; /* rebind glViewport/glOrtho to new size */

    [fullscreenWindow makeKeyAndOrderFront:nil];
    [fullscreenWindow makeFirstResponder:playerView];
    isFullscreen = YES;
}

- (void)exitFullscreen {
    if (!isFullscreen) {
        return;
    }

    [playerView retain];
    [playerView removeFromSuperview];
    NSView* wContent = [window contentView];
    [playerView setFrame:[wContent bounds]];
    [playerView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [wContent addSubview:playerView];
    [playerView release]; /* now retained by wContent */
    [[playerView openGLContext] update];
    [playerView reshape]; /* rebind glViewport/glOrtho to new size */

    [fullscreenWindow orderOut:nil];
    [fullscreenWindow release];
    fullscreenWindow = nil;

    SetSystemUIMode(kUIModeNormal, 0);

    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:playerView];
    isFullscreen = NO;
}

- (void)toggleFullscreen {
    if (isFullscreen) {
        [self exitFullscreen];
    } else {
        [self enterFullscreen];
    }
}

- (void)handleEscape {
    if (isFullscreen) {
        [self exitFullscreen];
    } else {
        [window close];
    }
}

- (void)closePlayer {
    /* 'q' from anywhere closes the player -- restore menu bar first
       if we're fullscreen, then close the titled window (which
       triggers windowWillClose -> stop). */
    if (isFullscreen) {
        [self exitFullscreen];
    }
    [window close];
}

- (void)togglePause {
    if (audioPlayer == nil || seeking) {
        return;
    }
    if (paused) {
        paused = NO;
        [audioPlayer start];
        fprintf(stderr, "player: resume\n");
    } else {
        paused = YES;
        [audioPlayer stop];
        fprintf(stderr, "player: pause\n");
    }
}

- (void)seekBy:(double)delta {
    /* Single-threaded: keyDown: runs on main, seekBy: is synchronous
       on main, so another arrow press can't arrive mid-seek.  The
       'seeking' flag is belt-and-suspenders for any future async
       caller. */
    if (seeking) {
        return;
    }
    if (audioPlayer == nil || videoDecoder == nil) {
        return;
    }
    seeking = YES;

    double current = startTime + (double)[audioPlayer samplesPlayed] / 44100.0;
    double target = current + delta;
    if (target < 0) {
        target = 0;
    }
    fprintf(stderr, "seek: %.2fs -> %.2fs (delta=%+.0fs)\n",
            current, target, delta);

    /* ---- Signal the fetch threads to exit. ----
       Three wake-up paths, one per place a thread might be blocked:
       - stopRequested: curl write callbacks return 0 on next call,
         causing curl_easy_perform to return CURLE_WRITE_ERROR
       - audioPlayer cancel: unsticks feedPCM if it's busy-waiting on
         a full ring (it is, whenever the ring has filled before seek)
       - queueNotFull broadcast: unsticks video decoder's delegate
         callback if it's blocked on a full frame queue
       NOTE: do NOT stop the audio unit here.  The render callback
       needs to keep draining the ring so feedPCM can make progress
       after being cancelled -- otherwise the old chunk it's mid-way
       through writing would still wedge.  We reset the unit below
       after the thread has confirmed exit. */
    stopRequested = YES;
    [audioPlayer cancel];
    pthread_mutex_lock(&queueMutex);
    pthread_cond_broadcast(&queueNotFull);
    pthread_mutex_unlock(&queueMutex);
    if (displayTimer != nil) {
        [displayTimer invalidate];
        displayTimer = nil;
    }

    /* Wait for both curl threads to exit.  With the three wake-up
       signals above, this is typically <100ms.  5s cap is a
       defensive backstop -- if we ever hit it, starting new fetch
       threads would race the zombies on the shared frame queue and
       ring buffer, so we abort playback entirely instead. */
    double waitStart = ttWallSec();
    while (!(videoStreamDone && audioStreamDone)) {
        if (ttWallSec() - waitStart > 5.0) {
            fprintf(stderr,
                "seek: ABORT -- fetch threads didn't exit in 5s "
                "(v=%d a=%d); closing player to avoid producer race\n",
                (int)videoStreamDone, (int)audioStreamDone);
            seeking = NO;
            [self closePlayer];
            return;
        }
        usleep(20000); /* 20 ms */
    }
    fprintf(stderr, "seek: fetch threads exited in %.2fs\n",
            ttWallSec() - waitStart);

    /* ---- Reset decoder + audio + frame queue. ---- */
    [audioPlayer reset]; /* also clears the cancel flag */
    [videoDecoder reset];
    pthread_mutex_lock(&queueMutex);
    queueHead = 0;
    queueTail = 0;
    queueCount = 0;
    pthread_mutex_unlock(&queueMutex);

    /* Keep texSetup = YES: dimensions haven't changed, the GL texture
       is still valid.  The window is also correctly sized. */

    /* Reset first-event diagnostics and the stats window baselines so
       the next printout doesn't show wrap-around deltas (framesDecoded
       just went back to 0). */
    firstDecodeLogged = NO;
    firstDisplayLogged = NO;
    statsWallLast = ttWallSec();
    statsCpuLast = ttCpuSec();
    statsDecLast = 0;
    statsDispLast = framesDisplayed;
    tickLastWall = 0;
    tickCount = 0;
    tickIntervalSum = 0;
    tickIntervalMax = 0;
    glTimeSum = 0;
    glTimeMax = 0;
    glTickCount = 0;
    otherTimeSum = 0;

    /* ---- Relaunch fetch at the new position. ---- */
    startTime = target;
    stopRequested = NO;
    videoStreamDone = NO;
    audioStreamDone = NO;

    [self retain];
    [self retain];

    pthread_t videoTid, audioTid;
    pthread_create(&videoTid, NULL, videoThreadFunc, self);
    pthread_detach(videoTid);
    pthread_create(&audioTid, NULL, audioThreadFunc, self);
    pthread_detach(audioTid);

    displayTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                    target:self
                                                  selector:@selector(displayTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES];

    seeking = NO;
}

#pragma mark - Playback control

- (void)play {
    stopRequested = NO;
    videoStreamDone = NO;
    audioStreamDone = NO;

    statsWall0 = ttWallSec();
    statsCpu0 = ttCpuSec();
    statsWallLast = statsWall0;
    statsCpuLast = statsCpu0;
    statsDecLast = 0;
    statsDispLast = 0;

    /* Retain self for the duration of the background threads */
    [self retain];
    [self retain];

    pthread_t videoTid, audioTid;
    pthread_create(&videoTid, NULL, videoThreadFunc, self);
    pthread_detach(videoTid);
    pthread_create(&audioTid, NULL, audioThreadFunc, self);
    pthread_detach(audioTid);

    /* Start a timer to pull decoded frames and display them.
       ~30 Hz is plenty for 24fps video and keeps CPU overhead low. */
    displayTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                    target:self
                                                  selector:@selector(displayTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)stop {
    /* If we're tearing down while fullscreen (e.g. AppleScript quit
       or streamDidEnd), restore the menu bar so the user isn't left
       with hidden chrome. */
    if (isFullscreen) {
        [self exitFullscreen];
    }

    /* Log playback stats the first time stop is called.  Guard on
       displayTimer != nil so we only log once (stop is idempotent --
       windowWillClose: and streamDidEnd: may both call it). */
    if (displayTimer != nil) {
        double wall = ttWallSec() - statsWall0;
        double cpu = ttCpuSec() - statsCpu0;
        unsigned long decTotal = [videoDecoder framesDecoded];
        double audioSec = 0;
        if (audioPlayer != nil) {
            audioSec = (double)[audioPlayer samplesPlayed] / 44100.0;
        }
        fprintf(stderr,
            "player stats: wall=%.1fs audio=%.1fs decoded=%lu displayed=%lu dropped=%lu cpu=%.1fs (%.0f%%)\n",
            wall, audioSec, decTotal, framesDisplayed, framesDropped,
            cpu, wall > 0 ? (cpu / wall) * 100.0 : 0.0);
    }

    stopRequested = YES;
    /* Wake any decoder thread blocked on the frame-queue cond. */
    pthread_mutex_lock(&queueMutex);
    pthread_cond_broadcast(&queueNotFull);
    pthread_mutex_unlock(&queueMutex);
    if (displayTimer != nil) {
        [displayTimer invalidate];
        displayTimer = nil;
    }
    [audioPlayer stop];
}

#pragma mark - TTVideoDecoderDelegate

- (void)videoDecoder:(TTVideoDecoder*)decoder
      didDecodeFrame:(const unsigned char*)uyvyData
               width:(unsigned int)w
              height:(unsigned int)h
              stride:(unsigned int)stride
{
    /* Called on the video network thread.  Enqueue into the 3-slot
       ring buffer; block on queueNotFull if the display timer is
       behind.  Blocking here propagates backpressure into the curl
       write callback -> TCP -> proxy ffmpeg. */
    unsigned int size = stride * h;

    pthread_mutex_lock(&queueMutex);

    /* First frame, or dims changed: (re)allocate all slots.  Any
       in-flight frames in the queue are dropped -- safe because the
       old size is wrong for them anyway. */
    if (frameSlots[0] == NULL || frameWidth != w || frameHeight != h) {
        int i;
        for (i = 0; i < TT_FRAME_QUEUE_SIZE; i++) {
            if (frameSlots[i] != NULL) {
                free(frameSlots[i]);
            }
            frameSlots[i] = (unsigned char*)malloc(size);
        }
        frameWidth = w;
        frameHeight = h;
        frameStride = stride;
        queueHead = 0;
        queueTail = 0;
        queueCount = 0;
    }

    /* Block while the queue is full.  stop wakes us via broadcast. */
    while (queueCount >= TT_FRAME_QUEUE_SIZE && !stopRequested) {
        pthread_cond_wait(&queueNotFull, &queueMutex);
    }
    if (stopRequested) {
        pthread_mutex_unlock(&queueMutex);
        return;
    }

    memcpy(frameSlots[queueTail], uyvyData, size);
    queueTail = (queueTail + 1) % TT_FRAME_QUEUE_SIZE;
    queueCount++;

    pthread_mutex_unlock(&queueMutex);

    if (!firstDecodeLogged) {
        firstDecodeLogged = YES;
        fprintf(stderr,
            "player: first decode at wall=%.3fs (fps=%.2f, %ux%u)\n",
            ttWallSec() - statsWall0, [videoDecoder fps], w, h);
    }

    /* Throttle the decode thread against the audio clock.
       Sleeping here blocks the curl write callback, which
       TCP-backpressures the proxy. */
    double fps = [videoDecoder fps];
    if (fps <= 0) {
        return;
    }

    /* Before audio starts, do NOT decode ahead -- hold whatever we've
       already decoded.  Otherwise the decoder races ahead of the audio
       stream's startup time, and when audio finally begins we're N
       seconds into the video while audio is still at 0.  The first
       frame is already in the queue above, so the display timer will
       show it immediately while we wait. */
    while (![audioPlayer isRunning] && !stopRequested) {
        usleep(20000); /* 20 ms */
    }
    if (stopRequested) {
        return;
    }

    /* Pace the decoder one frame at a time: keep at most ~40 ms of lead
       past the audio clock.  libmpeg2 runs at ~267 fps (11x real-time) on
       this G3, so without tight pacing it emits frames in bursts of 2-3
       before hitting the lookahead cap, then idles.  The single-slot
       frameBuffer loses all but the last frame in each burst, which is
       why display fps was half of decode fps.  Per-frame pacing produces
       one frame every ~42 ms, matched to the 30 Hz display timer. */
    double decodedTime = (double)[videoDecoder framesDecoded] / fps;
    double audioTime = (double)[audioPlayer samplesPlayed] / 44100.0;
    double targetLead = 0.040;
    if (decodedTime - audioTime > targetLead) {
        double sleepSec = decodedTime - audioTime - targetLead;
        usleep((unsigned long)(sleepSec * 1000000.0));
    }
}

#pragma mark - Display timer

- (void)displayTimerFired:(NSTimer*)timer {
    if (stopRequested) {
        [timer invalidate];
        displayTimer = nil;
        return;
    }
    if (paused) {
        /* Drop tick-cadence baseline so the first tick after resume
           doesn't report a giant interval. */
        tickLastWall = 0;
        return;
    }

    /* Tick-cadence instrumentation: interval since previous tick. */
    double tickStart = ttWallSec();
    if (tickLastWall > 0) {
        double iv = tickStart - tickLastWall;
        tickIntervalSum += iv;
        tickCount++;
        if (iv > tickIntervalMax) {
            tickIntervalMax = iv;
        }
    }
    tickLastWall = tickStart;
    double thisGlTime = 0;

    /* Set up the GL texture once we know the video dimensions. */
    if (!texSetup && [videoDecoder isSequenceReady]) {
        [playerView setupTextureWithWidth:[videoDecoder width]
                                   height:[videoDecoder height]];
        texSetup = YES;

        /* Resize window to match video aspect ratio */
        unsigned int vw = [videoDecoder width];
        unsigned int vh = [videoDecoder height];
        NSRect frame = [window frame];
        float titleBarH = frame.size.height - [[window contentView] bounds].size.height;
        frame.size.width = (float)vw;
        frame.size.height = (float)vh + titleBarH;
        [window setFrame:frame display:YES];
    }

    /* Start audio once BOTH:
       - the audio ring has buffered enough data, AND
       - the video decoder has produced at least one frame.
       If we start audio while video is still waiting for its first
       frame, the audio clock advances from 0 while the decoder is
       stalled; when video eventually catches up, it races through
       N seconds of frames to "catch" the audio clock, so the first
       frame the user sees has timecode ~N instead of 0. */
    if (![audioPlayer isRunning]
        && [videoDecoder framesDecoded] >= 1
        && [audioPlayer ringAvailable] > TT_AUDIO_RING_SIZE / 4)
    {
        fprintf(stderr,
            "player: audio start at wall=%.3fs (ring=%u bytes, decoded=%lu, displayed=%lu)\n",
            ttWallSec() - statsWall0, [audioPlayer ringAvailable],
            [videoDecoder framesDecoded], framesDisplayed);
        [audioPlayer start];
    }

    /* Non-blocking dequeue.  Holding the pointer past the unlock is
       safe: decoder won't overwrite this slot until queueHead advances,
       which only happens below after displayFrame: returns. */
    unsigned char* slot = NULL;
    unsigned int w = 0;
    unsigned int h = 0;
    unsigned int s = 0;
    pthread_mutex_lock(&queueMutex);
    if (queueCount > 0 && texSetup) {
        slot = frameSlots[queueHead];
        w = frameWidth;
        h = frameHeight;
        s = frameStride;
    }
    pthread_mutex_unlock(&queueMutex);

    if (slot != NULL) {
        double glT0 = ttWallSec();
        [playerView displayFrame:slot width:w height:h stride:s];
        thisGlTime = ttWallSec() - glT0;
        framesDisplayed++;
        glTimeSum += thisGlTime;
        glTickCount++;
        if (thisGlTime > glTimeMax) {
            glTimeMax = thisGlTime;
        }
        if (!firstDisplayLogged) {
            firstDisplayLogged = YES;
            fprintf(stderr,
                "player: first display at wall=%.3fs (decoded=%lu, gl took %.3fs)\n",
                ttWallSec() - statsWall0,
                [videoDecoder framesDecoded], thisGlTime);
        }

        /* Release the slot and wake the decoder if it's blocked. */
        pthread_mutex_lock(&queueMutex);
        queueHead = (queueHead + 1) % TT_FRAME_QUEUE_SIZE;
        queueCount--;
        pthread_cond_signal(&queueNotFull);
        pthread_mutex_unlock(&queueMutex);
    }

    /* Accumulate non-GL tick work (setTitle, audio-start check, etc.). */
    double tickEnd = ttWallSec();
    otherTimeSum += (tickEnd - tickStart) - thisGlTime;

    /* Periodic stats -- every ~0.5 seconds of wall time. */
    double nowWall = tickEnd;
    if (nowWall - statsWallLast >= 0.5) {
        double nowCpu = ttCpuSec();
        double dt = nowWall - statsWallLast;
        double dcpu = nowCpu - statsCpuLast;
        unsigned long decNow = [videoDecoder framesDecoded];
        unsigned long dec = decNow - statsDecLast;
        unsigned long dis = framesDisplayed - statsDispLast;
        unsigned int ringPct = 0;
        double audioSec = 0;
        if (audioPlayer != nil) {
            unsigned int avail = [audioPlayer ringAvailable];
            ringPct = (unsigned int)((avail * 100) / TT_AUDIO_RING_SIZE);
            audioSec = (double)[audioPlayer samplesPlayed] / 44100.0;
        }
        double decSec = 0;
        double fps = [videoDecoder fps];
        if (fps > 0) {
            decSec = (double)decNow / fps;
        }
        double tickAvgMs = (tickCount > 0)
            ? (tickIntervalSum / (double)tickCount) * 1000.0 : 0;
        double tickMaxMs = tickIntervalMax * 1000.0;
        double glAvgMs = (glTickCount > 0)
            ? (glTimeSum / (double)glTickCount) * 1000.0 : 0;
        double glMaxMs = glTimeMax * 1000.0;
        double otherAvgMs = (tickCount > 0)
            ? (otherTimeSum / (double)tickCount) * 1000.0 : 0;
        fprintf(stderr,
            "player: t=%.1fs dec=%.1ffps dis=%.1ffps drop=%lu cpu=%.0f%% ring=%u%% decT=%.2fs audT=%.2fs tick=%.1f/%.1fms gl=%.1f/%.1fms other=%.1fms\n",
            nowWall - statsWall0,
            (double)dec / dt, (double)dis / dt, framesDropped,
            (dcpu / dt) * 100.0, ringPct, decSec, audioSec,
            tickAvgMs, tickMaxMs, glAvgMs, glMaxMs, otherAvgMs);
        statsWallLast = nowWall;
        statsCpuLast = nowCpu;
        statsDecLast = decNow;
        statsDispLast = framesDisplayed;
        /* Reset tick-cadence accumulators for the next window. */
        tickCount = 0;
        tickIntervalSum = 0;
        tickIntervalMax = 0;
        glTimeSum = 0;
        glTimeMax = 0;
        glTickCount = 0;
        otherTimeSum = 0;
    }

    /* Check for end of streams. */
    if (videoStreamDone && audioStreamDone && [audioPlayer ringAvailable] == 0) {
        [self streamDidEnd];
    }
}

- (void)streamDidEnd {
    fprintf(stderr, "player: streams ended, stopping\n");
    /* Let the last audio buffer drain. */
    usleep(500000);
    [self stop];

    double totalSec = (double)[audioPlayer samplesPlayed] / 44100.0;
    fprintf(stderr, "player: played %.2f seconds, %lu video frames\n",
            totalSec, [videoDecoder framesDecoded]);
}

#pragma mark - NSWindow delegate

- (void)windowWillClose:(NSNotification*)note {
    /* Just stop playback.  The retains in -play are balanced by the
       curl-thread exits; AppController owns the strong reference and
       will release us on the next click (or dealloc). */
    [self stop];
}

@end

/* ---- curl write callbacks ---- */

static size_t curlWriteVideo(void* ptr, size_t size, size_t nmemb, void* userdata) {
    TTPlayerWindowController* ctrl = (TTPlayerWindowController*)userdata;
    size_t total = size * nmemb;
    if (ctrl->stopRequested) {
        return 0; /* abort transfer */
    }
    [ctrl->videoDecoder feedData:(const unsigned char*)ptr
                          length:(unsigned int)total];
    return total;
}

static size_t curlWriteAudio(void* ptr, size_t size, size_t nmemb, void* userdata) {
    TTPlayerWindowController* ctrl = (TTPlayerWindowController*)userdata;
    size_t total = size * nmemb;
    if (ctrl->stopRequested) {
        return 0; /* abort transfer */
    }
    [ctrl->audioPlayer feedPCM:(const unsigned char*)ptr
                        length:(unsigned int)total];
    return total;
}

/* ---- Thread functions ---- */

static void* videoThreadFunc(void* arg) {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    TTPlayerWindowController* ctrl = (TTPlayerWindowController*)arg;

    /* Append &t=T for seek.  Ignore t=0 to avoid proxy's HLS quirk
       (see build_video_cmd in tigertube-proxy.py). */
    NSString* fetchURL = ctrl->videoURL;
    if (ctrl->startTime > 0) {
        fetchURL = [NSString stringWithFormat:@"%@&t=%.2f",
                              ctrl->videoURL, ctrl->startTime];
    }

    fprintf(stderr, "video thread: starting fetch: %s\n",
            [fetchURL UTF8String]);

    CURL* curl = curl_easy_init();
    if (curl == NULL) {
        fprintf(stderr, "video thread: curl_easy_init failed\n");
        ctrl->videoStreamDone = YES;
        [ctrl release];
        [pool release];
        return NULL;
    }

    NSString* caPath = [[NSBundle mainBundle] pathForResource:@"cacert"
                                                       ofType:@"pem"];
    curl_easy_setopt(curl, CURLOPT_URL, [fetchURL UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curlWriteVideo);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, ctrl);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    if (caPath != nil) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, [caPath UTF8String]);
    }

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK && res != CURLE_WRITE_ERROR) {
        fprintf(stderr, "video thread: curl error: %s\n",
                curl_easy_strerror(res));
    }

    curl_easy_cleanup(curl);
    ctrl->videoStreamDone = YES;
    fprintf(stderr, "video thread: done, %lu frames decoded\n",
            [ctrl->videoDecoder framesDecoded]);
    [ctrl release];
    [pool release];
    return NULL;
}

static void* audioThreadFunc(void* arg) {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    TTPlayerWindowController* ctrl = (TTPlayerWindowController*)arg;

    NSString* fetchURL = ctrl->audioURL;
    if (ctrl->startTime > 0) {
        fetchURL = [NSString stringWithFormat:@"%@&t=%.2f",
                              ctrl->audioURL, ctrl->startTime];
    }

    fprintf(stderr, "audio thread: starting fetch: %s\n",
            [fetchURL UTF8String]);

    CURL* curl = curl_easy_init();
    if (curl == NULL) {
        fprintf(stderr, "audio thread: curl_easy_init failed\n");
        ctrl->audioStreamDone = YES;
        [ctrl release];
        [pool release];
        return NULL;
    }

    NSString* caPath = [[NSBundle mainBundle] pathForResource:@"cacert"
                                                       ofType:@"pem"];
    curl_easy_setopt(curl, CURLOPT_URL, [fetchURL UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curlWriteAudio);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, ctrl);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    if (caPath != nil) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, [caPath UTF8String]);
    }

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK && res != CURLE_WRITE_ERROR) {
        fprintf(stderr, "audio thread: curl error: %s\n",
                curl_easy_strerror(res));
    }

    curl_easy_cleanup(curl);
    ctrl->audioStreamDone = YES;
    fprintf(stderr, "audio thread: done\n");
    [ctrl release];
    [pool release];
    return NULL;
}
