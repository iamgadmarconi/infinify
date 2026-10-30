// SPDX-License-Identifier: GPL-3.0-or-later
// DWReplicaRecovery: negative capture history of one native child.
// Split from native/desktop/native-replica-family.m at 37b27b1, moved verbatim.
#import <Foundation/Foundation.h>
@class DWReplicaMember;
// Main-owned negative capture history, never identity or input authority. Keep
// the exact attempt weakly: callbacks from a retired stream cannot charge a
// replacement with the same numeric WID. The native family reader is bounded to
// 64 associations; stale observations cannot grow this table without bound.
@interface DWReplicaRecovery : NSObject
@property NSDictionary *root,*identity;
@property CGRect bounds;
@property(weak) DWReplicaMember *attempt;
@property NSUInteger failures;
@property CFTimeInterval notBefore;
@property uint64_t waiting;
@end
