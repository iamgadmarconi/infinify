// SPDX-License-Identifier: GPL-3.0-or-later
// DWNativeReplicaFamilies: native child windows of a root, captured as replicas.
// Split from native/desktop/native-replica-family.m at 37b27b1, moved verbatim.
#import "DWNativeReplicaFamilies+Private.h"
@implementation DWNativeReplicaFamilies
- (instancetype)initWithChanged:(void (^)(NSNumber *))changed {
    if((self=[super init])){_changed=[changed copy];_roots=@{};_members=[NSMutableDictionary dictionary];_drawableAttachments=[NSMutableDictionary dictionary];_recoveries=[NSMutableDictionary dictionary];
        _coldAttempts=[NSHashTable weakObjectsHashTable];_admissionRoots=[NSMutableArray array];
        _observer=familyQueue("org.infinify.native-family-replicas");}
    return self;
}
- (void)beginChanges {
    if(!self.changeDepth)self.changedWindows=[NSMutableSet set];
    self.changeDepth++;
}
- (void)endChanges {
    if(--self.changeDepth)return;
    if(self.orderingChanged){self.orderRevision++;self.orderingChanged=NO;}
    NSSet<NSNumber *> *changed=self.changedWindows;self.changedWindows=nil;
    for(NSNumber *window in changed)if(self.changed)self.changed(window);
}
- (void)changedWindow:(NSNumber *)window {
    if(!window)return;
    if(self.changeDepth)[self.changedWindows addObject:window];
    else if(self.changed)self.changed(window);
}
- (void)markOrderingChanged {
    BOOL own=!self.changeDepth;if(own)[self beginChanges];
    self.orderingChanged=YES;
    [self.changedWindows addObjectsFromArray:self.roots.allKeys];
    [self.changedWindows addObjectsFromArray:self.ordering.allKeys?:@[]];
    if(own)[self endChanges];
}
- (void)invalidateOrdering {
    if(self.ordering.count)[self markOrderingChanged];
    self.ordering=nil;self.orderingEpoch=0;self.orderingObservation=0;
}
- (void)reset {
    [self beginChanges];
    NSArray<NSNumber *> *changed=self.members.allKeys;
    if(self.roots.count||self.members.count||self.ordering.count)[self markOrderingChanged];
    self.epoch++;self.reading=NO;self.nextRead=0;
    [self invalidateOrdering];
    for(NSArray<DWReplicaMember *> *family in self.members.allValues)for(DWReplicaMember *member in family)[member retire];
    [self.members removeAllObjects];[self.drawableAttachments removeAllObjects];[self.recoveries removeAllObjects];[self.coldAttempts removeAllObjects];[self.admissionRoots removeAllObjects];self.admissionSequence=0;self.roots=@{};
    [self replaceDescriptions:@{}];
    for(NSNumber *window in changed)[self changedWindow:window];
    [self endChanges];
}
- (NSArray<NSDictionary *> *)capturePlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root {
    if([root[@"capture"]isEqual:@NO])return @[];
    CFTimeInterval now=CACurrentMediaTime();NSMutableArray *wanted=[NSMutableArray array];
    for(NSDictionary *plan in plans){CGRect bounds=DWRectFromJSON(plan[@"native_bounds"]);DWReplicaMember *installed=nil;
        for(DWReplicaMember *member in self.members[root[@"window"]])if(atomic_load(&member->alive)&&familyBinding(member.root,root)&&[member.identity isEqual:plan[@"identity"]]&&CGRectEqualToRect(member.bounds,bounds)){installed=member;break;}
        BOOL visible=familyIntersectsCapture(root,bounds);
        if(visible&&installed)installed.lastVisible=now;
        // Match the root's two-second grace: crossing a viewport boundary
        // briefly must not repeatedly stop/start a healthy child's stream.
        if(visible||(installed&&now-installed.lastVisible<2))[wanted addObject:plan];
    }
    return wanted.copy;
}
- (void)pruneCaptureDemand {
    CFTimeInterval now=CACurrentMediaTime();
    for(NSNumber *window in self.members.allKeys){NSDictionary *root=self.roots[window];NSArray *old=self.members[window];NSMutableArray *kept=[NSMutableArray array];
        for(DWReplicaMember *member in old){BOOL visible=familyIntersectsCapture(root,member.bounds);
            if(visible)member.lastVisible=now;
            if(visible||(![root[@"capture"]isEqual:@NO]&&now-member.lastVisible<2))[kept addObject:member];else [member retire];
        }
        if(kept.count==old.count)continue;
        self.members[window]=kept.copy;[self.drawableAttachments removeObjectForKey:window];
        // The same audited native ranks remain valid for a smaller drawn
        // subset. Do not replace them with controller/default grouping.
        DWReplicaOrder *prior=self.ordering[window];
        if(prior){DWReplicaOrder *order=[DWReplicaOrder new];order.root=prior.root;order.rank=prior.rank;order.members=kept.copy;
            NSMutableDictionary *ranks=[NSMutableDictionary dictionary];for(DWReplicaMember *member in kept)if(prior.ranks[member.image.key])ranks[member.image.key]=prior.ranks[member.image.key];order.ranks=ranks.copy;
            NSMutableDictionary *ordering=[self.ordering mutableCopy];ordering[window]=order;self.ordering=ordering.copy;
        }
        [self markOrderingChanged];[self changedWindow:window];
    }
}
- (void)describe:(NSArray<NSDictionary *> *)roots rate:(NSInteger)rate {
    NSMutableDictionary *wanted=[NSMutableDictionary dictionary];
    for(NSDictionary *root in roots)if(root[@"window"]&&root[@"identity"]&&root[@"generation"]&&familySize(DWRectFromJSON(root[@"native_bounds"])))wanted[root[@"window"]]=root;
    NSInteger hz=MAX(1,MIN(rate,240));BOOL bindingChanged=!familyCohortMatches(self.roots,wanted),configurationChanged=self.rate!=hz;
    for(NSNumber *window in wanted)if(![self.roots[window][@"density"]isEqual:wanted[window][@"density"]]||[self.roots[window][@"capture"]isEqual:@NO]!=[wanted[window][@"capture"]isEqual:@NO])configurationChanged=YES;
    BOOL visibilityGained=NO;
    if(!bindingChanged)for(NSNumber *window in wanted){NSDictionary *before=self.roots[window],*after=wanted[window],*known=self.descriptions[window];
        if(!familyBinding(known,after))continue;
        for(NSDictionary *member in known[@"members"]){
            if([member[@"identity"][@"wid"]isEqual:after[@"identity"][@"wid"]])continue;
            CGRect bounds=DWRectFromJSON(member[@"native_bounds"]);
            if(!familyIntersectsCapture(before,bounds)&&familyIntersectsCapture(after,bounds)){visibilityGained=YES;break;}
        }
        if(visibilityGained)break;
    }
    [self beginChanges];
    if(bindingChanged){self.epoch++;self.reading=NO;[self invalidateOrdering];}
    for(NSNumber *window in self.members.allKeys)if(!familyBinding(self.roots[window],wanted[window])||[wanted[window][@"capture"]isEqual:@NO]){
        for(DWReplicaMember *member in self.members[window])[member retire];[self.members removeObjectForKey:window];
        [self.drawableAttachments removeObjectForKey:window];
        [self changedWindow:window];
    }
    for(NSNumber *window in self.recoveries.allKeys)if(!familyBinding(self.roots[window],wanted[window])||[wanted[window][@"capture"]isEqual:@NO])[self.recoveries removeObjectForKey:window];
    for(NSNumber *window in self.admissionRoots.copy)if(!familyBinding(self.roots[window],wanted[window])||[wanted[window][@"capture"]isEqual:@NO])[self.admissionRoots removeObject:window];
    self.roots=wanted.copy;self.rate=hz;
    [self pruneCaptureDemand];
    NSMutableDictionary *descriptions=[self.descriptions mutableCopy]?:[NSMutableDictionary dictionary];
    for(NSNumber *window in descriptions.allKeys)if(!familyBinding(descriptions[window],wanted[window]))[descriptions removeObjectForKey:window];
    [self replaceDescriptions:descriptions.copy];
    if(bindingChanged)[self markOrderingChanged];
    // A known child becoming visible wakes discovery once, rather than waiting
    // for the idle refresh. Persistent visibility or missing pixels do not
    // continually wake audits or bypass the child's recovery backoff.
    if(bindingChanged||configurationChanged||visibilityGained)self.nextRead=0;
    [self endChanges];
    if(self.roots.count&&CACurrentMediaTime()>=self.nextRead)[self request];
}
- (NSArray<DWCanvasAttachment *> *)attachments:(NSNumber *)window {
    NSArray<DWReplicaMember *> *members=self.members[window];if(!members.count)return @[];
    NSArray<DWCanvasAttachment *> *cached=self.drawableAttachments[window];
    // Revoke cached drawing immediately even before the queued withdrawal runs.
    for(DWReplicaMember *member in members)if(member.image.buffer&&![member imageAvailable]){cached=nil;[self.drawableAttachments removeObjectForKey:window];break;}
    if(cached)return cached;
    // Pixel frames update these same attachment objects. Materialize only when
    // capture membership or first-image availability changes, on the main queue.
    NSMutableArray *images=[NSMutableArray array];
    for(DWReplicaMember *member in members)if([member imageAvailable]&&member.image.buffer)[images addObject:member.image];
    cached=images.copy;self.drawableAttachments[window]=cached;return cached;
}
- (NSDictionary *)hit:(NSNumber *)window local:(CGPoint)local {
    for(DWReplicaMember *member in [self.members[window]reverseObjectEnumerator]){
        NSDictionary *hit=familyHit(member,self.roots[window],local);if(hit)return hit;
    }
    return nil;
}
- (NSDictionary *)hit:(NSNumber *)window key:(NSString *)key local:(CGPoint)local {
    if(![key isKindOfClass:NSString.class]||!key.length)return nil;
    DWReplicaMember *found=nil;
    for(DWReplicaMember *member in self.members[window])if([member.image.key isEqual:key]){if(found)return nil;found=member;}
    return found?familyHit(found,self.roots[window],local):nil;
}
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds {
    for(DWReplicaMember *member in self.members[window])if([member imageAvailable]&&member.image.buffer&&[member.identity isEqual:identity]&&[member.root[@"generation"]isEqual:generation]&&CGRectEqualToRect(member.bounds,bounds)&&familyBinding(member.root,self.roots[window])){
        CGRect rootNow=CGRectZero,memberNow=CGRectZero;
        return DWNativeBounds([member.root[@"identity"][@"wid"]unsignedIntValue],&rootNow)&&DWNativeBounds([member.identity[@"wid"]unsignedIntValue],&memberNow)
            &&CGRectEqualToRect(rootNow,member.rootBounds)&&CGRectEqualToRect(memberNow,member.bounds);
    }
    return NO;
}
- (void)invalidatePID:(pid_t)pid {
    [self invalidatePID:pid discardRecovery:YES];
}
- (void)replaceDescriptions:(NSDictionary<NSNumber *,NSDictionary *> *)descriptions {
    if([self.descriptions isEqual:descriptions])return;
    NSDictionary *prior=self.descriptions;self.descriptions=descriptions.copy;
    NSMutableSet *windows=[NSMutableSet setWithArray:prior.allKeys?:@[]];[windows addObjectsFromArray:descriptions.allKeys];
    for(NSNumber *window in windows)if(![prior[window]isEqual:descriptions[window]])[self changedWindow:window];
}
- (void)request {
    // An uncancellable shareable-content request remains outstanding even after
    // its deadline. Never pile later observations behind a stalled native read.
    if(self.reading||self.requestPending||!self.roots.count)return;
    // A request sequence is not a binding epoch: keep the last complete order
    // during an ordinary refresh, then replace the whole cohort atomically.
    self.reading=YES;self.requestPending=YES;NSUInteger sequence=++self.requestSequence,epoch=self.epoch;NSDictionary *roots=self.roots;self.nextRead=CACurrentMediaTime()+1;
    dispatch_queue_t observer=self.observer;__weak DWNativeReplicaFamilies *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        DWNativeReplicaFamilies *owner=weak;if(!owner||!owner.reading||owner.epoch!=epoch||owner.requestSequence!=sequence)return;
        [owner invalidatePID:0 discardRecovery:NO];owner.nextRead=CACurrentMediaTime()+1;
    });
    dispatch_async(self.observer,^{
        // TCC preflight may synchronously wait on another process. Check once
        // per bounded observation here, never in the main-thread description
        // path (including empty families). This is not a cached grant: every
        // discovery rechecks, and stream errors still retire revoked captures.
        if(!CGPreflightScreenCaptureAccess()){
            dispatch_async(dispatch_get_main_queue(),^{
                DWNativeReplicaFamilies *owner=weak;if(!owner)return;owner.requestPending=NO;
                if(!owner.reading||owner.epoch!=epoch||owner.requestSequence!=sequence||!familyCohortMatches(owner.roots,roots))return;
                [owner invalidatePID:0];owner.nextRead=CACurrentMediaTime()+1;
            });
            return;
        }
        NSMutableDictionary *plans=[NSMutableDictionary dictionary],*descriptions=[NSMutableDictionary dictionary],*sampledAt=[NSMutableDictionary dictionary];NSMutableSet *completeRoots=[NSMutableSet set];
        // This option documents front-to-back order. Offscreen captures remain
        // eligible for default grouping, but cannot borrow an inferred rank.
        NSArray *ordered=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
        NSMutableDictionary *ranks=[NSMutableDictionary dictionary],*owners=[NSMutableDictionary dictionary];NSMutableSet *seen=[NSMutableSet set];
        for(NSUInteger i=0;i<ordered.count;i++){
            NSNumber *wid=ordered[i][(id)kCGWindowNumber],*pid=ordered[i][(id)kCGWindowOwnerPID];
            if(!frameNumber(wid)||[wid doubleValue]<=0||[wid doubleValue]>UINT32_MAX||floor([wid doubleValue])!=[wid doubleValue])continue;
            if([seen containsObject:wid]){[ranks removeObjectForKey:wid];[owners removeObjectForKey:wid];continue;}[seen addObject:wid];
            if(!frameNumber(pid)||[pid doubleValue]<=1||[pid doubleValue]>INT_MAX||floor([pid doubleValue])!=[pid doubleValue])continue;
            ranks[wid]=@(i);owners[wid]=pid;
        }
        for(NSNumber *window in roots){CFTimeInterval began=CACurrentMediaTime();NSString *why=nil;NSDictionary *family=DWNativeWindowFamily(roots[window][@"identity"],&why);
            NSMutableArray *children=[NSMutableArray array],*members=[NSMutableArray array];CGRect rootBounds=DWRectFromJSON(roots[window][@"native_bounds"]);NSUInteger rootCount=0;BOOL rankedChildren=YES;
            for(NSDictionary *member in family[@"members"]){
                if([member[@"identity"][@"wid"]isEqual:roots[window][@"identity"][@"wid"]]){rootCount++;if(!CGRectEqualToRect(DWRectFromJSON(member[@"native_bounds"]),rootBounds))family=nil;[members addObject:member];continue;}
                [members addObject:member];
                [children addObject:member];if(!familyRank(ranks,owners,member[@"identity"]))rankedChildren=NO;
            }
            if(!family||rootCount!=1){plans[window]=@[];continue;}
            sampledAt[window]=@(began);
            NSMutableDictionary *description=[family mutableCopy];description[@"window"]=window;description[@"generation"]=roots[window][@"generation"];description[@"native_bounds"]=roots[window][@"native_bounds"];description[@"members"]=members.copy;descriptions[window]=description.copy;
            if(rankedChildren)[children sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [ranks[b[@"identity"][@"wid"]]compare:ranks[a[@"identity"][@"wid"]]];}];
            plans[window]=children.copy;
            if(rankedChildren&&familyRank(ranks,owners,roots[window][@"identity"]))[completeRoots addObject:window];
        }
        BOOL children=NO;for(NSNumber *window in plans)if([plans[window]count]&&![roots[window][@"capture"]isEqual:@NO]){children=YES;break;}
        void (^reconcile)(SCShareableContent *,NSError *)=^(SCShareableContent *content,NSError *error){dispatch_async(observer,^{
            NSMutableDictionary *windows=[NSMutableDictionary dictionary];for(SCWindow *window in content.windows)windows[@(window.windowID)]=window;
            NSMutableDictionary *checkedMembers=[NSMutableDictionary dictionary];
            if(!error)for(NSNumber *logical in roots)if(![roots[logical][@"capture"]isEqual:@NO]){
                NSMutableDictionary *checked=[NSMutableDictionary dictionary];
                for(NSDictionary *plan in plans[logical]){
                    CFTimeInterval began=CACurrentMediaTime();
                    NSDictionary *identity=plan[@"identity"];CGRect bounds=DWRectFromJSON(plan[@"native_bounds"]);SCWindow *window=windows[identity[@"wid"]];
                    CGRect rootNow=CGRectZero,memberNow=CGRectZero;
                    if(window&&window.owningApplication.processID==[identity[@"pid"]intValue]&&familySize(bounds)
                       &&DWNativeWindowBelongsToRoot(identity,roots[logical][@"identity"])
                       &&DWNativeBounds([roots[logical][@"identity"][@"wid"]unsignedIntValue],&rootNow)
                       &&DWNativeBounds([identity[@"wid"]unsignedIntValue],&memberNow)
                       &&CGRectEqualToRect(rootNow,DWRectFromJSON(roots[logical][@"native_bounds"]))&&CGRectEqualToRect(memberNow,bounds))checked[identity[@"wid"]]=@(began);
                }
                checkedMembers[logical]=checked.copy;
            }
            // Root-only runs cannot change controller order. Only a cohort
            // containing captured children needs other roots' ranks to place
            // those children across families. Validate that geometry evidence
            // on the observer too; it never grants input or native authority.
            NSMutableDictionary *checkedRoots=[NSMutableDictionary dictionary];
            if(children&&!error)for(NSNumber *logical in completeRoots){
                CFTimeInterval began=CACurrentMediaTime();CGRect rootNow=CGRectZero;
                if(DWNativeWindowBelongsToRoot(roots[logical][@"identity"],roots[logical][@"identity"])
                   &&DWNativeBounds([roots[logical][@"identity"][@"wid"]unsignedIntValue],&rootNow)
                   &&CGRectEqualToRect(rootNow,DWRectFromJSON(roots[logical][@"native_bounds"])))checkedRoots[logical]=@(began);
            }
            dispatch_async(dispatch_get_main_queue(),^{
            DWNativeReplicaFamilies *owner=weak;if(!owner)return;owner.requestPending=NO;if(!owner.reading||owner.epoch!=epoch||owner.requestSequence!=sequence||!familyCohortMatches(owner.roots,roots))return;owner.reading=NO;
            [owner beginChanges];
            NSMutableDictionary *nextMembers=[NSMutableDictionary dictionary],*nextOrdering=[NSMutableDictionary dictionary];
            NSUInteger starting=0;
            for(NSNumber *logical in [owner admissionRootOrder]){NSMutableArray *installed=[NSMutableArray array];NSArray<DWReplicaMember *> *old=owner.members[logical]?:@[];
                NSDictionary *currentRoot=owner.roots[logical];NSInteger rate=owner.rate;
                // Only a fresh, complete native membership read may forget an
                // absent failed binding. An error/stalled request cannot turn
                // every old failure back into an unthrottled initial attempt.
                if(owner.epoch==epoch&&descriptions[logical])[owner acceptRecoveryCohort:plans[logical] root:roots[logical] sampledAt:sampledAt[logical]];
                NSArray<NSDictionary *> *wanted=error?@[]:[owner capturePlans:plans[logical] root:currentRoot];
                for(NSDictionary *plan in [owner admissionPlans:wanted root:roots[logical]]){
                    NSDictionary *identity=plan[@"identity"];CGRect bounds=DWRectFromJSON(plan[@"native_bounds"]);SCWindow *window=windows[identity[@"wid"]];
                    // The observer proved this exact child/root binding. Its
                    // deadline includes every native read and queue wait; a
                    // stalled result never becomes fresh at completion. This
                    // admits only stream setup/reuse: frames and input retain
                    // their own fresh native validation before publication.
                    NSNumber *began=checkedMembers[logical][identity[@"wid"]];
                    if(!began||!familyProcessMatches(identity))continue;
                    CFTimeInterval age=CACurrentMediaTime()-began.doubleValue;
                    if(age<0||age>.1)continue;
                    double density=[currentRoot[@"density"]doubleValue];if(!isfinite(density)||density<=0)density=2;
                    density=MIN(2,MAX(1./32,density));DWReplicaMember *member=nil;
                    for(DWReplicaMember *candidate in old)if(atomic_load(&candidate->alive)&&[candidate.identity isEqual:identity]&&CGRectEqualToRect(candidate.bounds,bounds)&&familyBinding(candidate.root,roots[logical])){member=candidate;break;}
                    if(!member){DWReplicaRecovery *recovery=[owner admitRecovery:identity root:roots[logical] bounds:bounds starting:&starting];if(!recovery)continue;
                        member=[DWReplicaMember new];member.owner=owner;member.root=currentRoot;member.identity=identity;member.bounds=bounds;member.rootBounds=DWRectFromJSON(currentRoot[@"native_bounds"]);member.density=density;member.rate=rate;member.lastVisible=CACurrentMediaTime();member.frameTime=mach_absolute_time();recovery.attempt=member;
                        [owner.coldAttempts addObject:member];
                        familyTrace(member,"create","none",0);
                        DWCanvasAttachment *image=[DWCanvasAttachment new];image.key=[NSString stringWithFormat:@"%@:%@:%@:%@",identity[@"pid"],identity[@"birth_sec"],identity[@"birth_usec"],identity[@"wid"]];
                        image.unitRect=CGRectMake((bounds.origin.x-member.rootBounds.origin.x)/member.rootBounds.size.width,(bounds.origin.y-member.rootBounds.origin.y)/member.rootBounds.size.height,bounds.size.width/member.rootBounds.size.width,bounds.size.height/member.rootBounds.size.height);member.image=image;
                        SCStreamConfiguration *config=familyConfiguration(bounds,density,rate);
                        member.samples=familyQueue("org.infinify.native-family-frames");
                        member.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:window] configuration:config delegate:member];
                        NSError *failure=nil;
                        if(![member.stream addStreamOutput:member type:SCStreamOutputTypeScreen sampleHandlerQueue:member.samples error:&failure]){[member fail:failure.localizedDescription?:@"Family capture output unavailable" code:"output_unavailable" error:failure.code];continue;}
                        [member start];
                    }else if(member.started&&!member.updating&&(member.density!=density||member.rate!=rate)){
                        member.updating=YES;member.density=density;member.rate=rate;NSUInteger revision=++member.configuration;DWReplicaMember *updated=member;
                        familyTrace(member,"configure","none",0);
                        [member.stream updateConfiguration:familyConfiguration(bounds,density,rate) completionHandler:^(NSError *failure){dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&updated->alive)||updated.configuration!=revision)return;updated.updating=NO;if(failure)[updated fail:failure.localizedDescription code:"configuration_failed" error:failure.code];});}];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(atomic_load(&updated->alive)&&updated.updating&&updated.configuration==revision)[updated fail:@"Family capture configuration timed out" code:"configuration_timeout" error:0];});
                    }
                    [installed addObject:member];
                }
                // Scheduling priority is not z-order. Publish the exact native
                // observation's sequence (or its existing fallback sequence).
                if(installed.count>1){NSMutableDictionary *byID=[NSMutableDictionary dictionary];for(DWReplicaMember *member in installed)byID[member.identity[@"wid"]]=member;
                    [installed removeAllObjects];for(NSDictionary *plan in wanted){DWReplicaMember *member=byID[plan[@"identity"][@"wid"]];if(member)[installed addObject:member];}}
                for(DWReplicaMember *member in old)if(![installed containsObject:member])[member retire];
                nextMembers[logical]=installed.copy;
                if(![old isEqual:installed]){[owner.drawableAttachments removeObjectForKey:logical];[owner markOrderingChanged];[owner changedWindow:logical];}
                BOOL complete=children&&!error&&[completeRoots containsObject:logical]&&installed.count==wanted.count;
                if(complete&&!installed.count){NSNumber *began=checkedRoots[logical];
                    // Measure from the first validation read, including time
                    // spent waiting on WindowServer and on this queue. A late
                    // result falls back for the whole run; it is not made fresh
                    // by its completion. Birth is still checked at publication.
                    complete=began&&familyProcessMatches(roots[logical][@"identity"]);
                    CFTimeInterval age=began?CACurrentMediaTime()-began.doubleValue:INFINITY;
                    complete=complete&&age>=0&&age<=.1;
                }
                if(complete){NSMutableDictionary *children=[NSMutableDictionary dictionary];
                    for(DWReplicaMember *member in installed){NSString *key=member.image.key;NSNumber *rank=familyRank(ranks,owners,member.identity);
                        if(!key||!rank||children[key]){complete=NO;break;}children[key]=rank;
                    }
                    if(complete){DWReplicaOrder *order=[DWReplicaOrder new];order.root=roots[logical];order.rank=familyRank(ranks,owners,roots[logical][@"identity"]);order.members=installed.copy;order.ranks=children.copy;nextOrdering[logical]=order;}
                }
            }
            // A synchronous capture setup failure invalidates this observation
            // too. No callback sees a partially installed family/order cohort.
            NSDictionary *accepted=owner.epoch==epoch?nextOrdering.copy:@{};
            familyNormalizeOrder(accepted);
            if(!familySameOrder(owner.ordering,accepted))[owner markOrderingChanged];
            owner.members=nextMembers;owner.ordering=accepted;
            owner.orderingEpoch=owner.epoch;owner.orderingObservation=accepted.count?sequence:0;
            [owner replaceDescriptions:owner.epoch==epoch?descriptions.copy:@{}];
            [owner endChanges];
        });});};
        // A fresh empty family needs only retirement of prior children. Do not
        // ask ScreenCaptureKit to enumerate the desktop when no filter can be
        // created, but retain the same epoch/deadline/reconciliation path.
        if(children)[SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:reconcile];
        else reconcile(nil,nil);
    });
}
- (void)dealloc {for(NSArray<DWReplicaMember *> *family in _members.allValues)for(DWReplicaMember *member in family)[member retire];}
@end
