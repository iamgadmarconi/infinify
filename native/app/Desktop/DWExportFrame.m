// SPDX-License-Identifier: GPL-3.0-or-later
// The one-shot export request a screenshot hands across queues.
#import "DWExportFrame.h"
@implementation DWExportFrame
- (void)dealloc {if(sample)CFRelease(sample);if(pixels)CVPixelBufferRelease(pixels);}
@end
