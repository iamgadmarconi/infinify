// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "DWScene.h"
#import "DWControllerReply.h"
#import "DWIdentity.h"
#import "DWSource.h"
#import "DWEffect.h"
#import "DWNativeResult.h"
NS_ASSUME_NONNULL_BEGIN
@class DWSceneWriter, DWResizeValidityFacts;
typedef struct { BOOL control, option, shift, command; } DWModifierFlags;\n// Semantic protocol values, separate from transport operation names. Action
// strings remain open (configuration and IPC define that vocabulary).
typedef NSString *DWActivationCause NS_TYPED_EXTENSIBLE_ENUM;
typedef NSString *DWControllerResizeEdges NS_TYPED_EXTENSIBLE_ENUM;
typedef NSString *DWControllerGestureKind NS_TYPED_EXTENSIBLE_ENUM;
typedef NSString *DWControllerZoomPolicy NS_TYPED_EXTENSIBLE_ENUM;


// Optional geometry arguments are NSValue point/rect values; nil means absent.
// Every reply is lazy and immutable. nil preserves the old failed-command path.
@protocol DWSceneController <NSObject>
- (nullable DWScene *)scene;
@property(nonatomic,readonly,nullable) DWScene *cachedScene;
@property(nonatomic,readonly,nullable) DWScene *visualScene;
@end

// A discovery attachment can name an existing logical slot, a world frame, or
// neither. Its optional screen pin is output-local, never native ownership.
@interface DWAttachRequest : NSObject
@property(nonatomic,strong) DWIdentity *identity;
@property(nonatomic,copy) NSString *bundleID;
@property(nonatomic,copy) NSString *title;
@property(nonatomic) CGSize buffer;
@property(nonatomic) CGRect sourceRect;
@property(nonatomic,strong,nullable) NSNumber *logicalID;
@property(nonatomic,strong,nullable) NSValue *worldRect;
@property(nonatomic,strong,nullable) NSNumber *output;
@property(nonatomic,strong,nullable) NSValue *pointer;
@property(nonatomic,strong,nullable) NSNumber *pinOutput;
@property(nonatomic) CGPoint pinPosition;
@property(nonatomic) BOOL unsolicited;
@end

@interface DWPresentWindow : NSObject
@property(nonatomic,copy) NSString *bundleID;
@property(nonatomic,copy) NSString *title;
+ (instancetype)windowWithBundleID:(NSString *)bundleID title:(NSString *)title;
@end

@protocol DWInputController <DWSceneController>
- (nullable NSNumber *)outputAtPoint:(CGPoint)point restrictedToOutputs:(NSArray<NSNumber *> *)outputs;
- (nullable DWControllerReply *)hitOnOutput:(NSNumber *)output screen:(CGPoint)screen;
- (nullable DWControllerReply *)inputOnOutput:(NSNumber *)output screen:(CGPoint)screen identity:(DWIdentity *)identity;
- (nullable DWControllerReply *)resizeBorderOnOutput:(NSNumber *)output screen:(CGPoint)screen;
- (nullable DWControllerReply *)gestureFingers;
- (nullable DWControllerReply *)bindings;
- (nullable DWControllerReply *)mouseBinding:(NSString *)trigger source:(nullable NSString *)source modifiers:(DWModifierFlags)modifiers windowContext:(BOOL)windowContext window:(nullable NSNumber *)window pick:(BOOL)pick;
- (nullable DWControllerReply *)hoverOnOutput:(NSNumber *)output screen:(CGPoint)screen time:(nullable NSNumber *)time;
- (nullable DWControllerReply *)hoverWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation output:(NSNumber *)output screen:(CGPoint)screen time:(nullable NSNumber *)time forwardMotion:(BOOL)forward;
- (nullable DWControllerReply *)pointerOnOutput:(nullable NSNumber *)output screen:(CGPoint)screen;
- (nullable DWControllerReply *)pickWindow:(NSNumber *)window output:(NSNumber *)output;
- (nullable DWControllerReply *)pointerNearestOnOutput:(NSNumber *)output screen:(CGPoint)screen start:(CGPoint)start held:(BOOL)held focus:(BOOL)focus;
- (nullable DWControllerReply *)beginDragWindow:(NSNumber *)window output:(NSNumber *)output group:(BOOL)group;
- (nullable DWControllerReply *)beginResizeWindow:(NSNumber *)window output:(NSNumber *)output edges:(DWControllerResizeEdges)edges group:(BOOL)group;
- (nullable DWControllerReply *)gestureTo:(CGPoint)delta pointer:(nullable NSValue *)pointer;
- (nullable DWControllerReply *)endGesture;
- (nullable DWControllerReply *)beginGesture:(DWControllerGestureKind)kind fingers:(NSUInteger)fingers modifiers:(DWModifierFlags)modifiers windowContext:(BOOL)windowContext output:(NSNumber *)output pointer:(CGPoint)pointer doubleTap:(BOOL)doubleTap time:(double)time;
- (nullable DWControllerReply *)updateGestureWithDelta:(CGPoint)delta scale:(double)scale rotation:(double)rotation time:(double)time held:(BOOL)held;
- (nullable DWControllerReply *)endGestureCancelled:(BOOL)cancelled time:(double)time held:(BOOL)held;
@end

