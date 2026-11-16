// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWController.h"
#import "driftwm_desktop.h"
@class DWSnapshotMirror;
NS_ASSUME_NONNULL_BEGIN
// Only the controller implementation and its focus-policy category see the wire.
@interface DWController ()
@property(nonatomic) DriftDesktop *handle;
@property(nonatomic,strong) DWSnapshotMirror *snapshotMirror;
@property(nonatomic,strong,nullable) NSDictionary *snapshotDictionary;
@property(nonatomic,strong,nullable) NSDictionary *visualDictionary;
@property(nonatomic,strong,nullable) DWScene *snapshotValue;
@property(nonatomic,strong,nullable) DWScene *visualValue;
- (nullable NSDictionary *)executeDictionary:(NSDictionary *)command query:(BOOL)query rawResponse:(NSData * _Nullable __autoreleasing * _Nullable)raw;
- (nullable DWControllerReply *)query:(NSDictionary *)command;
- (nullable DWControllerReply *)mutate:(NSDictionary *)command;
// Temporary migration shim. Never import this header from a native adapter.
- (nullable NSDictionary *)legacyCommand:(NSDictionary *)command raw:(NSData * _Nullable __autoreleasing * _Nullable)raw;
- (NSDictionary *)attachCommandDictionary:(DWAttachRequest *)request;
// Exactly the old navigationCall tail, including nested facts and snapshots.
- (nullable DWControllerReply *)navigationCommandDictionary:(NSDictionary *)command;
- (nullable DWControllerReply *)policyFactDictionary:(NSDictionary *)fact timestamp:(uint64_t)timestamp filter:(BOOL)filter focusAllowed:(BOOL)focusAllowed;
@end
NS_ASSUME_NONNULL_END
