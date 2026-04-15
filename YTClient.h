//
//  YTClient.h
//  TigerTube
//
//  Minimal YouTube Data API v3 client.  Performs a /search query followed
//  by a batched /videos contentDetails call so each row has a duration.
//

#ifndef YT_CLIENT_H
#define YT_CLIENT_H

#import <Foundation/Foundation.h>
#import "TigerCompat.h"
#include <curl/curl.h>

@interface YTClient : NSObject {
    NSString *apiKey;
    NSString *caBundlePath;
    CURL *curl;
}

// caPath must point to a PEM CA bundle (e.g. the bundled cacert.pem).
- (id)initWithAPIKey:(NSString *)key caBundlePath:(NSString *)caPath;

// Returns an NSArray of NSDictionary.  Each dict has:
//   videoId       NSString
//   title         NSString
//   channelTitle  NSString
//   duration      NSString (ISO 8601, e.g. "PT3M45S") -- may be absent
// Returns nil on error.  Prints per-phase timing to stderr.
- (NSArray *)searchVideos:(NSString *)query maxResults:(int)maxResults;

@end

#endif
