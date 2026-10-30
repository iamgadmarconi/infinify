// SPDX-License-Identifier: GPL-3.0-or-later
// DWNativeReplicaFamilies: negative capture history, recovery admission and the failure and drawable callbacks of members.
// Split from native/app/CompositorMode/DWNativeReplicaFamilies.m (0b3f028; native/desktop/native-replica-family.m at 37b27b1), moved verbatim.
#import "DWNativeReplicaFamilies+Private.h"
static BOOL familyRecoveryMatches(DWReplicaRecovery *recovery,NSDictionary *root,NSDictionary *identity,CGRect bounds) {
    return recovery&&familyBinding(recovery.root,root)&&[recovery.identity isEqual:identity]&&CGRectEqualToRect(recovery.bounds,bounds);
}
static CFTimeInterval familyRecoveryDelay(NSDictionary *identity,NSUInteger failures) {
    uint64_t hash=1469598103934665603ULL;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"]){hash^=[identity[key]unsignedLongLongValue];hash*=1099511628211ULL;}
    hash^=failures;hash*=1099511628211ULL;
    // Half a second, doubling to a thirty-second ceiling. Positive jitter
    // remains at the ceiling too, so simultaneous failures do not stay aligned.
    return MIN(29.75,ldexp(.5,(int)MIN(MAX(failures,1)-1,6)))+.25*(double)(1+hash%1024)/1024.;
}
@implementation DWNativeReplicaFamilies (Recovery)
- (DWReplicaRecovery *)recovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds {
    NSNumber *logical=root[@"window"],*wid=identity[@"wid"];
    NSMutableDictionary<NSNumber *,DWReplicaRecovery *> *family=self.recoveries[logical];
    DWReplicaRecovery *recovery=family[wid];
    if(!familyRecoveryMatches(recovery,root,identity,bounds)){
        // The caller just validated this exact replacement on the observer and
        // checked birth/freshness on main. Density/rate alone never reset it.
        if(!recovery&&family.count>=64)return nil;
        if(!family){family=[NSMutableDictionary dictionary];self.recoveries[logical]=family;}
        recovery=[DWReplicaRecovery new];recovery.root=root;recovery.identity=identity;recovery.bounds=bounds;recovery.waiting=++self.admissionSequence;family[wid]=recovery;
    }
    return recovery;
}
- (DWReplicaRecovery *)admitRecovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds starting:(NSUInteger *)starting {
    DWReplicaRecovery *recovery=[self recovery:identity root:root bounds:bounds];
    if(!recovery||*starting>=2||(recovery.failures&&CACurrentMediaTime()<recovery.notBefore))return nil;
    NSUInteger all=0,family=0;
    for(DWReplicaMember *attempt in self.coldAttempts.allObjects){
        if(!atomic_load(&attempt->alive)||attempt.image.buffer){[self.coldAttempts removeObject:attempt];continue;}
        all++;family+=[attempt.root[@"window"]isEqual:root[@"window"]];
    }
    if(all>=4||family>=2)return nil;
    (*starting)++;recovery.waiting=++self.admissionSequence;
    NSNumber *logical=root[@"window"];[self.admissionRoots removeObject:logical];[self.admissionRoots addObject:logical];
    return recovery;
}
- (NSArray<NSNumber *> *)admissionRootOrder {
    for(NSNumber *logical in self.admissionRoots.copy)if(!self.roots[logical])[self.admissionRoots removeObject:logical];
    for(NSNumber *logical in [self.roots.allKeys sortedArrayUsingSelector:@selector(compare:)])if(![self.admissionRoots containsObject:logical])[self.admissionRoots addObject:logical];
    return self.admissionRoots.copy;
}
- (NSArray<NSDictionary *> *)admissionPlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root {
    if(plans.count<2)return plans;
    // FIFO tickets, not numeric WID order or unconditional new-child priority:
    // a due persistent child keeps its place despite endlessly replaced peers.
    NSDictionary<NSNumber *,DWReplicaRecovery *> *family=self.recoveries[root[@"window"]];
    return [plans sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        DWReplicaRecovery *left=family[a[@"identity"][@"wid"]],*right=family[b[@"identity"][@"wid"]];
        uint64_t x=familyRecoveryMatches(left,root,a[@"identity"],DWRectFromJSON(a[@"native_bounds"]))?left.waiting:UINT64_MAX;
        uint64_t y=familyRecoveryMatches(right,root,b[@"identity"],DWRectFromJSON(b[@"native_bounds"]))?right.waiting:UINT64_MAX;
        return x<y?NSOrderedAscending:x>y?NSOrderedDescending:[a[@"identity"][@"wid"]compare:b[@"identity"][@"wid"]];
    }];
}
- (void)acceptRecoveryCohort:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root sampledAt:(NSNumber *)began {
    NSMutableDictionary<NSNumber *,DWReplicaRecovery *> *family=self.recoveries[root[@"window"]];
    if(!plans.count&&!family.count)return;
    if(!began||!familyBinding(self.roots[root[@"window"]],root)||!familyProcessMatches(root[@"identity"]))return;
    CFTimeInterval age=CACurrentMediaTime()-began.doubleValue;if(age<0||age>.1)return;
    NSMutableDictionary *current=[NSMutableDictionary dictionary];for(NSDictionary *plan in plans)current[plan[@"identity"][@"wid"]]=plan;
    for(NSNumber *wid in family.allKeys){NSDictionary *plan=current[wid];
        if(!plan||!familyRecoveryMatches(family[wid],root,plan[@"identity"],DWRectFromJSON(plan[@"native_bounds"])))
            [family removeObjectForKey:wid];
    }
    if(!family.count)[self.recoveries removeObjectForKey:root[@"window"]];
    // A fresh complete observation gives waiting members a stable place before
    // capacity is consulted. Merely waiting never consumes a start allowance.
    for(NSDictionary *plan in plans)[self recovery:plan[@"identity"] root:root bounds:DWRectFromJSON(plan[@"native_bounds"])];
}
- (void)memberFailed:(DWReplicaMember *)member {
    NSNumber *window=member.root[@"window"];
    DWReplicaRecovery *recovery=self.recoveries[window][member.identity[@"wid"]];
    if(recovery.attempt!=member||!familyRecoveryMatches(recovery,member.root,member.identity,member.bounds)
       ||!familyBinding(self.roots[window],member.root))return;
    recovery.failures=MIN(7,recovery.failures+1);
    recovery.notBefore=CACurrentMediaTime()+familyRecoveryDelay(member.identity,recovery.failures);
    [self beginChanges];
    [self.drawableAttachments removeObjectForKey:window];
    self.epoch++;self.reading=NO;self.nextRead=MIN(self.nextRead,CACurrentMediaTime()+.25);
    [self markOrderingChanged];[self invalidateOrdering];[self changedWindow:window];
    [self endChanges];
}
- (void)memberBecameDrawable:(DWReplicaMember *)member {
    [self.coldAttempts removeObject:member];
    NSNumber *window=member.root[@"window"];
    DWReplicaRecovery *recovery=self.recoveries[window][member.identity[@"wid"]];
    if(recovery.attempt==member&&familyRecoveryMatches(recovery,member.root,member.identity,member.bounds)){
        recovery.failures=0;recovery.notBefore=0;
    }
    // A first image changes the default token membership and may complete an
    // observed family. Later pixel frames leave ordering/revision untouched.
    [self beginChanges];[self.drawableAttachments removeObjectForKey:window];[self markOrderingChanged];[self changedWindow:window];[self endChanges];
}
- (void)memberBecameUnavailable:(DWReplicaMember *)member {
    NSNumber *window=member.root[@"window"];
    if(![self.members[window]containsObject:member]||!familyBinding(self.roots[window],member.root))return;
    // Availability changes drawing/input only: the stream, immutable audit and
    // retry history remain intact until a real lifecycle failure occurs.
    [self beginChanges];[self.drawableAttachments removeObjectForKey:window];[self markOrderingChanged];[self changedWindow:window];[self endChanges];
}
- (void)invalidatePID:(pid_t)pid discardRecovery:(BOOL)discard {
    [self beginChanges];[self invalidateOrdering];
    self.epoch++;self.reading=NO;self.nextRead=0;
    for(NSNumber *window in self.members.allKeys)if(!pid||[self.roots[window][@"identity"][@"pid"]intValue]==pid){
        for(DWReplicaMember *member in self.members[window])[member retire];[self.members removeObjectForKey:window];[self.drawableAttachments removeObjectForKey:window];[self markOrderingChanged];[self changedWindow:window];
    }
    if(discard)for(NSNumber *window in self.recoveries.allKeys)if(!pid||[self.roots[window][@"identity"][@"pid"]intValue]==pid)[self.recoveries removeObjectForKey:window];
    if(discard)for(NSNumber *window in self.admissionRoots.copy)if(!pid||[self.roots[window][@"identity"][@"pid"]intValue]==pid)[self.admissionRoots removeObject:window];
    NSMutableDictionary *descriptions=[self.descriptions mutableCopy]?:[NSMutableDictionary dictionary];
    for(NSNumber *window in descriptions.allKeys)if(!pid||[descriptions[window][@"identity"][@"pid"]intValue]==pid)[descriptions removeObjectForKey:window];
    [self replaceDescriptions:descriptions.copy];
    [self endChanges];
}
@end
