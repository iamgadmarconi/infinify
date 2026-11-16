// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWFlight, DWNavigationContext, DWPointerDemand;
NS_ASSUME_NONNULL_BEGIN
@interface DWNavigation : DWControllerValue
@property(nonatomic,readonly,nullable) DWPointerDemand *cursorPan;
@property(nonatomic,readonly,nullable) DWPointerDemand *hoverPull;
@property(nonatomic,readonly,nullable) NSNumber *clockNanoseconds;
- (nullable DWNavigationContext *)contextForOutput:(NSNumber *)output;
@property(nonatomic,readonly) NSUInteger flightCount;
- (nullable DWFlight *)flightForOutput:(NSNumber *)output;
@property(nonatomic,readonly,nullable) NSNumber *targetZoom;
@property(nonatomic,readonly) CGPoint targetCamera;
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) NSNumber *generation;
@property(nonatomic,readonly) BOOL hasHomeReturns;
@property(nonatomic,readonly) BOOL hasOverviewReturns;
- (BOOL)hasHomeReturnForOutput:(NSNumber *)output;
- (BOOL)hasOverviewReturnForOutput:(NSNumber *)output;
@end
NS_ASSUME_NONNULL_END
