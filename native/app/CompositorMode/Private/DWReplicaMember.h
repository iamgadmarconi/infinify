// SPDX-License-Identifier: GPL-3.0-or-later
// DWReplicaMember: one native child window's capture stream and its published image.
// Split from native/desktop/native-replica-family.m at 37b27b1, moved verbatim.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <stdatomic.h>
#import "DWCanvasAttachment.h"
@class DWNativeReplicaFamilies;

// Each object owns exactly one immutable native membership/geometry epoch and
// one stream. Retiring it invalidates queued callbacks before any new filter is
// installed. At most one frame per member waits for the main queue.
@interface DWReplicaMember : NSObject <SCStreamOutput,SCStreamDelegate> {
@public
    _Atomic BOOL alive;
    _Atomic BOOL pending;
    _Atomic BOOL received;
    _Atomic BOOL stopped;
    _Atomic BOOL withdrawalPending;
    _Atomic uint64_t callbackSequence,publishedSequence,unavailableSequence;
}
@property NSDictionary *root,*identity;
@property CGRect rootBounds,bounds;
@property DWCanvasAttachment *image;
@property SCStream *stream;
@property dispatch_queue_t samples;
@property(weak) DWNativeReplicaFamilies *owner;
@property(copy) NSString *failure;
@property double density;
@property BOOL started;
@property BOOL hadImage;
@property BOOL updating;
@property NSInteger rate;
@property NSUInteger configuration;
@property uint64_t frameTime;
@property CFTimeInterval startDeadline;
@property CFTimeInterval firstFrameDeadline;
@property CFTimeInterval lastVisible;
- (void)retire;
- (void)start;
- (void)expireStart;
- (void)expireFirstFrame;
- (BOOL)imageAvailable;
- (void)fail:(NSString *)failure code:(const char *)code error:(NSInteger)error;
@end
