//
//  NSString+.m
//  TigerTube
//

#import "NSString+.h"
#include <stdio.h>

@implementation NSString (TigerTube)

- (NSString*)htmlDecoded {
    NSUInteger len = [self length];
    if (len == 0) {
        return self;
    }

    unichar* buf = (unichar*)malloc(sizeof(unichar) * len);
    [self getCharacters:buf range:NSMakeRange(0, len)];

    NSMutableString* out = [NSMutableString stringWithCapacity:len];
    NSUInteger i = 0;
    while (i < len) {
        unichar c = buf[i];
        if (c != '&') {
            [out appendFormat:@"%C", c];
            i++;
            continue;
        }

        /* Look for a ';' within the next 10 chars. */
        NSUInteger end = i + 1;
        while (end < len && (end - i) < 10 && buf[end] != ';') {
            end++;
        }
        if (end >= len || buf[end] != ';') {
            [out appendFormat:@"%C", c];
            i++;
            continue;
        }

        NSString* entity = [[[NSString alloc] initWithCharacters:buf + i + 1
                                                          length:end - i - 1]
                            autorelease];
        unichar replacement = 0;
        if ([entity isEqualToString:@"amp"]) {
            replacement = '&';
        } else if ([entity isEqualToString:@"lt"]) {
            replacement = '<';
        } else if ([entity isEqualToString:@"gt"]) {
            replacement = '>';
        } else if ([entity isEqualToString:@"quot"]) {
            replacement = '"';
        } else if ([entity isEqualToString:@"apos"]) {
            replacement = '\'';
        } else if ([entity length] > 1 && [entity characterAtIndex:0] == '#') {
            NSString* num = [entity substringFromIndex:1];
            int value = 0;
            if ([num length] > 1 &&
                ([num characterAtIndex:0] == 'x' || [num characterAtIndex:0] == 'X'))
            {
                sscanf([[num substringFromIndex:1] UTF8String], "%x", &value);
            } else {
                value = [num intValue];
            }
            if (value > 0) {
                replacement = (unichar)value;
            }
        }

        if (replacement != 0) {
            [out appendFormat:@"%C", replacement];
            i = end + 1;
        } else {
            /* Unknown entity: emit & and continue past it. */
            [out appendFormat:@"%C", c];
            i++;
        }
    }

    free(buf);
    return out;
}

- (NSString*)iso8601DurationDisplay {
    if ([self length] < 3 || ![self hasPrefix:@"PT"]) {
        return self;
    }

    const char* s = [self UTF8String];
    int hours = 0;
    int minutes = 0;
    int seconds = 0;
    int current = 0;
    int i;
    for (i = 2; s[i] != '\0'; i++) {
        char c = s[i];
        if (c >= '0' && c <= '9') {
            current = current * 10 + (c - '0');
        } else if (c == 'H') {
            hours = current;
            current = 0;
        } else if (c == 'M') {
            minutes = current;
            current = 0;
        } else if (c == 'S') {
            seconds = current;
            current = 0;
        }
    }

    if (hours > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", hours, minutes, seconds];
    }
    return [NSString stringWithFormat:@"%d:%02d", minutes, seconds];
}

- (int)iso8601DurationSeconds {
    if ([self length] < 3 || ![self hasPrefix:@"PT"]) {
        return 0;
    }
    const char* s = [self UTF8String];
    int hours = 0;
    int minutes = 0;
    int seconds = 0;
    int current = 0;
    int i;
    for (i = 2; s[i] != '\0'; i++) {
        char c = s[i];
        if (c >= '0' && c <= '9') {
            current = current * 10 + (c - '0');
        } else if (c == 'H') {
            hours = current;
            current = 0;
        } else if (c == 'M') {
            minutes = current;
            current = 0;
        } else if (c == 'S') {
            seconds = current;
            current = 0;
        }
    }
    return hours * 3600 + minutes * 60 + seconds;
}

- (NSString*)viewCountDisplay {
    /* Parse as double; we only care about 2-3 sig figs for display, so
     * precision loss above ~10^15 doesn't matter -- and double handles
     * the full range of YouTube view counts where unsigned long (32-bit
     * on ppc Tiger) would overflow around 4.3B. */
    double n = [self doubleValue];
    if (n < 0.0) {
        n = 0.0;
    }

    NSString* count;
    if (n < 1000.0) {
        count = [NSString stringWithFormat:@"%.0f", n];
    } else if (n < 10000.0) {
        count = [NSString stringWithFormat:@"%.1fK", n / 1000.0];
    } else if (n < 1000000.0) {
        count = [NSString stringWithFormat:@"%.0fK", n / 1000.0];
    } else if (n < 10000000.0) {
        count = [NSString stringWithFormat:@"%.1fM", n / 1000000.0];
    } else if (n < 1000000000.0) {
        count = [NSString stringWithFormat:@"%.0fM", n / 1000000.0];
    } else if (n < 10000000000.0) {
        count = [NSString stringWithFormat:@"%.1fB", n / 1000000000.0];
    } else {
        count = [NSString stringWithFormat:@"%.0fB", n / 1000000000.0];
    }

    if (n == 1.0) {
        return @"1 view";
    }
    return [NSString stringWithFormat:@"%@ views", count];
}

@end
