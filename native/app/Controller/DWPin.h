// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWPin : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly) CGRect screenRect;

@property(nonatomic,readonly) DWValuePresence screenRectPresence;
@property(nonatomic,readonly) BOOL screenRectHasNumericComponents;
@property(nonatomic,readonly) CGRect screenRectOrNull;
@end
NS_ASSUME_NONNULL_END
