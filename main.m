//
//  main.m
//  TigerTube
//
//  Feasibility harness: performs a real YouTube Data API v3 search directly
//  from Tiger and reports per-phase wall-clock timing.  This lets us decide
//  whether the G3 can drive the API directly or whether API calls need to
//  go through the transcoding proxy.
//

#import <Cocoa/Cocoa.h>
#import "YTClient.h"
#import "Secrets.h"
#include <stdio.h>
#include <curl/curl.h>

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    /* Locate the bundled CA bundle. */
    NSString *caPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (caPath == nil) {
        fprintf(stderr, "FAIL: cacert.pem not found in bundle\n");
        [pool release];
        return 1;
    }

    curl_global_init(CURL_GLOBAL_DEFAULT);

    NSString *apiKey = [NSString stringWithUTF8String:YOUTUBE_API_KEY];
    YTClient *client = [[[YTClient alloc] initWithAPIKey:apiKey
                                            caBundlePath:caPath] autorelease];
    if (client == nil) {
        fprintf(stderr, "FAIL: YTClient init failed\n");
        curl_global_cleanup();
        [pool release];
        return 1;
    }

    /* Default query -- override with argv if supplied. */
    NSString *query = @"tiger powerpc mac";
    int maxResults = 25;
    if (argc >= 2) {
        query = [NSString stringWithUTF8String:argv[1]];
    }
    if (argc >= 3) {
        maxResults = atoi(argv[2]);
        if (maxResults < 1) maxResults = 1;
        if (maxResults > 50) maxResults = 50;
    }

    printf("=== TigerTube YouTube API feasibility test ===\n");
    printf("query:      \"%s\"\n", [query UTF8String]);
    printf("maxResults: %d\n\n", maxResults);
    fflush(stdout);

    NSDate *t0 = [NSDate date];
    NSArray *results = [client searchVideos:query maxResults:maxResults];
    NSTimeInterval total = -[t0 timeIntervalSinceNow];

    if (results == nil) {
        fprintf(stderr, "FAIL: searchVideos returned nil\n");
        curl_global_cleanup();
        [pool release];
        return 1;
    }

    fprintf(stderr, "\n=== total: %.2fs for %d results ===\n\n",
            total, (int)[results count]);
    fflush(stderr);

    int i = 0;
    NSEnumerator *e = [results objectEnumerator];
    NSDictionary *row;
    while ((row = [e nextObject]) != nil) {
        i++;
        NSString *title = [row objectForKey:@"title"];
        NSString *channel = [row objectForKey:@"channelTitle"];
        NSString *duration = [row objectForKey:@"duration"];
        printf("%2d. [%-9s] %s\n", i,
               duration ? [duration UTF8String] : "???",
               [title UTF8String]);
        printf("              -- %s\n", [channel UTF8String]);
    }

    curl_global_cleanup();
    [pool release];
    return 0;
}
