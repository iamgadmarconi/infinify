// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
// Wrong-class is distinct from missing and explicit JSON null; typed accessors return nil for all three.
typedef NS_ENUM(NSUInteger,DWValuePresence) { DWValueAbsent, DWValueNull, DWValueMalformed, DWValuePresent };
// Immutable decoded value. Copy returns self. Access is confined to the controller/main queue.
@interface DWControllerValue : NSObject <NSCopying>
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
