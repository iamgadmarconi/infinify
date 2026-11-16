// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWModifiers;
NS_ASSUME_NONNULL_BEGIN
@interface DWBinding : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *kind;
@property(nonatomic,readonly,nullable) NSString *action;
@property(nonatomic,readonly,nullable) NSString *combo;
@property(nonatomic,readonly,nullable) NSNumber *implemented;
@property(nonatomic,readonly,nullable) NSNumber *focus;
@property(nonatomic,readonly,nullable) NSNumber *speed;
@property(nonatomic,readonly,nullable) NSNumber *panSpeed;
@property(nonatomic,readonly,nullable) NSNumber *zoomSpeed;
@property(nonatomic,readonly,nullable) NSNumber *invert;
@property(nonatomic,readonly,nullable) NSNumber *passable;
@property(nonatomic,readonly,nullable) NSNumber *keyCode;
@property(nonatomic,readonly,nullable) NSNumber *nxKeyType;
@property(nonatomic,readonly,nullable) DWModifiers *modifiers;
@property(nonatomic,readonly,nullable) NSString *key;

@property(nonatomic,readonly,nullable) NSNumber *trackpadSpeed;
@property(nonatomic,readonly,nullable) NSNumber *mouseSpeed;
@property(nonatomic,readonly,nullable) NSNumber *zoomStep;
@property(nonatomic,readonly,nullable) NSNumber *zoomMouseSpeed;
@property(nonatomic,readonly,nullable) NSNumber *zoomTrackpadSpeed;
@property(nonatomic,readonly,nullable) NSString *chord;
@property(nonatomic,readonly,nullable) NSNumber *repeat;
@property(nonatomic,readonly,nullable) NSString *character;
@property(nonatomic,readonly,nullable) NSString *reason;
@property(nonatomic,readonly,nullable) NSString *purpose;
@end
NS_ASSUME_NONNULL_END
