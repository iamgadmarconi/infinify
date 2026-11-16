// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWPointerSettings : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *trackpadSpeed;
@property(nonatomic,readonly,nullable) NSNumber *mouseSpeed;
@property(nonatomic,readonly,nullable) NSNumber *zoomStep;
@property(nonatomic,readonly,nullable) NSNumber *zoomMouseSpeed;
@property(nonatomic,readonly,nullable) NSNumber *zoomTrackpadSpeed;
@end
NS_ASSUME_NONNULL_END
