//
//  TTPlayerWindowController.m
//  TigerTube
//

#import "TTPlayerWindowController.h"
#include <pthread.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <curl/curl.h>

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

        frameBuffer = NULL;
        frameWidth = 0;
        frameHeight = 0;
        frameStride = 0;
        frameReady = NO;
        texSetup = NO;
        videoStreamDone = NO;
        audioStreamDone = NO;
        stopRequested = NO;
        displayTimer = nil;

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

        [self buildWindow];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [videoDecoder release];
    [audioPlayer release];
    [videoURL release];
    [audioURL release];
    [videoTitle release];
    [window release];
    if (frameBuffer != NULL) {
        free(frameBuffer);
    }
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
    [content addSubview:playerView];
    [playerView release]; /* retained by superview */

    [window makeKeyAndOrderFront:nil];
    /* Make the player view first responder so keyDown: (q = quit) fires. */
    [window makeFirstResponder:playerView];
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
    /* Called on the video network thread.
       Copy the frame into our shared buffer. */
    unsigned int size = stride * h;
    if (frameBuffer == NULL || frameWidth != w || frameHeight != h) {
        if (frameBuffer != NULL) {
            free(frameBuffer);
        }
        frameBuffer = (unsigned char*)malloc(size);
        frameWidth = w;
        frameHeight = h;
        frameStride = stride;
    }
    /* If the previous frame hasn't been displayed yet, we're about to
       overwrite it -- count that as a drop. */
    if (frameReady) {
        framesDropped++;
    }
    memcpy(frameBuffer, uyvyData, size);
    frameReady = YES;

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
       frame is already copied to frameBuffer above, so the display
       timer will show it immediately while we wait. */
    while (![audioPlayer isRunning] && !stopRequested) {
        usleep(20000); /* 20 ms */
    }
    if (stopRequested) {
        return;
    }

    /* Audio is running -- cap lookahead to ~200 ms past the audio clock. */
    double decodedTime = (double)[videoDecoder framesDecoded] / fps;
    double audioTime = (double)[audioPlayer samplesPlayed] / 44100.0;
    double aheadBy = decodedTime - audioTime;
    if (aheadBy > 0.20) {
        double sleepSec = aheadBy - 0.10;
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

    /* Display the latest decoded frame if one is ready. */
    if (frameReady && texSetup) {
        frameReady = NO;
        double t0 = ttWallSec();
        [playerView displayFrame:frameBuffer
                           width:frameWidth
                          height:frameHeight
                          stride:frameStride];
        framesDisplayed++;
        if (!firstDisplayLogged) {
            firstDisplayLogged = YES;
            double dt = ttWallSec() - t0;
            fprintf(stderr,
                "player: first display at wall=%.3fs (decoded=%lu, gl took %.3fs)\n",
                ttWallSec() - statsWall0,
                [videoDecoder framesDecoded], dt);
        }
    }

    /* Update window title with playback time. */
    if ([audioPlayer isRunning]) {
        double sec = (double)[audioPlayer samplesPlayed] / 44100.0;
        int m = (int)(sec / 60.0);
        int s = (int)sec % 60;
        NSString* t = [NSString stringWithFormat:@"%@ - %d:%02d", videoTitle, m, s];
        [window setTitle:t];
    }

    /* Periodic stats -- every ~0.5 seconds of wall time. */
    double nowWall = ttWallSec();
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
        fprintf(stderr,
            "player: t=%.1fs dec=%.1ffps dis=%.1ffps drop=%lu cpu=%.0f%% ring=%u%% decT=%.2fs audT=%.2fs\n",
            nowWall - statsWall0,
            (double)dec / dt, (double)dis / dt, framesDropped,
            (dcpu / dt) * 100.0, ringPct, decSec, audioSec);
        statsWallLast = nowWall;
        statsCpuLast = nowCpu;
        statsDecLast = decNow;
        statsDispLast = framesDisplayed;
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

    fprintf(stderr, "video thread: starting fetch: %s\n",
            [ctrl->videoURL UTF8String]);

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
    curl_easy_setopt(curl, CURLOPT_URL, [ctrl->videoURL UTF8String]);
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

    fprintf(stderr, "audio thread: starting fetch: %s\n",
            [ctrl->audioURL UTF8String]);

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
    curl_easy_setopt(curl, CURLOPT_URL, [ctrl->audioURL UTF8String]);
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
