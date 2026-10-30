// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation. Private ABI declarations cross-checked against
// yabai (MIT), https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/osax/payload.m; its notice is native/app/Resources/YABAI-NOTICE.txt.
// The arrival veil (v2Veil below) adapts an idea and a technique of Sunlight,
// https://github.com/spacefarm-digital/sunlight commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm): that a window an
// application opens must not be seen at its native place before the canvas has placed it
// (LiveWindows/README.md:129 and LiveWindows/osax/sunbeam.h:40-51, which keep the canvas and its
// windows one window level up), and the window server's own announcement of it, SkyLight
// connection notification 1325 with the Space id (u64) then the window id (u32) as payload,
// registered with SLSRegisterConnectionNotifyProc (Sources/Canvas/RealWindows/WindowServerEvents.swift:4-15,
// 36-55 and 73-85). The level lift is not taken: here the window is held at alpha 0 instead.
// Private ABI declarations below are cross-checked against yabai (MIT),
// https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd; its notice is native/app/Resources/YABAI-NOTICE.txt.
// Restoration: released originals pruned only on proof the window is gone, the retry schedule, and v2Restore, which puts back what
// was captured at first touch behind fresh identity fences.
// Moved verbatim from native/dock-helper/Payload/DWPayload.m (37b27b1), lines 644-789. #imported by DWDockPayload.m in a fixed order; never compiled alone.

