//
//  main.m
//  TigerTube
//

#import <Cocoa/Cocoa.h>
#import "JSON.h"
#include <stdio.h>
#include <string.h>
#include <curl/curl.h>

/* Buffer that grows as curl receives data. */
struct responseBuffer {
    char *data;
    size_t size;
};

static size_t writeCallback(void *ptr, size_t size, size_t nmemb, void *userdata)
{
    size_t realsize = size * nmemb;
    struct responseBuffer *buf = (struct responseBuffer *)userdata;
    char *newdata = (char *)realloc(buf->data, buf->size + realsize + 1);
    if (newdata == NULL) {
        return 0;
    }
    buf->data = newdata;
    memcpy(buf->data + buf->size, ptr, realsize);
    buf->size += realsize;
    buf->data[buf->size] = '\0';
    return realsize;
}

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
    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        fprintf(stderr, "FAIL: curl_easy_init returned NULL\n");
        curl_global_cleanup();
        [pool release];
        return 1;
    }

    struct responseBuffer buf;
    buf.data = (char *)malloc(1);
    buf.size = 0;
    buf.data[0] = '\0';

    const char *url = "https://rocketcal.cc/2561bed5d594db0698d99f3d35178ce3/2561bed5d594db0698d99f3d35178ce3.json";
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_CAINFO, [caPath UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&buf);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "SBJsonTest/1.0");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);

    CURLcode res = curl_easy_perform(curl);
    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);

    if (res != CURLE_OK) {
        fprintf(stderr, "FAIL: curl_easy_perform: %s\n", curl_easy_strerror(res));
        free(buf.data);
        curl_easy_cleanup(curl);
        curl_global_cleanup();
        [pool release];
        return 1;
    }
    printf("HTTP %ld, %lu bytes\n", httpCode, (unsigned long)buf.size);

    /* Wrap the response bytes in an NSString, then parse with SBJson. */
    NSString *body = [[[NSString alloc] initWithBytes:buf.data
                                               length:buf.size
                                             encoding:NSUTF8StringEncoding] autorelease];
    free(buf.data);
    curl_easy_cleanup(curl);
    curl_global_cleanup();

    if (body == nil) {
        fprintf(stderr, "FAIL: response was not valid UTF-8\n");
        [pool release];
        return 1;
    }

    id parsed = [body JSONValue];
    if (parsed == nil) {
        fprintf(stderr, "FAIL: SBJson could not parse the response\n");
        [pool release];
        return 1;
    }
    printf("parsed top-level type: %s\n", [[[parsed class] description] UTF8String]);

    /* Print a short summary of the structure. */
    if ([parsed isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)parsed;
        printf("top-level keys (%lu):\n", (unsigned long)[dict count]);
        NSEnumerator *keyEnum = [dict keyEnumerator];
        NSString *key;
        while ((key = [keyEnum nextObject]) != nil) {
            id value = [dict objectForKey:key];
            printf("  %s -> %s\n",
                   [key UTF8String],
                   [[[value class] description] UTF8String]);
        }

        NSArray *rockets = [dict objectForKey:@"auto_rockets"];
        if ([rockets isKindOfClass:[NSArray class]]) {
            printf("auto_rockets count: %lu\n", (unsigned long)[rockets count]);

            /* Pull a field out of the first rocket to prove we really walked the tree. */
            if ([rockets count] > 0) {
                NSDictionary *first = [rockets objectAtIndex:0];
                NSDictionary *groups = [first objectForKey:@"groups"];
                NSNumber *weight = [first objectForKey:@"weight"];
                printf("first rocket: weight=%.1f, groups=%lu\n",
                       [weight doubleValue],
                       (unsigned long)[groups count]);

                NSEnumerator *groupKeys = [groups keyEnumerator];
                NSString *groupKey;
                while ((groupKey = [groupKeys nextObject]) != nil) {
                    NSDictionary *group = [groups objectForKey:groupKey];
                    NSNumber *count = [group objectForKey:@"count"];
                    NSString *item = [group objectForKey:@"item"];
                    printf("  group %s: %d x %s\n",
                           [groupKey UTF8String],
                           [count intValue],
                           [item UTF8String]);
                }
            }
        }
    }

    [pool release];
    return 0;
}
