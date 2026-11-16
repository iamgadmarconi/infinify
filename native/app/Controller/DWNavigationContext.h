// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWNavigationContext : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *mode;
@property(nonatomic,readonly,nullable) NSNumber *zoom;
@property(nonatomic,readonly) CGPoint camera;

@property(nonatomic,readonly) DWValuePresence cameraPresence;
@property(nonatomic,readonly) BOOL cameraHasNumericComponents;
@property(nonatomic,readonly) CGRect usableRectLocal;
@property(nonatomic,readonly) CGRect usableRectLocalOrNull;
@end
NS_ASSUME_NONNULL_END
