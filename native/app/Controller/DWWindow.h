// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWDrawnValue.h"
@class DWMetadata, DWPin, DWPlacement, DWWindowRule;
NS_ASSUME_NONNULL_BEGIN
@interface DWWindow : DWDrawnValue
@property(nonatomic,readonly,nullable) DWMetadata *metadata;
@property(nonatomic,readonly,nullable) DWPin *pinned;
@property(nonatomic,readonly,nullable) DWWindowRule *rule;
@property(nonatomic,readonly,nullable) NSString *mode;
- (DWPlacement *)placementOnOutput:(NSNumber *)output screenRect:(CGRect)screenRect clipRect:(CGRect)clipRect pinned:(BOOL)pinned familyOnly:(BOOL)familyOnly;
- (BOOL)hasSameSizeTransitionBindingAsWindow:(DWWindow *)other;
- (DWPlacement *)capturePlacement;
- (BOOL)hasSameSizeTransitionBindingAsWindow:(DWWindow *)other ignoringWorldRect:(BOOL)ignore;
@property(nonatomic,readonly) BOOL isPinned;
@end
NS_ASSUME_NONNULL_END