// Live released originals remain obligations across connection death. Make room only by proving
// a recorded instance is gone, never age. Returns whether the released table changed.
static BOOL v2PruneReleased(void) {
    BOOL changed=NO;
    NSDictionary *owners=v2RestoreOwners();
    for(NSNumber *releasedKey in v2Released.allKeys){DW2Entry *old=v2Released[releasedKey];
        if(v2RestoreIdentityWithOwners(&old->who,old->owner,owners)==DW2_INSTANCE_GONE){[v2Released removeObjectForKey:releasedKey];changed=YES;}}
    return changed;
}
static void v2ScheduleRetry(void) {
    if(v2RetryScheduled)return;
    v2RetryScheduled=YES;
    unsigned delay=v2RetryDelayMS;
    v2RetryDelayMS=MIN(v2RetryDelayMS*2,2000U);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay*NSEC_PER_MSEC),v2q,^{
        v2RetryScheduled=NO;
        if(atomic_load(&v2Restoring) || v2JournalStale)v2Restore(@"automatic retry",YES,nil,NULL);
    });
}
// Puts back what was captured at first touch, for every window (or, on a retry, for
// those still pending). Each window is resolved again: one that is no longer the
// recorded window of the recorded process instance is left alone and dropped; one
// whose restore cannot be confirmed stays, blocks nothing else and is retried.
static void v2Restore(NSString *reason,BOOL retry,NSMutableData *results,struct dw2_restore_reply *summary) {
    NSMutableArray *report=[NSMutableArray array];
    uint32_t count=0,pending=0;
    // Share the initial enumeration across this bounded table pass. Successful
    // restoration still takes a fresh enumeration at its final identity fence.
    NSDictionary *owners=v2Table.count ? v2RestoreOwners() : nil;
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(retry && e->state!=DW2_RESTORING)continue;
        struct dw2_restore_result r={.id=e->who,.outcome=DW2_PENDING,.set_status=-1};
        BOOL transformSet=NO,transformRead=NO,transformMatches=NO,alphaChecked=NO,alphaCurrent=NO,alphaSet=NO,alphaRead=NO,rebased=NO;
        int transformSetStatus=0,transformGetStatus=0,alphaSetStatus=0,alphaGetStatus=0,finalIdentity=-1,originStatus=0;
        CGAffineTransform actual=CGAffineTransformIdentity,target=e->transform;float alpha=-1;CGRect releasedBounds=CGRectZero,originBounds=CGRectZero;
        int observed=v2RestoreIdentityWithOwners(&e->who,e->owner,owners);
        BOOL admitted=observed==DW2_INSTANCE_CURRENT&&(!e->reattaching||v2ReattachCurrent(e));
        if(e->originalSpace&&!admitted){e->restoreSpaceQuiet=0;e->restoreSpaceSample=NO;}
        if(observed==DW2_INSTANCE_GONE){r.outcome=DW2_GONE;r.set_status=0;}
        else if(admitted) {
            BOOL spaceRestored=v2RestoreSpace(e);
            v2SpaceRestoreSample(e);
            // Space calls and their readbacks can outlive the window as well.
            if(e->originalSpace&&!v2EntryCurrent(e)){e->restoreSpaceQuiet=0;e->restoreSpaceSample=NO;e->state=DW2_RESTORING;pending++;count++;[results appendBytes:&r length:sizeof(r)];
                [report addObject:@{@"pid":@(r.id.pid),@"birth_sec":@(r.id.birth_sec),@"birth_usec":@(r.id.birth_usec),@"wid":@(r.id.wid),@"outcome":@"pending",@"set_status":@(-1)}];continue;}
            BOOL ok;
            if(e->veilBare) {
                // Nothing but alpha was changed: the transform in force is the window's own, and moves with it. Adopt it as the original.
                r.set_status=0;transformRead=YES;
                ok=(transformGetStatus=getTransform(mainConnection(),e->who.wid,&actual))==0 && finiteMatrix(actual);
                if(ok){e->transform=actual;transformMatches=YES;}
            } else {
                // The original is re-based on the native origin read now (v2RestoreTransform), and that origin must still be the
                // window's when the write has been read back below; a window that moved meanwhile is pending and is done again.
                // Without a readable origin the captured original is written as the best that can be done and the window stays
                // pending, so a later pass writes the re-based one.
                originStatus=getBounds(mainConnection(),e->who.wid,&originBounds);
                rebased=!originStatus&&v2FiniteRect(originBounds);
                if(rebased)target=v2RestoreTransform(e->transform,e->bounds.origin,originBounds.origin);
                transformSet=YES;r.set_status=transformSetStatus=setTransform(mainConnection(),e->who.wid,target);
                ok=rebased && r.set_status==0 && (transformRead=YES,transformGetStatus=getTransform(mainConnection(),e->who.wid,&actual))==0
                    && (transformMatches=v2SameTransform(actual,target));
            }
            if(e->alphaTouched) {
                alphaChecked=YES;alphaCurrent=e->reattaching ? v2ReattachCurrent(e) : v2EntryCurrent(e);
                // The veil's alpha is put back only while it still reads 0: a window the application has since taken over, or that
                // a frame lifted without asking for an alpha of its own, is left as it is.
                float held=-1;BOOL owed=!(e->veilAlpha && alphaCurrent && !getAlpha(mainConnection(),e->who.wid,&held) && held!=0);
                if(owed) {
                    int status=alphaCurrent ? (alphaSet=YES,alphaSetStatus=setAlpha(mainConnection(),e->who.wid,e->alpha)) : -1;
                    if(status && !r.set_status)r.set_status=status;
                    if(status || (alphaRead=YES,alphaGetStatus=getAlpha(mainConnection(),e->who.wid,&alpha)) || alpha!=e->alpha)ok=NO;
                }
            }
            if(e->sublevelTouched){
                int sublevelStatus=0;
                if(!v2ApplySublevel(e,e->originalSublevel,&sublevelStatus))ok=NO;
                if(sublevelStatus&&!r.set_status)r.set_status=sublevelStatus;
            }
            // The retained release describes the geometry at restoration, not
            // the possibly resized geometry from first admission.
            ok=ok && spaceRestored && (!e->originalSpace||v2WindowSpace(e->who.wid)==e->originalSpace)
                && !getBounds(mainConnection(),e->who.wid,&releasedBounds) && v2FiniteRect(releasedBounds)
                && (!e->reattaching || CGRectEqualToRect(releasedBounds,e->bounds))
                && (!rebased || CGPointEqualToPoint(releasedBounds.origin,originBounds.origin));
            ok=ok && (finalIdentity=v2RestoreIdentity(&e->who,e->owner))==DW2_INSTANCE_CURRENT;
            r.outcome=v2SpaceRestoreSettled(e,releasedBounds,ok) ? DW2_RESTORED : DW2_PENDING;
        }
        if(r.outcome==DW2_PENDING){e->state=DW2_RESTORING;pending++;}
        else {
            // The retained record says what is now on the window: the transform written, at the bounds read after it, so a later
            // re-base starts from a pair that belongs together. A veil-only release adopted the transform in force above.
            if(r.outcome==DW2_RESTORED){if(rebased)e->transform=target;e->bounds=releasedBounds;e->reattaching=NO;e->appliedTransformKnown=NO;
                // A veil's conditional alpha was settled by this release; its mark is not an original to guard later.
                if(e->veilAlpha)e->alphaTouched=NO;
                e->veiled=e->veilBare=e->veilAlpha=e->arrival=NO;v2Released[wid]=e;}
            [v2Table removeObjectForKey:wid];
        }
        count++;
        [results appendBytes:&r length:sizeof(r)];
        NSMutableDictionary *receipt=[@{@"pid":@(r.id.pid),@"birth_sec":@(r.id.birth_sec),@"birth_usec":@(r.id.birth_usec),@"wid":@(r.id.wid),
            @"outcome":r.outcome==DW2_RESTORED ? @"restored" : r.outcome==DW2_GONE ? @"gone" : @"pending",@"set_status":@(r.set_status)} mutableCopy];
        if(r.outcome==DW2_PENDING) {
            // Record only calls already made above, including short-circuited
            // checks. Null statuses mean not called, never success. This is
            // explanatory journal/log metadata, not protocol or restore state.
            receipt[@"diagnostic"]=@{@"initial_identity":v2RestoreIdentityName(observed),
                @"transform_set_status":transformSet ? @(transformSetStatus) : (id)NSNull.null,
                @"transform_get_status":transformRead ? @(transformGetStatus) : (id)NSNull.null,
                @"saved_transform":matrix(e->transform),
                @"origin_status":rebased||originStatus ? @(originStatus) : (id)NSNull.null,
                @"native_origin":rebased ? @[@(originBounds.origin.x),@(originBounds.origin.y)] : (id)NSNull.null,
                @"captured_origin":@[@(e->bounds.origin.x),@(e->bounds.origin.y)],
                @"target_transform":rebased ? matrix(target) : (id)NSNull.null,
                @"actual_transform":transformRead && !transformGetStatus && finiteMatrix(actual) ? matrix(actual) : (id)NSNull.null,
                @"transform_matches":transformRead && !transformGetStatus ? @(transformMatches) : (id)NSNull.null,
                @"alpha":e->alphaTouched ? @{@"identity_current":alphaChecked ? @(alphaCurrent) : (id)NSNull.null,
                    @"set_status":alphaSet ? @(alphaSetStatus) : (id)NSNull.null,
                    @"get_status":alphaRead ? @(alphaGetStatus) : (id)NSNull.null,
                    @"saved":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,
                    @"actual":alphaRead && !alphaGetStatus && isfinite(alpha) ? @(alpha) : (id)NSNull.null} : (id)NSNull.null,
                @"final_identity":finalIdentity>=0 ? v2RestoreIdentityName(finalIdentity) : (id)NSNull.null};
            if(e->originalSpace){NSMutableDictionary *diagnostic=[receipt[@"diagnostic"]mutableCopy];
                diagnostic[@"space"]=@{@"original":@(e->originalSpace),@"pending_target":@(e->pendingSpace),
                    @"settle_started_ms":@(e->restoreSpaceStarted),@"quiet_since_ms":@(e->restoreSpaceQuiet),
                    @"sample_current":@(e->restoreSpaceSample)};receipt[@"diagnostic"]=diagnostic;}
        }
        [report addObject:receipt];
    }
    BOOL saved=YES;
    if(count || v2JournalStale) {
        if(count)v2LastRestore=@{@"reason":reason,@"results":report};
        saved=v2Persist();v2JournalStale=!saved;
    }
    v2Count();
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->originalSpace&&e->restoreSpaceSample){v2RetryDelayMS=250;break;}
    if(atomic_load(&v2Restoring) || v2JournalStale)v2ScheduleRetry();
    else v2RetryDelayMS=250;
    if(summary)*summary=(struct dw2_restore_reply){.count=count,.pending=pending,.journal_persisted=saved};
    if(!summary && count) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"reason":reason,@"results":report,@"journal_persisted":@(saved)} options:0 error:NULL];
        fprintf(stderr,"V2_RESTORE %s\n",data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "serialization failed");
    }
}

