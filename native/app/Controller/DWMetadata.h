// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWMetadata : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *bundleID;
@property(nonatomic,readonly,nullable) NSString *title;

@end
NS_ASSUME_NONNULL_END
