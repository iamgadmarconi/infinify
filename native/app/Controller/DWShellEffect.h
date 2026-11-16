// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWEffect.h"
@class DWScreenshotTarget;
NS_ASSUME_NONNULL_BEGIN
@interface DWShellEffect : DWEffect
@property(nonatomic,readonly,nullable) NSString *app;
@property(nonatomic,readonly,nullable) NSString *bundleID;
@property(nonatomic,readonly,nullable) NSString *command;
@property(nonatomic,readonly,nullable) NSString *source;
@property(nonatomic,readonly,nullable) NSString *action;

@property(nonatomic,readonly,nullable) NSString *path;
@property(nonatomic,readonly,nullable) NSNumber *scale;
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) NSNumber *width;
@property(nonatomic,readonly,nullable) NSNumber *height;
@property(nonatomic,readonly) CGRect region;
@property(nonatomic,readonly,nullable) DWScreenshotTarget *target;
@property(nonatomic,readonly,nullable) NSNumber *minimized;
@property(nonatomic,readonly) CGRect regionOrNull;
@property(nonatomic,readonly,nullable) NSNumber *fitPadding;
@property(nonatomic,readonly,nullable) NSDictionary<NSString *,NSString *> *environment;
@end
NS_ASSUME_NONNULL_END
