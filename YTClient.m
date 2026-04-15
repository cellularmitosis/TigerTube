//
//  YTClient.m
//  TigerTube
//

#import "YTClient.h"
#import "JSON.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Growable buffer for libcurl's write callback. */
struct YTBuffer {
    char* data;
    size_t size;
};

static size_t YTWriteCallback(void* ptr, size_t size, size_t nmemb, void* userdata) {
    size_t realsize = size * nmemb;
    struct YTBuffer* buf = (struct YTBuffer*)userdata;
    char* newdata = (char*)realloc(buf->data, buf->size + realsize + 1);
    if (newdata == NULL) {
        return 0;
    }
    buf->data = newdata;
    memcpy(buf->data + buf->size, ptr, realsize);
    buf->size += realsize;
    buf->data[buf->size] = '\0';
    return realsize;
}

@interface YTClient (Private)
- (NSString*)urlEncode:(NSString*)s;
- (NSString*)httpGet:(NSString*)url bytes:(size_t*)outBytes;
@end

@implementation YTClient

- (id)initWithAPIKey:(NSString*)key caBundlePath:(NSString*)caPath {
    self = [super init];
    if (self != nil) {
        apiKey = [key retain];
        caBundlePath = [caPath retain];
        curl = curl_easy_init();
        if (curl == NULL) {
            [self release];
            return nil;
        }
        /* Options that don't change per-request. */
        curl_easy_setopt(curl, CURLOPT_CAINFO, [caBundlePath UTF8String]);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, YTWriteCallback);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "TigerTube/0.1");
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    }
    return self;
}

- (void)dealloc {
    if (curl != NULL) {
        curl_easy_cleanup(curl);
        curl = NULL;
    }
    [apiKey release];
    [caBundlePath release];
    [super dealloc];
}

- (NSString*)urlEncode:(NSString*)s {
    const char* utf = [s UTF8String];
    char* esc = curl_easy_escape(curl, utf, 0);
    if (esc == NULL) {
        return s;
    }
    NSString* result = [NSString stringWithUTF8String:esc];
    curl_free(esc);
    return result;
}

- (NSString*)httpGet:(NSString*)url bytes:(size_t*)outBytes {
    struct YTBuffer buf;
    buf.data = (char*)malloc(1);
    buf.size = 0;
    buf.data[0] = '\0';

    curl_easy_setopt(curl, CURLOPT_URL, [url UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void*)&buf);

    CURLcode res = curl_easy_perform(curl);
    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);

    if (res != CURLE_OK) {
        fprintf(stderr, "YTClient: curl_easy_perform: %s\n", curl_easy_strerror(res));
        free(buf.data);
        return nil;
    }
    if (httpCode != 200) {
        fprintf(stderr, "YTClient: HTTP %ld\n", httpCode);
        fprintf(stderr, "body: %.*s\n", (int)buf.size, buf.data);
        free(buf.data);
        return nil;
    }

    if (outBytes != NULL) {
        *outBytes = buf.size;
    }

    NSString* body = [[[NSString alloc] initWithBytes:buf.data
                                                length:buf.size
                                              encoding:NSUTF8StringEncoding] autorelease];
    free(buf.data);
    return body;
}