@protocol DWNavigationCommands <DWSceneController>
- (nullable DWControllerReply *)tickNavigationAt:(uint64_t)timestamp;
- (nullable DWControllerReply *)focusWindow:(NSNumber *)window;
- (nullable DWControllerReply *)activateWindow:(NSNumber *)window output:(nullable NSNumber *)output cause:(DWActivationCause)cause identity:(nullable DWIdentity *)identity generation:(nullable NSNumber *)generation;
- (nullable DWControllerReply *)clearFocus;
- (nullable DWControllerReply *)focusLost;
- (nullable DWControllerReply *)focusResult:(DWFocusEffect *)effect success:(BOOL)success;
- (nullable DWControllerReply *)focusLogical:(DWFocusEffect *)effect;
- (nullable DWControllerReply *)observeFocusWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation;
- (nullable DWControllerReply *)endFocusCycle;
- (nullable DWControllerReply *)cancelFocusCycle;
- (nullable DWControllerReply *)cycleFocusBackward:(BOOL)backward held:(BOOL)held;
- (nullable DWControllerReply *)cancelNavigationOnOutput:(NSNumber *)output;
- (nullable DWControllerReply *)panOnOutput:(NSNumber *)output delta:(CGPoint)delta time:(nullable NSNumber *)time source:(nullable NSString *)source;
- (nullable DWControllerReply *)endPanOnOutput:(NSNumber *)output time:(nullable NSNumber *)time;
- (nullable DWControllerReply *)zoomOnOutput:(NSNumber *)output anchor:(CGPoint)anchor delta:(double)delta source:(NSString *)source phase:(nullable NSString *)phase;
- (nullable DWControllerReply *)navigateWindow:(NSNumber *)window output:(NSNumber *)output zoomPolicy:(DWControllerZoomPolicy)policy;
- (nullable DWControllerReply *)cycleNavigateOnOutput:(NSNumber *)output backward:(BOOL)backward held:(BOOL)held;
@end

@protocol DWResizeController <DWSceneController>
- (nullable DWResizeTransaction *)resizeTransaction;
- (nullable DWResizeValidityFacts *)resizeValidityForWindow:(NSNumber *)window output:(NSNumber *)output;
- (BOOL)resizeRemovalAllowedForWindow:(nullable NSNumber *)window allowed:(BOOL *)allowed;
- (nullable DWControllerReply *)beginNativeResizeWindow:(NSNumber *)window output:(NSNumber *)output edges:(nullable DWControllerResizeEdges)edges start:(CGPoint)start group:(BOOL)group;
- (nullable DWControllerReply *)nativeResizeTo:(CGPoint)screen transaction:(NSNumber *)transaction;
- (nullable DWControllerReply *)endNativeResize:(NSNumber *)transaction;
- (nullable DWControllerReply *)cancelNativeResize:(NSNumber *)transaction;
- (nullable DWControllerReply *)nativeResizeResult:(DWNativeResult *)result effect:(DWSizeEffect *)effect;
- (nullable DWControllerReply *)setNativeResizeCapability:(BOOL)enabled;
- (nullable DWControllerReply *)nativeDecoration:(NSString *)action window:(NSNumber *)window output:(NSNumber *)output identity:(DWIdentity *)identity generation:(NSNumber *)generation;
@end

@protocol DWWindowController <DWSceneController>
- (nullable DWSourceBinding *)sourceBindingForWindow:(nullable NSNumber *)window;
- (BOOL)observationCurrentForWindow:(NSNumber *)window identity:(DWIdentity *)identity bounds:(CGRect)bounds buffer:(CGSize)buffer;
- (nullable DWControllerReply *)attach:(DWAttachRequest *)request;
- (nullable DWControllerReply *)adoptionComplete:(NSArray<DWPresentWindow *> *)present;
- (nullable DWControllerReply *)retitleWindow:(NSNumber *)window identity:(DWIdentity *)identity title:(NSString *)title;
- (nullable DWControllerReply *)windowClosed:(NSNumber *)window identity:(DWIdentity *)identity output:(nullable NSNumber *)output;
- (nullable DWControllerReply *)removeSourceWindow:(NSNumber *)window identity:(DWIdentity *)identity keepPlaceholder:(BOOL)keep;
- (nullable DWControllerReply *)forgetWindow:(NSNumber *)window;
- (nullable DWControllerReply *)observeWindow:(NSNumber *)window identity:(DWIdentity *)identity rect:(CGRect)rect buffer:(CGSize)buffer;
- (nullable DWControllerReply *)observePresentationWindow:(NSNumber *)window identity:(DWIdentity *)identity rect:(CGRect)rect buffer:(CGSize)buffer;
- (nullable DWControllerReply *)sourceVisibilityPendingWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation;
- (nullable DWControllerReply *)observeVisibilityWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation minimized:(BOOL)minimized;
- (nullable DWControllerReply *)sourceVisibleWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation revision:(NSNumber *)revision;
- (nullable DWControllerReply *)relocateSourceWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation observedRect:(CGRect)observed expectedWorldRect:(CGRect)expected delta:(CGPoint)delta;
@end

