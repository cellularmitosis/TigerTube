//
//  TTAudioPlayer.m
//  TigerTube
//

#import "TTAudioPlayer.h"
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <unistd.h>

#define RING_MASK (TT_AUDIO_RING_SIZE - 1)

/* ---- C helpers for the ring buffer ---- */

static unsigned int ring_avail(volatile unsigned int wr, volatile unsigned int rd) {
    return wr - rd;
}

static void ring_read(unsigned char* ring, volatile unsigned int* rd,
                      unsigned char* out, unsigned int len) {
    unsigned int r = *rd;
    unsigned int i;
    for (i = 0; i < len; i++) {
        out[i] = ring[(r + i) & RING_MASK];
    }
    *rd = r + len;
}

/* ---- CoreAudio render callback ---- */

static OSStatus renderCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData)
{
    TTAudioPlayer* self = (TTAudioPlayer*)inRefCon;
    float* out = (float*)ioData->mBuffers[0].mData;
    unsigned int ch = self->channels;
    /* bytes per frame in the ring: channels * 2 (s16be) */
    unsigned int bpf = ch * 2;
    UInt32 framesNeeded = inNumberFrames;
    unsigned int bytesNeeded = framesNeeded * bpf;
    unsigned int avail = ring_avail(self->ringWr, self->ringRd);

    if (avail < bytesNeeded) {
        if (avail >= bpf) {
            bytesNeeded = (avail / bpf) * bpf;
            framesNeeded = bytesNeeded / bpf;
        } else {
            /* Underrun: silence */
            memset(out, 0, inNumberFrames * ch * sizeof(float));
            return noErr;
        }
    }

    /* Pull raw s16be bytes from ring */
    unsigned char raw[bytesNeeded];
    ring_read(self->ring, (volatile unsigned int*)&self->ringRd,
              raw, bytesNeeded);

    /* Convert s16be -> Float32.
       On PPC big-endian, s16be is native byte order. */
    unsigned int totalSamples = framesNeeded * ch;
    unsigned int i;
    for (i = 0; i < totalSamples; i++) {
        short s = (short)((raw[i * 2] << 8) | raw[i * 2 + 1]);
        out[i] = (float)s / 32768.0f;
    }

    /* Zero any remaining frames (underrun tail) */
    for (i = framesNeeded * ch; i < inNumberFrames * ch; i++) {
        out[i] = 0.0f;
    }

    self->samplesOut += framesNeeded;
    return noErr;
}

/* ---- Obj-C implementation ---- */

@implementation TTAudioPlayer

- (id)initWithSampleRate:(double)rate channels:(unsigned int)ch {
    self = [super init];
    if (self != nil) {
        sampleRate = rate;
        channels = ch;
        ringWr = 0;
        ringRd = 0;
        samplesOut = 0;
        running = NO;
        cancelled = NO;
        audioUnit = NULL;
        memset(ring, 0, TT_AUDIO_RING_SIZE);

        /* Set up Default Output AudioUnit */
        ComponentDescription desc;
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;

        Component comp = FindNextComponent(NULL, &desc);
        if (comp == NULL) {
            fprintf(stderr, "TTAudioPlayer: FindNextComponent failed\n");
            [self release];
            return nil;
        }

        AudioUnit au;
        OSStatus err = OpenAComponent(comp, &au);
        if (err != noErr) {
            fprintf(stderr, "TTAudioPlayer: OpenAComponent failed: %d\n", (int)err);
            [self release];
            return nil;
        }

        /* Set input format: Float32, big-endian, interleaved */
        AudioStreamBasicDescription fmt;
        memset(&fmt, 0, sizeof(fmt));
        fmt.mSampleRate = rate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kAudioFormatFlagIsFloat
                         | kAudioFormatFlagIsPacked
                         | kAudioFormatFlagIsBigEndian;
        fmt.mBytesPerPacket = ch * 4;
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerFrame = ch * 4;
        fmt.mChannelsPerFrame = ch;
        fmt.mBitsPerChannel = 32;

        err = AudioUnitSetProperty(au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &fmt, sizeof(fmt));
        if (err != noErr) {
            fprintf(stderr, "TTAudioPlayer: SetProperty StreamFormat failed: %d\n", (int)err);
            CloseComponent(au);
            [self release];
            return nil;
        }

        AURenderCallbackStruct cb;
        cb.inputProc = renderCallback;
        cb.inputProcRefCon = self;
        err = AudioUnitSetProperty(au,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &cb, sizeof(cb));
        if (err != noErr) {
            fprintf(stderr, "TTAudioPlayer: SetProperty RenderCallback failed: %d\n", (int)err);
            CloseComponent(au);
            [self release];
            return nil;
        }

        err = AudioUnitInitialize(au);
        if (err != noErr) {
            fprintf(stderr, "TTAudioPlayer: AudioUnitInitialize failed: %d\n", (int)err);
            CloseComponent(au);
            [self release];
            return nil;
        }

        audioUnit = au;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (audioUnit != NULL) {
        AudioUnitUninitialize((AudioUnit)audioUnit);
        CloseComponent((AudioUnit)audioUnit);
        audioUnit = NULL;
    }
    [super dealloc];
}

- (BOOL)start {
    if (running) {
        return YES;
    }
    if (audioUnit == NULL) {
        return NO;
    }
    OSStatus err = AudioOutputUnitStart((AudioUnit)audioUnit);
    if (err != noErr) {
        fprintf(stderr, "TTAudioPlayer: AudioOutputUnitStart failed: %d\n", (int)err);
        return NO;
    }
    running = YES;
    return YES;
}

- (void)stop {
    if (!running) {
        return;
    }
    if (audioUnit != NULL) {
        AudioOutputUnitStop((AudioUnit)audioUnit);
    }
    running = NO;
}

- (BOOL)isRunning {
    return running;
}

- (void)feedPCM:(const unsigned char*)data length:(unsigned int)len {
    unsigned int written = 0;
    while (written < len) {
        if (cancelled) {
            return;
        }
        unsigned int free = TT_AUDIO_RING_SIZE - ring_avail(ringWr, ringRd);
        if (free == 0) {
            usleep(1000);
            continue;
        }
        unsigned int chunk = len - written;
        if (chunk > free) {
            chunk = free;
        }
        unsigned int wr = ringWr;
        unsigned int i;
        for (i = 0; i < chunk; i++) {
            ring[(wr + i) & RING_MASK] = data[written + i];
        }
        ringWr = wr + chunk;
        written += chunk;
    }
}

- (void)cancel {
    cancelled = YES;
}

- (unsigned int)ringAvailable {
    return ring_avail(ringWr, ringRd);
}

- (unsigned int)ringFree {
    return TT_AUDIO_RING_SIZE - ring_avail(ringWr, ringRd);
}

- (unsigned long)samplesPlayed {
    return samplesOut;
}

- (void)reset {
    BOOL wasRunning = running;
    if (wasRunning) {
        [self stop];
    }
    ringWr = 0;
    ringRd = 0;
    samplesOut = 0;
    cancelled = NO;
    memset(ring, 0, TT_AUDIO_RING_SIZE);
    if (wasRunning) {
        [self start];
    }
}

@end
