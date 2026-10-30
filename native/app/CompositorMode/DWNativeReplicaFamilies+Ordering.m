// SPDX-License-Identifier: GPL-3.0-or-later
// DWNativeReplicaFamilies: the native back-to-front ordering of captured members.
// Split from native/app/CompositorMode/DWNativeReplicaFamilies.m (0b3f028; native/desktop/native-replica-family.m at 37b27b1), moved verbatim.
#import "DWNativeReplicaFamilies+Private.h"
@implementation DWNativeReplicaFamilies (Ordering)
- (NSArray<NSDictionary *> *)orderedRun:(NSArray<NSDictionary *> *)tokens range:(NSRange)range {
    NSMutableDictionary<NSNumber *,DWReplicaOrder *> *families=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSMutableSet<NSString *> *> *keys=[NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *roots=[NSMutableSet set],*seenRanks=[NSMutableSet set];
    NSMutableArray<NSArray *> *ranked=[NSMutableArray arrayWithCapacity:range.length];NSNumber *previousRoot=nil;
    for(NSUInteger i=range.location;i<NSMaxRange(range);i++){
        NSDictionary *token=tokens[i];NSNumber *window=token[@"window"];id key=token[@"key"];
        if(![window isKindOfClass:NSNumber.class])return nil;
        DWReplicaOrder *order=self.ordering[window];
        if(!order)return nil;
        if(!families[window]){
            if(!familyBinding(order.root,self.roots[window])||![order.members isEqual:self.members[window]]
               ||order.ranks.count!=order.members.count)return nil;
            families[window]=order;keys[window]=[NSMutableSet set];
        }
        NSNumber *rank=nil;
        if(key){
            if(![key isKindOfClass:NSString.class]||![key length]||[keys[window]containsObject:key])return nil;
            rank=order.ranks[key];[keys[window]addObject:key];
        }else{
            if([roots containsObject:window])return nil;
            rank=order.rank;if(!rank)return nil;
            // WindowServer enumeration is front to back; the supplied root
            // tokens are the controller's back-to-front order and must agree.
            if(previousRoot&&[previousRoot compare:rank]!=NSOrderedDescending)return nil;
            previousRoot=rank;[roots addObject:window];
        }
        if(!rank||[seenRanks containsObject:rank])return nil;
        [seenRanks addObject:rank];[ranked addObject:@[token,rank]];
    }
    for(NSNumber *window in families){DWReplicaOrder *order=families[window];
        if(![roots containsObject:window]||keys[window].count!=order.members.count)return nil;
        for(DWReplicaMember *member in order.members){
            if(![member imageAvailable]||!member.image.buffer||!familyBinding(member.root,self.roots[window])
               ||!member.image.key||![keys[window]containsObject:member.image.key]||!order.ranks[member.image.key])return nil;
        }
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [b[1]compare:a[1]];}];
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:range.length];for(NSArray *entry in ranked)[result addObject:entry[0]];
    return result;
}
- (NSArray<NSDictionary *> *)orderedTokens:(NSArray<NSDictionary *> *)tokens {
    if(!self.ordering.count||self.orderingEpoch!=self.epoch||!self.orderingObservation)return tokens;
    NSMutableArray *result=nil;
    for(NSUInteger start=0;start<tokens.count;){
        NSDictionary *token=tokens[start];
        if(![token isKindOfClass:NSDictionary.class]||familyBarrier(token)){start++;continue;}
        NSNumber *bucket=familyBucket(token);if(!bucket){start++;continue;}
        NSUInteger end=start+1;
        while(end<tokens.count&&[tokens[end]isKindOfClass:NSDictionary.class]
              &&!familyBarrier(tokens[end])&&[bucket isEqual:familyBucket(tokens[end])])end++;
        NSRange range=NSMakeRange(start,end-start);NSArray *ordered=[self orderedRun:tokens range:range];
        if(ordered){BOOL changed=NO;for(NSUInteger i=0;i<ordered.count;i++)if(ordered[i]!=tokens[start+i]){changed=YES;break;}
            if(changed){if(!result)result=[tokens mutableCopy];[result replaceObjectsInRange:range withObjectsFromArray:ordered];}
        }
        start=end;
    }
    return result?result.copy:tokens;
}
@end
