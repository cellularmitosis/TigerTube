#ifndef TIGER_COMPAT_H
#define TIGER_COMPAT_H

// Compatibility shim for Tiger/10.4.

#import <Foundation/Foundation.h>

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 1050

// NSInteger, NSUInteger and CGFloat didn't exist on Tiger/10.4.

typedef int NSInteger;
#define NSIntegerMax INT_MAX
#define NSIntegerMin INT_MIN

typedef unsigned int NSUInteger;
#define NSUIntegerMax UINT_MAX

typedef float CGFloat;
#define CGFLOAT_MIN FLT_MIN
#define CGFLOAT_MAX FLT_MAX

#endif

#endif
