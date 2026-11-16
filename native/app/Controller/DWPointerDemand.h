// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWPointerDemand : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *needsPointer;
@property(nonatomic,readonly,nullable) NSNumber *active;

@end
NS_ASSUME_NONNULL_END
