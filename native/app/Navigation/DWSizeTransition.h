// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
@class Desktop, LiveSource;
// Main-thread owner of native size work and its optical handoff. Callers submit
// controller effects; capture/hide admission and final-placement ACK stay inside.
@interface DWSizeTransition : NSObject
- (instancetype)initWithDesktop:(Desktop *)desktop;
// Nil without a Fill/Restore handoff. Immutable identity/output/background
// facts used by input refusal; callers must not retain them as authorization.
@property (readonly) NSDictionary *fillHandoff;
@property (readonly) NSUInteger obligations;
@property (readonly) NSString *failure;
- (BOOL)canRemove:(NSNumber *)window;
- (NSNumber *)busyWindow;
- (NSDictionary *)request:(NSDictionary *)command;
- (void)consume:(NSDictionary *)reply;
- (NSDictionary *)consumeSize:(NSDictionary *)reply;
- (BOOL)sizing;
- (void)cancel;
- (void)shutdown;
- (void)reap;
- (void)clearNativeFillPresentation;
- (void)updateNativeFill;
- (void)interruptFillForVisibility:(LiveSource *)source;
- (NSDictionary *)nativeFillBackground:(NSDictionary *)snapshot;
- (void)cancelPresentationForSessionDeparture;
- (void)cancelPresentation;
- (void)updatePresentation;
@end
