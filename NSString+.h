//
//  NSString+.h
//  TigerTube
//

#ifndef NS_STRING_TIGERTUBE_H
#define NS_STRING_TIGERTUBE_H

#import <Foundation/Foundation.h>
#import "TigerCompat.h"

@interface NSString (TigerTube)

// Decode a subset of HTML entities commonly found in YouTube API text:
//   &amp; &lt; &gt; &quot; &apos; &#NN; &#xHH;
// Unknown entities are left as-is.
- (NSString*)htmlDecoded;

// Convert an ISO 8601 duration like "PT1H2M3S" or "PT12M53S" or "PT40S"
// into a display form like "1:02:03" / "12:53" / "0:40".  Strings that
// don't start with "PT" are returned unchanged.
- (NSString*)iso8601DurationDisplay;

// Same parse as -iso8601DurationDisplay but returns the total in seconds
// (e.g. "PT1H2M3S" -> 3723).  Returns 0 for strings that don't start
// with "PT" (caller can treat as "unknown duration").
- (int)iso8601DurationSeconds;

// Treat the receiver as a decimal integer view count (e.g. "1234567")
// and return an abbreviated display form: "1 view", "42 views",
// "1.2K views", "15K views", "1.2M views", "123M views", "1.2B views".
- (NSString*)viewCountDisplay;

@end

#endif
