// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
// The caller supplies freshly verified root-only geometry, never guessed ancestry.
NSNumber *DWResizeCaptureTimestamp(CMSampleBufferRef sample);
NSDictionary *DWResizeCaptureMetadata(CMSampleBufferRef sample, uint64_t cutoff, CGRect nativeExtent);
// The same answer by the same checks; when it is nil, `why` names the first check that failed and the values it compared, for a person to read.
NSDictionary *DWResizeCaptureDescription(CMSampleBufferRef sample, uint64_t cutoff, CGRect nativeExtent, NSString *__autoreleasing *why);
