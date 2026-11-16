// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DWRGBA : NSObject <NSCopying>
@property(nonatomic,readonly,nullable) NSNumber *red;
@property(nonatomic,readonly,nullable) NSNumber *green;
@property(nonatomic,readonly,nullable) NSNumber *blue;
@property(nonatomic,readonly,nullable) NSNumber *alpha;
@property(nonatomic,readonly) BOOL hasNumericComponents;
@end
NS_ASSUME_NONNULL_END
