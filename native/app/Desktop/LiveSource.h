// SPDX-License-Identifier: GPL-3.0-or-later
// One managed window: its capture stream, picture, native identity and per-window native state.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "DWCaptureConfiguration.h"
#import "DWRootCaptureMailbox.h"
#import "Router.h"
@interface LiveSource : NSObject <SCStreamDelegate>
@property Router *router;
@property NSDictionary *identity;
@property NSNumber *logical;
@property(nonatomic) SCStream *stream; // main-only; its setter retires the prior mailbox
@property DWRootCaptureMailbox *captureMailbox;
@property NSUInteger frames;
@property CGSize buffer;
@property NSString *error;
@property(nonatomic) BOOL detached; // main-only; retirement drops queued capture immediately
@property BOOL streamStopped;
// A managed run: the window the stream is made from and the title last reported.
@property SCWindow *window;
@property NSString *title;
// When its application reported the window destroyed (DWWindowEvents.h), until the window list agrees or shows it is still there; 0 for none.
@property CFTimeInterval destroyed;
// The compositor draws the stream's latest pixel buffer, kept here until
// the next one. `presented` runs when a new one was kept.
@property CVPixelBufferRef pixels;
// Pixel crop belongs to the retained picture, including across intentional stops.
// CGRectNull is reserved for explicit full-buffer export installation.
@property CGRect contentRect;
@property (copy) void (^presented)(void);
// INFINIFY_DEBUG's frame line (-frameStats), since it was last printed: screen frames the stream handed over, frames kept, and
// complete frames passed over because nothing in them had changed.
@property NSUInteger delivered,accepted,skipped;
// The stream was started or given a new size and has had no frame kept since: its next complete frame is kept whatever it
// says of itself. The picture held is from before (-stopCapture: keeps it), so "nothing changed" is not about that one.
@property BOOL restarted;
// Capture pixels are a presentation budget, never the native or world size. Configuration changes are serialized.
@property CGSize captureSize,captureNativeSize,captureCandidate;
@property CFTimeInterval captureCandidateSince;
@property double captureDemandDensity;
@property CFTimeInterval captureDemandSince;
@property(nonatomic) DWCaptureConfiguration captureConfiguration;
@property(readonly) BOOL captureUpdating;
// A system-interrupted capture keeps its logical binding and last picture.
// Retries obtain a new shareable-window identity rather than reuse a stale filter.
@property BOOL captureRecovering;
@property BOOL nativeReplica,replicaWanted;
@property NSUInteger captureFailures;
@property CFTimeInterval captureRetryAt;
@property uint64_t observationToken;
@property BOOL nativeMinimized,nativeVisibilityHeld,nativeVisibilityWanted,nativeVisibilityWriting;
@property uint64_t nativeVisibilityRevision;
@property CFTimeInterval nativeVisibilityRetryAt,nativeVisibilityStableSince;
@property NSDictionary *nativeVisibilityEffect,*nativeVisibilityRestore,*nativeVisibilityStable;
// Audited worker geometry for presentation discovery only; capture and input
// still require their own fresh native identity/parent checks.
@property NSDictionary *nativeFamily;
@property NSMutableDictionary *nativeMouseOwnership;
@property BOOL nativeMouseAdopting;
@property BOOL nativeTransferFamilyWanted; // exact audited family requested for a replica ownership handoff
@property NSDictionary *nativeButtons;
// Not hit-test authority: an origin-only observation waits for an exact AXMoved hint.
@property NSDictionary *nativeButtonsMoveCandidate;
@property(copy) NSString *nativeTitleDebugReason; // last reported reason, retained across routine cache invalidation
@property uint64_t nativeButtonsRevision;
@property BOOL nativeButtonsReading;
@property CFTimeInterval nativeButtonsNext;
- (void)invalidateNativeButtons;
- (BOOL)installSample:(CMSampleBufferRef)sample;
- (BOOL)installPixels:(CVPixelBufferRef)pixels;
- (BOOL)installPixels:(CVPixelBufferRef)pixels contentRect:(CGRect)crop;
- (BOOL)acceptCapturedSample:(CMSampleBufferRef)sample stream:(SCStream *)stream received:(NSUInteger)received forceInstall:(BOOL)force;
- (void)clearSample;
- (void)captureFailed:(NSError *)error;
- (uint64_t)beginCaptureConfiguration:(SCStreamConfiguration *)configuration;
- (BOOL)completeCaptureConfiguration:(uint64_t)serial success:(BOOL)success;
@end
