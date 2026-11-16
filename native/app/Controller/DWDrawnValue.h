// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWDecoration, DWSource;
NS_ASSUME_NONNULL_BEGIN
@interface DWDrawnValue : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly) CGRect worldRect;
@property(nonatomic,readonly,nullable) NSString *kind;
@property(nonatomic,readonly,nullable) NSNumber *focused;
@property(nonatomic,readonly,nullable) NSString *title;
@property(nonatomic,readonly,nullable) NSString *appName;
@property(nonatomic,readonly,nullable) NSNumber *launching;
@property(nonatomic,readonly,nullable) DWDecoration *decoration;
@property(nonatomic,readonly,nullable) DWSource *source;
@property(nonatomic,readonly,nullable) NSNumber *opacity;
@property(nonatomic,readonly,nullable) NSNumber *presentationSettled;
@property(nonatomic,readonly,nullable) NSNumber *widget;

@property(nonatomic,readonly) DWValuePresence worldRectPresence;
@property(nonatomic,readonly) BOOL worldRectHasNumericComponents;
@property(nonatomic,readonly) CGRect worldRectOrNull;
@property(nonatomic,readonly) BOOL isCurrentDrawnPlacement;
@end
NS_ASSUME_NONNULL_END
