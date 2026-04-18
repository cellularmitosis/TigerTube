//
//  YTClient.h
//  TigerTube
//
//  Minimal YouTube Data API v3 client.  Performs a /search query followed
//  by a batched /videos contentDetails+statistics call so each row has a
//  duration and view count.
//

#ifndef YT_CLIENT_H
#define YT_CLIENT_H

#import <Foundation/Foundation.h>
#import "TigerCompat.h"
#include <curl/curl.h>

@interface YTClient : NSObject {
    NSString* defaultAPIKey;
    NSString* caBundlePath;
    CURL* curl;

    /* Set by -currentAPIKey each time it's called, so -httpGet: can
       record which key was in use if the request fails. */
    BOOL currentKeyIsOverride;

    /* Populated on a failed searchVideos: call, cleared at the start
       of each call.  Accessors below. */
    int lastHTTPStatus;
    NSString* lastErrorReason;
    BOOL lastErrorUsedOverrideKey;
}

// caPath must point to a PEM CA bundle (e.g. the bundled cacert.pem).
- (id)initWithAPIKey:(NSString*)key caBundlePath:(NSString*)caPath;

// Returns an NSArray of NSDictionary.  Each dict has:
//   videoId       NSString
//   title         NSString
//   channelTitle  NSString
//   thumbnailURL  NSString -- may be absent
//   duration      NSString (ISO 8601, e.g. "PT3M45S") -- may be absent
//   viewCount     NSString (decimal, e.g. "12345678") -- may be absent
//   liveBroadcastContent  NSString ("live" or "upcoming") -- absent for
//                 regular VODs.  Livestreams have no meaningful
//                 duration, so UI should substitute a status label.
// Returns nil on error.  Prints per-phase timing to stderr.
- (NSArray*)searchVideos:(NSString*)query maxResults:(int)maxResults;

/* After a failed searchVideos:, these reflect the last HTTP response.
   Return 0 / nil / NO if the last call succeeded or failed non-HTTP. */
- (int)lastHTTPStatus;
- (NSString*)lastErrorReason;    /* e.g. "quotaExceeded", "keyInvalid" */
- (BOOL)lastErrorUsedOverrideKey;

@end

#endif