@protocol DWOutputController <DWSceneController>
- (nullable DWControllerReply *)registerOutput:(NSString *)stableID screenBounds:(CGRect)bounds usableRect:(nullable NSValue *)usable;
- (nullable DWControllerReply *)removeOutput:(NSNumber *)output;
- (nullable DWControllerReply *)outputsSettled;
- (nullable DWControllerReply *)setUsableRect:(CGRect)rect output:(NSNumber *)output;
@end

@protocol DWConfigurationController <DWSceneController>
- (nullable DWControllerReply *)loadConfig:(nullable NSString *)path;
- (nullable DWControllerReply *)setSuperChord:(NSString *)chord;
- (nullable DWControllerReply *)layoutChangedName:(NSString *)name shortName:(NSString *)shortName index:(NSUInteger)index count:(NSUInteger)count;
@end

@protocol DWActionController <DWSceneController>
- (nullable DWControllerReply *)action:(NSString *)action output:(nullable NSNumber *)output pointer:(nullable NSValue *)pointer held:(BOOL)held;
- (nullable DWControllerReply *)tapModifiers:(DWModifierFlags)modifiers output:(nullable NSNumber *)output pointer:(nullable NSValue *)pointer held:(BOOL)held;
- (nullable DWControllerReply *)hotCorner:(NSString *)corner output:(NSNumber *)output pointer:(nullable NSValue *)pointer held:(BOOL)held;
- (nullable DWControllerReply *)stateOnOutput:(nullable NSNumber *)output;
- (nullable DWControllerReply *)bookmark:(NSString *)name output:(NSNumber *)output;
- (nullable DWControllerReply *)closeWindow:(NSNumber *)window output:(nullable NSNumber *)output;
- (nullable DWControllerReply *)relaunchWindow:(NSNumber *)window output:(nullable NSNumber *)output;
- (nullable DWControllerReply *)stateEventOnOutput:(nullable NSNumber *)output;
- (nullable DWControllerReply *)screenshotResultPath:(nullable NSString *)path width:(nullable NSNumber *)width height:(nullable NSNumber *)height error:(nullable NSString *)error;
@end

@protocol DWPersistenceController <DWSceneController>
- (nullable DWControllerReply *)saveScene:(NSString *)path;
- (nullable DWControllerReply *)loadScene:(NSString *)path;
@end

// Narrow stage-1 query. Placement alpha/screen rect are presenter facts and
// deliberately absent. These views share the current scene, never native proof.
@interface DWResizeValidityFacts : NSObject
@property(nonatomic,readonly,nullable) DWResizeTransaction *transaction;
@property(nonatomic,readonly,nullable) DWSource *source;
@property(nonatomic,readonly,nullable) DWOutput *output;
@end

@interface DWController : NSObject <DWSceneController, DWInputController, DWNavigationCommands, DWResizeController, DWWindowController, DWOutputController, DWConfigurationController, DWActionController, DWPersistenceController>
@property(nonatomic,copy,nullable) void (^failed)(NSString *reason);
@property(nonatomic,copy,nullable) void (^refreshGestureFingers)(void);
// Run after every navigation-owned underlying call, including nested policy
// facts and snapshots. The adapter consumes size effects; reply projection owns
// focus/size effect selection without changing transport call count.
@property(nonatomic,copy,nullable) DWControllerReply * _Nullable (^navigationPostprocess)(DWControllerReply * _Nullable reply);
- (nullable DWSourceBinding *)sourceBindingForWindow:(nullable NSNumber *)window;
- (BOOL)observationCurrentForWindow:(NSNumber *)window identity:(DWIdentity *)identity bounds:(CGRect)bounds buffer:(CGSize)buffer;
- (BOOL)resizeRemovalAllowedForWindow:(nullable NSNumber *)window allowed:(BOOL *)allowed;
- (NSArray<NSNumber *> *)outputIDs;
- (nullable NSNumber *)outputAtPoint:(CGPoint)point restrictedToOutputs:(NSArray<NSNumber *> *)outputs;
- (BOOL)output:(NSNumber *)output screenBounds:(CGRect *)bounds;
- (nullable DWResizeValidityFacts *)resizeValidityForWindow:(NSNumber *)window output:(NSNumber *)output;
- (BOOL)submitSceneToWriter:(DWSceneWriter *)writer path:(NSString *)path;
@end
NS_ASSUME_NONNULL_END
