// SPDX-License-Identifier: GPL-3.0-or-later
// DWReplicaOrder: one root's members and ranks in a native ordering observation.
// Split from native/desktop/native-replica-family.m at 37b27b1, moved verbatim.
#import <Foundation/Foundation.h>
@class DWReplicaMember;
@interface DWReplicaOrder : NSObject
@property NSDictionary *root;
@property NSNumber *rank;
@property NSArray<DWReplicaMember *> *members;
@property NSDictionary<NSString *,NSNumber *> *ranks;
@end
