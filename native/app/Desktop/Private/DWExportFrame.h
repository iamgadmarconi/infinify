// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1.
// The one-shot export request a screenshot hands across queues.
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <stdatomic.h>
#import "DWNativePresenter.h"
// A one-shot export completion may run on any queue. GCD transfers its retained
// result to the main thread; an expired request never installs a late sample.
@interface DWExportFrame : NSObject {
@public
    _Atomic BOOL completed;
    _Atomic BOOL captureExpired; // deadline stops capture callbacks; final validation may still complete
    CMSampleBufferRef sample;
    CVPixelBufferRef pixels;
    NSString *failure;
    NSArray<NSDictionary *> *nativeItems;
    NSUInteger nativeIndex; // main-only capture cursor, independent of a failed root index
    DWNativePresenter *presenter;
    BOOL nativeFamilies;
}
@end
