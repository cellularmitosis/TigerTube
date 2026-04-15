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
- (NSString *)htmlDecoded;

// Convert an ISO 8601 duration like "PT1H2M3S" or "PT12M53S" or "PT40S"
// into a display form like "1:02:03" / "12:53" / "0:40".  Strings that
// don't start with "PT" are returned unchanged.
- (NSString *)iso8601DurationDisplay;

@end

#endif
