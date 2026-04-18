//
//  ResultCell.h
//  TigerTube
//
//  NSCell subclass used for the "info" column of the search results
//  table.  Renders four text fields stacked vertically (left-aligned,
//  single-line, truncating-tail):
//
//      title              (bold 13pt, black)
//      channelTitle       (11pt, dark gray)
//      duration           (11pt, dark gray)
//      viewCountDisplay   (11pt, dark gray)
//
//  Expects its objectValue to be an NSDictionary with the above keys
//  (all already display-formatted by the data source).
//

#ifndef RESULT_CELL_H
#define RESULT_CELL_H

#import <Cocoa/Cocoa.h>
#import "TigerCompat.h"

@interface ResultCell : NSCell {
    NSDictionary* info;   /* strong */
}
@end

#endif
