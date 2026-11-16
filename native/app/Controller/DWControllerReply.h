// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
#import "DWIdentity.h"
#import "DWSource.h"
#import "DWMetadata.h"
#import "DWDecoration.h"
#import "DWPin.h"
#import "DWDrawnValue.h"
#import "DWWindow.h"
#import "DWWindowRule.h"
#import "DWPlacement.h"
#import "DWFullscreen.h"
#import "DWOutput.h"
#import "DWFocus.h"
#import "DWFocusCycle.h"
#import "DWNavigationContext.h"
#import "DWPointerDemand.h"
#import "DWNavigation.h"
#import "DWResizeTransaction.h"
#import "DWNativeResult.h"
#import "DWEffect.h"
#import "DWFocusEffect.h"
#import "DWSizeEffect.h"
#import "DWShellEffect.h"
#import "DWLifecycleEvent.h"
#import "DWLifecycle.h"
#import "DWRenderBackground.h"
#import "DWRenderChrome.h"
#import "DWRenderOutline.h"
#import "DWRenderEffects.h"
#import "DWBlurSettings.h"
#import "DWAnimationSettings.h"
#import "DWRender.h"
#import "DWSourceBinding.h"
#import "DWHit.h"
#import "DWBinding.h"
#import "DWFocusCorrection.h"
#import "DWFlight.h"
#import "DWResizeBorder.h"
#import "DWGestureState.h"
#import "DWModifiers.h"
#import "DWPointerSettings.h"
#import "DWCornerActions.h"
#import "DWHotCornerSettings.h"
#import "DWScreenshotWindowTarget.h"
#import "DWScreenshotRegionTarget.h"
#import "DWScreenshotTarget.h"
#import "DWRGBA.h"
#import "DWGestureAction.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWControllerReply : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *dirty;
@property(nonatomic,readonly,nullable) NSNumber *needsFrames;
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) NSNumber *adopted;
@property(nonatomic,readonly,nullable) NSNumber *background;
@property(nonatomic,readonly,nullable) NSNumber *focusOnOpenSuppressed;
@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *changedOutputs;
@property(nonatomic,readonly,nullable) DWNavigation *navigation;
@property(nonatomic,readonly,nullable) NSString *error;
@property(nonatomic,readonly,nullable) NSString *message;
@property(nonatomic,readonly,nullable) DWHit *hit;
@property(nonatomic,readonly,nullable) DWBinding *binding;
@property(nonatomic,readonly,nullable) NSNumber *passed;
@property(nonatomic,readonly,nullable) NSNumber *enabled;
@property(nonatomic,readonly,nullable) NSArray<NSNumber *> *fingers;
@property(nonatomic,readonly,nullable) NSNumber *clockOnly;
@property(nonatomic,readonly,nullable) NSNumber *needsPointer;
@property(nonatomic,readonly,nullable) NSNumber *stateEvent;
@property(nonatomic,readonly,nullable) NSNumber *revision;
@property(nonatomic,readonly,nullable) NSNumber *visibilityRevision;
@property(nonatomic,readonly,nullable) DWSource *source;
@property(nonatomic,readonly,nullable) DWIdentity *identity;
@property(nonatomic,readonly,nullable) NSNumber *generation;
@property(nonatomic,readonly,nullable) DWSourceBinding *sourceBinding;
@property(nonatomic,readonly,nullable) DWFocusCorrection *focusCorrection;
@property(nonatomic,readonly,nullable) DWFocusEffect *focusEffect;
@property(nonatomic,readonly,nullable) NSArray<DWSizeEffect *> *sizeEffects;
@property(nonatomic,readonly,nullable) NSArray<DWShellEffect *> *shellEffects;
@property(nonatomic,readonly) DWValuePresence effectPresence;
@property(nonatomic,readonly,nullable) NSArray<DWBinding *> *bindings;
@property(nonatomic,readonly,nullable) NSNumber *pick;
@property(nonatomic,readonly,nullable) NSNumber *forward;
@property(nonatomic,readonly,nullable) DWResizeBorder *border;
@property(nonatomic,readonly,nullable) DWGestureState *gesture;
@property(nonatomic,readonly,nullable) NSString *line;
@property(nonatomic,readonly,nullable) NSNumber *resized;
@property(nonatomic,readonly,nullable) NSNumber *moved;
@property(nonatomic,readonly,nullable) NSString *path;
@property(nonatomic,readonly,nullable) NSNumber *exists;
@property(nonatomic,readonly,nullable) NSArray<NSString *> *warnings;
@property(nonatomic,readonly,nullable) NSArray<NSString *> *errors;
@property(nonatomic,readonly,nullable) NSString *superModifier;
@property(nonatomic,readonly,nullable) NSNumber *layoutIndependent;
@property(nonatomic,readonly,nullable) NSNumber *repeatDelayMilliseconds;
@property(nonatomic,readonly,nullable) NSNumber *repeatRateHertz;
@property(nonatomic,readonly,nullable) DWModifiers *cycleHold;
@property(nonatomic,readonly,nullable) DWPointerSettings *settings;
@property(nonatomic,readonly,nullable) NSArray<DWBinding *> *keys;
@property(nonatomic,readonly,nullable) NSArray<DWBinding *> *mediaKeys;
@property(nonatomic,readonly,nullable) NSArray<DWBinding *> *taps;
@property(nonatomic,readonly,nullable) NSArray<DWBinding *> *skipped;
@property(nonatomic,readonly,nullable) NSArray<DWBinding *> *reserved;
@property(nonatomic,readonly,nullable) NSArray<DWHotCornerSettings *> *hotCorners;
- (DWControllerReply *)replyWithoutEffect;
@property(nonatomic,readonly,nullable) NSString *failure;
@property(nonatomic,readonly,nullable) NSString *note;
@property(nonatomic,readonly,nullable) DWGestureAction *fired;
@end
NS_ASSUME_NONNULL_END
