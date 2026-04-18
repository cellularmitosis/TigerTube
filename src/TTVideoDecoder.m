//
//  TTVideoDecoder.m
//  TigerTube
//

#import "TTVideoDecoder.h"
#include <mpeg2dec/mpeg2.h>
#include <mpeg2dec/mpeg2convert.h>
#include <sys/sysctl.h>

@implementation TTVideoDecoder

- (id)init {
    self = [super init];
    if (self != nil) {
        /* Detect AltiVec via sysctl rather than MPEG2_ACCEL_DETECT:
           libmpeg2's PPC probe executes an AltiVec insn unguarded on
           Darwin, which SIGILLs on G3.  sysctl is safe on both. */
        static int accel_logged = 0;
        int has_altivec = 0;
        size_t sz = sizeof(has_altivec);
        sysctlbyname("hw.optional.altivec", &has_altivec, &sz, NULL, 0);
        uint32_t accel = has_altivec ? MPEG2_ACCEL_PPC_ALTIVEC : 0;
        mpeg2_accel(accel);
        if (!accel_logged) {
            fprintf(stderr, "TTVideoDecoder: mpeg2_accel=0x%x%s\n",
                    accel,
                    has_altivec ? " (AltiVec)" : " (none)");
            accel_logged = 1;
        }
        mpeg2dec_t* dec = mpeg2_init();
        if (dec == NULL) {
            fprintf(stderr, "TTVideoDecoder: mpeg2_init failed\n");
            [self release];
            return nil;
        }
        /* Ask libmpeg2 to convert decoded YUV to UYVY in-place.
           This saves us a manual YUV->UYVY pass and the output
           goes straight to GL_APPLE_ycbcr_422. */
        mpeg2_convert(dec, mpeg2convert_uyvy, NULL);
        decoder = dec;
        info = mpeg2_info(dec);
        vidWidth = 0;
        vidHeight = 0;
        sequenceReady = NO;
        delegate = nil;
        framesDecoded = 0;
    }
    return self;
}

- (void)dealloc {
    if (decoder != NULL) {
        mpeg2_close((mpeg2dec_t*)decoder);
        decoder = NULL;
    }
    [super dealloc];
}

- (void)setDelegate:(id <TTVideoDecoderDelegate>)d {
    delegate = d;
}

- (id <TTVideoDecoderDelegate>)delegate {
    return delegate;
}

- (void)feedData:(const unsigned char*)data length:(unsigned int)len {
    mpeg2dec_t* dec = (mpeg2dec_t*)decoder;
    const mpeg2_info_t* inf = (const mpeg2_info_t*)info;

    mpeg2_buffer(dec, (uint8_t*)data, (uint8_t*)data + len);

    mpeg2_state_t state;
    while ((state = mpeg2_parse(dec)) != STATE_BUFFER) {
        switch (state) {
        case STATE_SEQUENCE:
        case STATE_SEQUENCE_REPEATED:
        case STATE_SEQUENCE_MODIFIED:
            vidWidth = inf->sequence->width;
            vidHeight = inf->sequence->height;
            sequenceReady = YES;
            break;

        case STATE_SLICE:
        case STATE_END:
            if (inf->display_fbuf != NULL && sequenceReady) {
                framesDecoded++;
                if (delegate != nil) {
                    /* For UYVY, buf[0] is the packed UYVY plane.
                       Stride = width * 2 bytes (2 bytes per pixel). */
                    unsigned int stride = vidWidth * 2;
                    [delegate videoDecoder:self
                            didDecodeFrame:inf->display_fbuf->buf[0]
                                     width:vidWidth
                                    height:vidHeight
                                    stride:stride];
                }
            }
            break;

        case STATE_INVALID:
        case STATE_INVALID_END:
            /* Corrupted data; reset and keep going. */
            mpeg2_reset(dec, 0);
            break;

        default:
            break;
        }
    }
}

- (void)reset {
    /* mpeg2_reset(dec, 1) in libmpeg2 0.5.1 is supposed to release
       display buffers and restart parsing, but the mpeg2_convert hook
       installed at init time does not survive the reset reliably --
       the first frame after reset handed us a buf[0] pointing into an
       unmapped page, crashing the subsequent memcpy on the network
       thread.  Tearing down and recreating the decoder sidesteps the
       issue and is fast enough (<1ms) that it's not a perf concern
       for a user-initiated seek. */
    if (decoder != NULL) {
        mpeg2_close((mpeg2dec_t*)decoder);
        decoder = NULL;
    }
    mpeg2dec_t* dec = mpeg2_init();
    if (dec != NULL) {
        mpeg2_convert(dec, mpeg2convert_uyvy, NULL);
        decoder = dec;
        info = mpeg2_info(dec);
    } else {
        fprintf(stderr, "TTVideoDecoder: mpeg2_init failed during reset\n");
        info = NULL;
    }
    vidWidth = 0;
    vidHeight = 0;
    sequenceReady = NO;
    framesDecoded = 0;
}

- (void)setSkipMode:(int)mode {
    if (decoder != NULL) {
        mpeg2_skip((mpeg2dec_t*)decoder, mode);
    }
}

- (unsigned int)width {
    return vidWidth;
}

- (unsigned int)height {
    return vidHeight;
}

- (BOOL)isSequenceReady {
    return sequenceReady;
}

- (unsigned long)framesDecoded {
    return framesDecoded;
}

- (double)fps {
    const mpeg2_info_t* inf = (const mpeg2_info_t*)info;
    if (!sequenceReady || inf == NULL || inf->sequence == NULL) {
        return 0.0;
    }
    /* sequence->frame_period is in units of 1/27,000,000 second. */
    uint32_t p = inf->sequence->frame_period;
    if (p == 0) {
        return 0.0;
    }
    return 27000000.0 / (double)p;
}

@end
