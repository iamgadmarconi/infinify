// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
// The caller supplies freshly verified root-only geometry, never guessed ancestry.
NSNumber *DWResizeCaptureTimestamp(CMSampleBufferRef sample);
NSDictionary *DWResizeCaptureMetadata(CMSampleBufferRef sample, uint64_t cutoff, CGRect nativeExtent);

// Completion ticket for a configuration request; success never authorizes capture.
BOOL DWResizeConfigurationCurrent(id requestedStream,id currentStream,NSNumber *requestedRevision,NSNumber *currentRevision,BOOL detached);
