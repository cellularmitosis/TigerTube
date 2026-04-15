//
//  ThumbnailCache.m
//  TigerTube
//

#import "ThumbnailCache.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Growable buffer for libcurl's write callback. */
struct TCBuffer {
    char* data;
    size_t size;
};

static size_t TCWriteCallback(void* ptr, size_t size, size_t nmemb, void* userdata) {
    size_t realsize = size * nmemb;
    struct TCBuffer* buf = (struct TCBuffer*)userdata;
    char* newdata = (char*)realloc(buf->data, buf->size + realsize);
    if (newdata == NULL) {
        return 0;
    }
    buf->data = newdata;
    memcpy(buf->data + buf->size, ptr, realsize);
    buf->size += realsize;
    return realsize;
}

@interface ThumbnailCache (Private)
- (void)workerLoop:(id)unused;
- (void)imageDidArrive:(NSDictionary*)info;
@end

@implementation ThumbnailCache

- (id)initWithCABundlePath:(NSString*)caPath {
    self = [super init];
    if (self != nil) {
        caBundlePath = [caPath retain];
        images = [[NSMutableDictionary alloc] init];
        pending = [[NSMutableSet alloc] init];
        queue = [[NSMutableArray alloc] init];
        lock = [[NSConditionLock alloc] initWithCondition:0];

        curl = curl_easy_init();
        if (curl == NULL) {
            [self release];
            return nil;
        }
        curl_easy_setopt(curl, CURLOPT_CAINFO, [caBundlePath UTF8String]);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, TCWriteCallback);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "TigerTube/0.1");
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);

        [NSThread detachNewThreadSelector:@selector(workerLoop:)
                                 toTarget:self
                               withObject:nil];
    }
    return self;
}

- (void)dealloc {
    /* ThumbnailCache lives for the lifetime of the app; the worker thread
     * is intentionally not shut down here. */
    if (curl != NULL) {
        curl_easy_cleanup(curl);
    }
    [caBundlePath release];
    [images release];
    [pending release];
    [queue release];
    [lock release];
    [super dealloc];
}

- (void)setDelegate:(id)d {
    delegate = d;  /* weak */
}

- (NSImage*)imageForVideoId:(NSString*)videoId url:(NSString*)url {
    NSImage* img = [images objectForKey:videoId];
    if (img != nil) {
        return img;
    }
    if (url == nil) {
        return nil;
    }
    if ([pending containsObject:videoId]) {
        return nil;
    }
    [pending addObject:videoId];

    NSDictionary* item = [NSDictionary dictionaryWithObjectsAndKeys:
                          videoId, @"videoId",
                          url, @"url",
                          nil];

    [lock lock];
    [queue addObject:item];
    [lock unlockWithCondition:1];

    return nil;
}

- (void)workerLoop:(id)unused {
    while (1) {
        NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

        [lock lockWhenCondition:1];
        NSDictionary* item = [[queue objectAtIndex:0] retain];
        [queue removeObjectAtIndex:0];
        int nextCond = ([queue count] > 0) ? 1 : 0;
        [lock unlockWithCondition:nextCond];

        NSString* vid = [item objectForKey:@"videoId"];
        NSString* url = [item objectForKey:@"url"];

        struct TCBuffer buf;
        buf.data = (char*)malloc(1);
        buf.size = 0;

        curl_easy_setopt(curl, CURLOPT_URL, [url UTF8String]);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void*)&buf);

        NSDate* t0 = [NSDate date];
        CURLcode res = curl_easy_perform(curl);
        NSTimeInterval dt = -[t0 timeIntervalSinceNow];

        NSImage* img = nil;
        if (res == CURLE_OK && buf.size > 0) {
            NSData* data = [NSData dataWithBytes:buf.data length:buf.size];
            img = [[[NSImage alloc] initWithData:data] autorelease];
            fprintf(stderr, "[thumb] %s: %5.2fs  %6lu bytes\n",
                    [vid UTF8String], dt, (unsigned long)buf.size);
        } else {
            fprintf(stderr, "[thumb] %s: FAIL (%s)\n",
                    [vid UTF8String], curl_easy_strerror(res));
        }
        free(buf.data);

        NSMutableDictionary* result = [NSMutableDictionary dictionary];
        [result setObject:vid forKey:@"videoId"];
        if (img != nil) {
            [result setObject:img forKey:@"image"];
        }

        [self performSelectorOnMainThread:@selector(imageDidArrive:)
                               withObject:result
                            waitUntilDone:NO];

        [item release];
        [pool release];
    }
}

- (void)imageDidArrive:(NSDictionary*)info {
    NSString* vid = [info objectForKey:@"videoId"];
    NSImage* img = [info objectForKey:@"image"];
    [pending removeObject:vid];
    if (img != nil) {
        [images setObject:img forKey:vid];
        if (delegate != nil &&
            [delegate respondsToSelector:@selector(thumbnailCache:didLoadImageForVideoId:)])
        {
            [delegate thumbnailCache:self didLoadImageForVideoId:vid];
        }
    }
}

@end
