// SPDX-License-Identifier: GPL-3.0-or-later
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
    CMSampleBufferRef sample;
    CVPixelBufferRef pixels;
    NSString *failure;
    NSArray<NSDictionary *> *nativeItems;
    DWNativePresenter *presenter;
    BOOL nativeFamilies;
}
@end
