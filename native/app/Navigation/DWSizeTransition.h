// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWSizeTransitionHost.h"
@class LiveSource;
// Main-thread owner of native size work and its optical handoff. Callers submit
// controller effects; capture/hide admission and final-placement ACK stay inside.
// Host must outlive this owner (held weakly); driver/capture are retained. Capture
// completes asynchronously on main. Every effect is revalidated before native
// work; refusal follows the unchanged controller-result/failure path. Native
// cancellation drains work already started; it cannot retract an AX setter.
// No caller waits/polls for capture, hide, animation or reveal. observe/willRender
// are existing shell observation/render events, not readiness authorization.
@interface DWSizeTransition : NSObject
- (instancetype)initWithHost:(id<DWSizeTransitionHost>)host;
// The injected adapters sit behind the same interface as production. No
// caller configures coordinator/driver readiness callbacks or picture phases.
- (instancetype)initWithHost:(id<DWSizeTransitionHost>)host
                      driver:(id<DWSizeTransitionResizeDriver>)driver
                     capture:(DWSizeTransitionCapture)capture;
// Nil without a Fill/Restore handoff. Immutable identity/output/background
// facts used by input refusal; callers must not retain them as authorization.
@property (readonly) NSDictionary *fillHandoff;
@property (readonly) NSUInteger obligations;
@property (readonly) NSString *failure;
- (BOOL)canRemove:(NSNumber *)window;
- (NSNumber *)busyWindow;
- (DWControllerReply *)request:(DWResizeRequest)operation;
- (void)consume:(DWControllerReply *)reply;
// IPC resize writes wait at most two seconds for the native transaction, never
// blocking main or cancelling native work. A newer write supersedes the waiter.
// Completion is an external Ok(Size) or Err reply, not a controller command.
- (void)replyForResizeWindow:(NSNumber *)window requested:(CGSize)requested completion:(void (^)(NSDictionary *reply))completion;
// Returns the sizing effect (or nil), preserving the action reply continuation.
- (DWSizeEffect *)consumeSize:(DWControllerReply *)reply;
- (BOOL)sizing;
- (void)cancel;
- (void)shutdown;
- (void)reap;
- (void)interruptFillForVisibility:(LiveSource *)source;
- (DWScene *)nativeFillBackground:(DWScene *)snapshot;
// Before changing session/outputs, retire pictures without admitting successors.
- (void)suspendPresentation;
- (void)cancelPresentation;
- (void)observe;
- (void)willRender;
@end
