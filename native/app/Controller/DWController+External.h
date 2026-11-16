// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWController.h"
NS_ASSUME_NONNULL_BEGIN
// This bridge is solely for already validated public IPC/persistence commands.
// Internal clients use the narrow semantic protocols above, never JSON commands.
@protocol DWExternalController <NSObject>
- (nullable DWControllerReply *)executeExternalCommand:(NSDictionary *)command rawResponse:(NSData * _Nullable __autoreleasing * _Nullable)raw;
@end

@interface DWController (External) <DWExternalController>
@end
// Exact public JSON values for the IPC serializer only. Internal consumers use
// typed reply/geometry accessors instead of these external representations.
@interface DWControllerReply (External)
@property(nonatomic,readonly,nullable) NSDictionary *externalReplyObject;
@end
@interface DWPlacement (External)
@property(nonatomic,readonly,nullable) id externalScreenRect;
@property(nonatomic,readonly,nullable) id externalClipRect;
@end
NS_ASSUME_NONNULL_END
