// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWController.h"
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger,DWNavigationActivationCause) {
    DWNavigationActivationClick,
    DWNavigationActivationClickRelease
};

// Providers are sampled for EACH policy fact, including synchronous receipts.
@interface DWFocusPolicyContext : NSObject
- (instancetype)initWithClock:(uint64_t (^)(void))clock
                      filter:(BOOL (^)(void))filter
                focusAllowed:(BOOL (^)(void))focusAllowed;
@property(nonatomic,readonly) uint64_t timestamp;
@property(nonatomic,readonly) BOOL filter;
@property(nonatomic,readonly) BOOL focusAllowed;
@end

// Main-thread synchronous hooks. currentEpoch is a read only, never a command.
// The five actions contain native scheduling, not policy interpretation.
@protocol DWNavigationExecution <NSObject>
@property(nonatomic,readonly) uint64_t currentEpoch;
- (void)navigationCancelNativeClick;
- (void)navigationAdvanceReleasingHold:(BOOL)releaseHold;
- (void)navigationAnswerEffect:(nullable DWEffect *)effect logical:(BOOL)logical epoch:(uint64_t)epoch;
- (void)navigationPerformReply:(nullable DWControllerReply *)reply correction:(nullable DWFocusCorrection *)correction prepared:(BOOL)prepared;
- (void)navigationChanged;
@end

@protocol DWNavigationController <DWSceneController>
- (nullable DWScene *)navigationScene;
// Compatibility selection after size postprocessing: ANY dictionary top-level
// effect wins, even an unexpected kind; otherwise the last native-focus effect.
// This deliberately differs from the reply's strict separated focusEffect view.
- (nullable DWEffect *)navigationEffectForReply:(DWControllerReply *)reply;
- (nullable DWControllerReply *)navigationExecute:(DWControllerReply * _Nullable (^)(void))execute;
- (nullable DWControllerReply *)attach:(DWAttachRequest *)request arrived:(BOOL)arrived adopted:(BOOL)adopted utility:(BOOL)utility context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)observeIdentity:(DWIdentity *)actual familyBinding:(nullable DWSourceBinding *)family eventAt:(uint64_t)observedAt output:(nullable NSNumber *)output capturedEpoch:(uint64_t)epoch context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (BOOL)applicationPID:(pid_t)pid birthSeconds:(NSNumber *)seconds microseconds:(NSNumber *)microseconds bundle:(nullable NSString *)bundle activated:(BOOL)activated eventAt:(uint64_t)eventAt context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)systemSwitchHeld:(BOOL)held context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)systemUIIntentWithContext:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)launchIntentForBundle:(NSString *)bundle context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)windowClicked:(nullable NSNumber *)window context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)cancelBackgroundArrivalWithContext:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution;
- (void)clearBackgroundArrivalWithContext:(DWFocusPolicyContext *)context;
- (void)resetFocusPolicyWithContext:(DWFocusPolicyContext *)context;
- (void)resetFocusRestoresWithContext:(DWFocusPolicyContext *)context;
- (nullable DWFocusCorrection *)prepareFocusReply:(DWControllerReply *)reply protect:(BOOL)protect context:(DWFocusPolicyContext *)context;
- (void)focusAnswerBegan:(DWEffect *)effect success:(BOOL)success context:(DWFocusPolicyContext *)context;
- (void)focusConfirmed:(DWIdentity *)identity context:(DWFocusPolicyContext *)context;
- (nullable DWControllerReply *)navigationAnswerFocus:(DWEffect *)effect logical:(BOOL)logical success:(BOOL)success;
- (nullable DWControllerReply *)navigationCancelFocusCycle;
- (nullable DWControllerReply *)navigationEndFocusCycle;
- (nullable DWControllerReply *)navigationCancelOnOutput:(NSNumber *)output;
- (nullable DWControllerReply *)navigationTickAt:(uint64_t)timestamp;
- (nullable DWControllerReply *)navigationActivateBinding:(DWSourceBinding *)binding cause:(DWNavigationActivationCause)cause output:(NSNumber *)output;
- (nullable DWControllerReply *)navigationObserveBinding:(DWSourceBinding *)binding;
@end

@interface DWController (Focus) <DWNavigationController>
@end
NS_ASSUME_NONNULL_END