- (NSArray*)searchVideos:(NSString*)query maxResults:(int)maxResults {
    NSString* encoded = [self urlEncode:query];
    NSString* searchURL = [NSString stringWithFormat:
        @"https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&maxResults=%d&q=%@&key=%@",
        maxResults, encoded, apiKey];

    /* --- /search: fetch --- */
    size_t searchBytes = 0;
    NSDate* t0 = [NSDate date];
    NSString* searchBody = [self httpGet:searchURL bytes:&searchBytes];
    NSTimeInterval dtFetch = -[t0 timeIntervalSinceNow];
    fprintf(stderr, "[search]  fetch: %6.2fs  %6lu bytes\n",
            dtFetch, (unsigned long)searchBytes);
    if (searchBody == nil) {
        return nil;
    }

    /* --- /search: parse --- */
    NSDate* t1 = [NSDate date];
    id parsed = [searchBody JSONValue];
    NSTimeInterval dtParse = -[t1 timeIntervalSinceNow];
    fprintf(stderr, "[search]  parse: %6.2fs\n", dtParse);

    if (![parsed isKindOfClass:[NSDictionary class]]) {
        fprintf(stderr, "YTClient: search response was not a dict\n");
        return nil;
    }
    NSArray* items = [(NSDictionary*)parsed objectForKey:@"items"];
    if (![items isKindOfClass:[NSArray class]]) {
        fprintf(stderr, "YTClient: search response had no items array\n");
        return nil;
    }

    NSMutableArray* results = [NSMutableArray arrayWithCapacity:[items count]];
    NSMutableArray* videoIds = [NSMutableArray arrayWithCapacity:[items count]];
    NSEnumerator* itemEnum = [items objectEnumerator];
    NSDictionary* item;
    while ((item = [itemEnum nextObject]) != nil) {
        NSDictionary* idDict = [item objectForKey:@"id"];
        NSDictionary* snippet = [item objectForKey:@"snippet"];
        if (![idDict isKindOfClass:[NSDictionary class]]) continue;
        if (![snippet isKindOfClass:[NSDictionary class]]) continue;
        NSString* vid = [idDict objectForKey:@"videoId"];
        NSString* title = [snippet objectForKey:@"title"];
        NSString* channel = [snippet objectForKey:@"channelTitle"];
        if (vid == nil || title == nil || channel == nil) continue;

        NSMutableDictionary* row = [NSMutableDictionary dictionary];
        [row setObject:vid forKey:@"videoId"];
        [row setObject:title forKey:@"title"];
        [row setObject:channel forKey:@"channelTitle"];
        [results addObject:row];
        [videoIds addObject:vid];
    }

    if ([videoIds count] == 0) {
        return results;
    }

    /* --- /videos: fetch durations for all ids in one call --- */
    NSString* idsCSV = [videoIds componentsJoinedByString:@","];
    NSString* videosURL = [NSString stringWithFormat:
        @"https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=%@&key=%@",
        idsCSV, apiKey];

    size_t videosBytes = 0;
    NSDate* t2 = [NSDate date];
    NSString* videosBody = [self httpGet:videosURL bytes:&videosBytes];
    NSTimeInterval dtVFetch = -[t2 timeIntervalSinceNow];
    fprintf(stderr, "[videos]  fetch: %6.2fs  %6lu bytes\n",
            dtVFetch, (unsigned long)videosBytes);
    if (videosBody == nil) {
        return results;
    }

    NSDate* t3 = [NSDate date];
    id videosParsed = [videosBody JSONValue];
    NSTimeInterval dtVParse = -[t3 timeIntervalSinceNow];
    fprintf(stderr, "[videos]  parse: %6.2fs\n", dtVParse);

    if (![videosParsed isKindOfClass:[NSDictionary class]]) {
        return results;
    }
    NSArray* videoItems = [(NSDictionary*)videosParsed objectForKey:@"items"];
    if (![videoItems isKindOfClass:[NSArray class]]) {
        return results;
    }

    NSMutableDictionary* durations = [NSMutableDictionary dictionary];
    NSEnumerator* vitemEnum = [videoItems objectEnumerator];
    NSDictionary* vitem;
    while ((vitem = [vitemEnum nextObject]) != nil) {
        NSString* vid = [vitem objectForKey:@"id"];
        NSDictionary* details = [vitem objectForKey:@"contentDetails"];
        if (vid == nil || ![details isKindOfClass:[NSDictionary class]]) continue;
        NSString* duration = [details objectForKey:@"duration"];
        if (duration != nil) {
            [durations setObject:duration forKey:vid];
        }
    }

    NSEnumerator* resultEnum = [results objectEnumerator];
    NSMutableDictionary* row;
    while ((row = [resultEnum nextObject]) != nil) {
        NSString* vid = [row objectForKey:@"videoId"];
        NSString* duration = [durations objectForKey:vid];
        if (duration != nil) {
            [row setObject:duration forKey:@"duration"];
        }
    }

    return results;
}

@end
