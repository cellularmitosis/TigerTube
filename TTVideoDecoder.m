//
//  TTVideoDecoder.m
//  TigerTube
//

#import "TTVideoDecoder.h"
#include <mpeg2dec/mpeg2.h>
#include <mpeg2dec/mpeg2convert.h>

@implementation TTVideoDecoder

- (id)init {
    self = [super init];
    if (self != nil) {
        mpeg2_accel(0);  /* no AltiVec on G3 */
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
    if (decoder != NULL) {
        mpeg2_reset((mpeg2dec_t*)decoder, 1);
    }
    sequenceReady = NO;
    framesDecoded = 0;
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
