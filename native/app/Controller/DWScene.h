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
@interface DWScene : DWControllerValue
@property(nonatomic,readonly,nullable) DWFocus *focus;
@property(nonatomic,readonly,nullable) DWNavigation *navigation;
@property(nonatomic,readonly,nullable) DWResizeTransaction *nativeResize;
@property(nonatomic,readonly,nullable) DWRender *render;
@property(nonatomic,readonly,nullable) DWLifecycle *lifecycle;
@property(nonatomic,readonly,nullable) NSArray<DWWindow *> *windows;
@property(nonatomic,readonly,nullable) NSArray<DWPlacement *> *placements;
@property(nonatomic,readonly,nullable) NSArray<DWOutput *> *outputs;
@property(nonatomic,readonly,nullable) NSArray<DWLifecycleEvent *> *lifecycleEvents;
- (nullable DWWindow *)windowWithID:(NSNumber *)identifier;
- (nullable DWOutput *)outputWithID:(NSNumber *)identifier;
- (DWScene *)sceneWithPlacements:(NSArray<DWPlacement *> *)placements;
- (DWScene *)sceneWithOutputs:(NSArray<DWOutput *> *)outputs;
@property(nonatomic,readonly) DWValuePresence nativeResizePresence;
@property(nonatomic,readonly,nullable) NSNumber *passesAllKeys;
@property(nonatomic,readonly,nullable) NSArray<NSString *> *passedKeyCombos;
@property(nonatomic,readonly) DWValuePresence passKeysPresence;
@property(nonatomic,readonly) BOOL windowsAreObjects;
@property(nonatomic,readonly) BOOL placementsAreObjects;
@property(nonatomic,readonly) BOOL hasCurrentOutputPlacements;
@end
NS_ASSUME_NONNULL_END
