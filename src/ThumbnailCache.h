//
//  ThumbnailCache.h
//  TigerTube
//
//  In-memory NSImage cache for YouTube video thumbnails.  Owns its own
//  persistent CURL handle pointed at i.ytimg.com so the TLS session is
//  reused across fetches.  A dedicated worker thread pulls requests off
//  a serial queue so the main thread never blocks on network I/O.
//

#ifndef THUMBNAIL_CACHE_H
#define THUMBNAIL_CACHE_H

#import <Cocoa/Cocoa.h>
#import "TigerCompat.h"
#include <curl/curl.h>

@class ThumbnailCache;

@protocol ThumbnailCacheDelegate
- (void)thumbnailCache:(ThumbnailCache*)cache
    didLoadImageForVideoId:(NSString*)videoId;
@end

@interface ThumbnailCache : NSObject {
    NSString* caBundlePath;
    CURL* curl;                   /* worker-thread-only after init */
    NSMutableDictionary* images;  /* main-thread only: videoId -> NSImage */
    NSMutableSet* pending;        /* main-thread only: videoIds in flight */
    NSMutableArray* queue;        /* lock-protected: of NSDictionary */
    NSConditionLock* lock;        /* 0 = queue empty, 1 = work available */
    id delegate;                  /* weak */
}

- (id)initWithCABundlePath:(NSString*)caPath;
- (void)setDelegate:(id)d;

/* Main thread.  Returns the cached NSImage if present; otherwise returns
 * nil and schedules a background fetch.  When the fetch completes the
 * delegate is notified on the main thread. */
- (NSImage*)imageForVideoId:(NSString*)videoId url:(NSString*)url;

@end

#endif
