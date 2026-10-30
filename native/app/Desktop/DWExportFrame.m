// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// The one-shot export request a screenshot hands across queues.
#import "DWExportFrame.h"
@implementation DWExportFrame
- (void)dealloc {if(sample)CFRelease(sample);if(pixels)CVPixelBufferRelease(pixels);}
@end
