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
// Frames: the alpha a frame leaves a window at, and v2ApplyWithSpaces and v2Apply, which capture and journal every new window before
// any change and apply each record behind identity fences.
// Moved verbatim from native/dock-helper/Payload/DWPayload.m (37b27b1), lines 475-486, 790-978. #imported by DWDockPayload.m in a fixed order; never compiled alone.

// The alpha a frame leaves a window at: the record's own or, for a veiled window whose record carries none, its original.
static BOOL v2FrameAlpha(DW2Entry *e,const struct dw2_record *r,float *alpha) {
    if(r->flags&DW2_RECORD_HAS_ALPHA){*alpha=r->alpha;return YES;}
    if(e->veiled){
        // No alpha of its own to ask for: lift the veil, unless the application has taken the alpha over since (it no longer reads 0).
        float held=-1;
        if(!getAlpha(mainConnection(),e->who.wid,&held) && held!=0){e->veiled=NO;return NO;}
        *alpha=e->alpha;return YES;
    }
    return NO;
}

// One frame. A record that cannot be applied fails alone. Windows not yet in the
// table are captured first and journalled together, once, before any of them is
// changed; a frame of known windows writes nothing to disk.
static void v2ApplyWithSpaces(const struct dw2_record *records,const uint64_t *targets,uint32_t count,uint8_t *status) {
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:count];
    NSMutableDictionary *replacedReleases=[NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *releasing=[NSMutableSet set];
    NSMutableData *sourceData=[NSMutableData dataWithLength:count*sizeof(uint64_t)];uint64_t *sources=sourceData.mutableBytes;
    for(uint32_t i=0;i<count;i++)if(records[i].flags==DW2_RECORD_RESTORE)[releasing addObject:@(records[i].id.wid)];
    NSMutableSet *seen=[NSMutableSet set],*duplicates=[NSMutableSet set];
    if(targets)for(uint32_t i=0;i<count;i++){NSNumber *wid=@(records[i].id.wid);if([seen containsObject:wid])[duplicates addObject:wid];[seen addObject:wid];}
    // Finish releases and confirmations of prior requests before staging any
    // new Space intent. Their journal writes must never commit another record's
    // not-yet-admitted pending target halfway through this frame.
    NSMutableData *priorData=[NSMutableData dataWithLength:count];uint8_t *prior=priorData.mutableBytes;
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];
        if(r->flags!=DW2_RECORD_RESTORE||!v2InScope(&r->id)||[duplicates containsObject:@(r->id.wid)]||(targets&&targets[i]))continue;
        DW2Entry *entry=v2Table[@(r->id.wid)];
        if(entry&&!v2SameProcess(&entry->who,&r->id)){prior[i]=DW2_IDENTITY;continue;}
        if(entry)entry->state=DW2_RESTORING;
        if(entry||v2JournalStale){struct dw2_restore_reply summary={0};v2Restore(@"window released",YES,nil,&summary);
            prior[i]=v2Table[@(r->id.wid)]?DW2_RESTORE_PENDING:summary.journal_persisted?DW2_APPLIED:DW2_JOURNAL;}
    }
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];DW2Entry *entry=v2Table[@(r->id.wid)];
        if(r->flags!=DW2_RECORD_RESTORE&&![releasing containsObject:@(r->id.wid)]&&v2InScope(&r->id)
            &&entry&&entry->pendingSpace&&v2SameProcess(&entry->who,&r->id))prior[i]=v2ConfirmSpace(entry);
    }
    BOOL changed=NO;
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];
        [entries addObject:NSNull.null];
        uint64_t target=targets?targets[i]:0;
        if([duplicates containsObject:@(r->id.wid)]||(target&&r->flags==DW2_RECORD_RESTORE)){status[i]=DW2_MALFORMED;continue;}
        if((r->flags&~(uint32_t)(DW2_RECORD_HAS_ALPHA|DW2_RECORD_RESTORE|DW2_RECORD_PINNED))
            ||((r->flags&DW2_RECORD_RESTORE)&&r->flags!=DW2_RECORD_RESTORE)){status[i]=DW2_MALFORMED;continue;}
        if(!v2InScope(&r->id)){status[i]=DW2_SCOPE;continue;}
        if(r->flags==DW2_RECORD_RESTORE){status[i]=prior[i];continue;}
        if(prior[i]!=DW2_APPLIED){status[i]=prior[i];continue;}
        // A malformed frame cannot both release and transform the same number.
        // Restoration wins, regardless of its position in that frame.
        if([releasing containsObject:@(r->id.wid)]){status[i]=DW2_RESTORE_PENDING;continue;}
        if(!finiteMatrix(CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]))){status[i]=DW2_MATRIX;continue;}
        BOOL wantsAlpha=(r->flags&DW2_RECORD_HAS_ALPHA)!=0,wantsPin=(r->flags&DW2_RECORD_PINNED)!=0;
        if(wantsPin&&!v2SublevelAPI()){status[i]=DW2_SUBLEVEL;continue;}
        if(wantsAlpha && (!setAlpha || !getAlpha || !isfinite(r->alpha) || r->alpha<0 || r->alpha>1)){status[i]=DW2_ALPHA;continue;}
        int owner=0;struct dw2_identity now={0};uid_t uid=0;
        if(!v2Resolve(r->id.wid,&owner,&now,&uid) || !v2SameProcess(&now,&r->id) || uid!=getuid()){status[i]=DW2_IDENTITY;continue;}
        uint64_t source=0;NSString *sourceDisplay=nil;
        if(target&&!v2CanMoveSpace(r->id.wid,target,&source,&sourceDisplay)){status[i]=DW2_SPACE;continue;}
        sources[i]=source;
        NSNumber *key=@(r->id.wid);
        DW2Entry *e=v2Table[key];
        if(e && !v2SameProcess(&e->who,&now)) {
            // The number now names another process's window: the recorded one is gone.
            [v2Table removeObjectForKey:key];e=nil;changed=YES;
        }
        if(e && e->owner!=owner){status[i]=DW2_IDENTITY;continue;}
        if(e && e->state==DW2_RESTORING){status[i]=DW2_RESTORE_PENDING;continue;}
        if(!e) {
            if(!v2Released[key] && v2Table.count+v2Released.count>=DW2_MAX_TABLE && v2PruneReleased())changed=YES;
            if(v2Table.count+v2Released.count-(v2Released[key]?1:0)>=DW2_MAX_TABLE){status[i]=DW2_TABLE_FULL;continue;}
            e=[DW2Entry new];e->who=now;e->owner=owner;e->state=DW2_HELD;e->fresh=YES;
            if(getTransform(mainConnection(),now.wid,&e->transform) || !finiteMatrix(e->transform) || getBounds(mainConnection(),now.wid,&e->bounds) || !v2FiniteRect(e->bounds)){status[i]=DW2_SNAPSHOT;continue;}
            // The original alpha is captured with the window, whether or not this
            // record changes it, so a later record can.
            if(getAlpha && setAlpha) {
                if(getAlpha(mainConnection(),now.wid,&e->alpha) || !isfinite(e->alpha)){status[i]=DW2_SNAPSHOT;continue;}
                e->hasAlpha=YES;
            }
            if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            if(v2Released[key]){replacedReleases[key]=v2Released[key];[v2Released removeObjectForKey:key];}
            v2Table[key]=e;changed=YES;
        }
        if(wantsPin&&!e->sublevelTouched){
            int original=0;
            if(!v2ReadSublevel(e,&original)){
                status[i]=DW2_SNAPSHOT;
                if(e->fresh){[v2Table removeObjectForKey:key];if(replacedReleases[key])v2Released[key]=replacedReleases[key];}
                continue;
            }
            e->originalSublevel=original;e->sublevelTouched=e->sublevelFresh=YES;changed=YES;
        }
        if(target&&source!=target){
            if(!e->originalSpace){e->originalSpace=source;e->originalSpaceDisplay=sourceDisplay;e->spaceFresh=YES;}
            e->pendingSpace=target;e->pendingSpaceFresh=YES;e->pendingSpaceObserved=NO;changed=YES;
        }
        if(wantsAlpha && !e->alphaTouched){e->alphaTouched=e->alphaFresh=YES;changed=YES;}
        if(e->veilBare && !e->veilBareCleared) {
            // The first frame for a window the veil only hid. Its original was read at the announcement and the application may have moved or
            // resized the window since: read it again, and make the record say a transform is now owed, before anything is written.
            CGAffineTransform current=CGAffineTransformIdentity;CGRect bounds=CGRectZero;
            if(getTransform(mainConnection(),now.wid,&current) || !finiteMatrix(current) || getBounds(mainConnection(),now.wid,&bounds) || !v2FiniteRect(bounds)){status[i]=DW2_SNAPSHOT;continue;}
            e->veilPriorTransform=e->transform;e->veilPriorBounds=e->bounds;
            e->transform=current;e->bounds=bounds;e->veilBare=NO;e->veilBareCleared=YES;changed=YES;
        }
        if(wantsAlpha && e->veilAlpha && !e->veilAlphaCleared){e->veilAlpha=NO;e->veilAlphaCleared=YES;changed=YES;}
        e->arrival=NO; // the shell names this window in a frame: its placement is the shell's from here on
        entries[i]=e;status[i]=DW2_APPLIED;
    }
    if(changed) {
        BOOL saved=v2Persist();
        for(uint32_t i=0;i<count;i++) {
            DW2Entry *e=entries[i];
            if((id)e==NSNull.null || !(e->fresh || e->alphaFresh || e->sublevelFresh || e->pendingSpaceFresh || e->veilBareCleared || e->veilAlphaCleared))continue;
            if(!saved) {
                // Nothing of this window (or of its alpha) is changed without a record on disk.
                status[i]=DW2_JOURNAL;entries[i]=NSNull.null;
                if(e->fresh){NSNumber *key=@(e->who.wid);[v2Table removeObjectForKey:key];if(replacedReleases[key])v2Released[key]=replacedReleases[key];}
                else {if(e->alphaFresh)e->alphaTouched=NO;
                    // The window stays veiled, with what the announcement read, and is asked again with the next frame.
                    if(e->veilBareCleared){e->transform=e->veilPriorTransform;e->bounds=e->veilPriorBounds;e->veilBare=YES;}
                    if(e->veilAlphaCleared)e->veilAlpha=YES;
                    if(e->sublevelFresh)e->sublevelTouched=NO;
                    if(e->spaceFresh){e->originalSpace=0;e->originalSpaceDisplay=nil;}
                    if(e->pendingSpaceFresh)e->pendingSpace=0;}
            }
        }
        for(DW2Entry *e in v2Table.objectEnumerator)e->fresh=e->alphaFresh=e->sublevelFresh=e->veilBareCleared=e->veilAlphaCleared=NO;
        if(!saved){v2JournalStale=YES;v2ScheduleRetry();}
    }
    BOOL spaceAttempted=NO;
    for(uint32_t i=0;i<count;i++) {
        DW2Entry *e=entries[i];
        if((id)e==NSNull.null)continue;
        const struct dw2_record *r=&records[i];
        uint64_t target=targets?targets[i]:0;
        if(!v2EntryCurrent(e)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_IDENTITY;continue;}
        if(target){
            uint64_t current=0;
            if(!v2CanMoveSpace(e->who.wid,target,&current,NULL)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_SPACE;continue;}
            if(current!=target){
                if(current!=sources[i]||e->pendingSpace!=target||!v2EntryCurrent(e)){if(!spaceAttempted)v2ForgetUnsentSpace(e);status[i]=DW2_IDENTITY;continue;}
                e->pendingSpaceFresh=e->spaceFresh=NO;spaceAttempted=YES;
                moveWindowsToSpace(mainConnection(),(__bridge CFArrayRef)@[@(e->who.wid)],target);
            } // A preceding root move may have carried this member already.
              // Its observed target confirms, but never erases, its original.
            uint8_t confirmed=v2ConfirmSpace(e);
            if(confirmed!=DW2_APPLIED){status[i]=confirmed;continue;}
            if(v2WindowSpace(e->who.wid)!=target||!v2EntryCurrent(e)){status[i]=DW2_NOT_APPLIED;continue;}
        }
        CGAffineTransform requested=CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]),actual=CGAffineTransformIdentity;
        // Frames stay complete, but moving one window need not rewrite every
        // unchanged neighbour. Only a previously applied request is eligible,
        // and it still needs a fresh native read and the final identity fence.
        BOOL repeated=e->appliedTransformKnown && v2SameTransform(e->appliedTransform,requested);
        BOOL ok=repeated && getTransform(mainConnection(),e->who.wid,&actual)==0 && v2SameTransform(actual,requested);
        e->appliedTransformKnown=NO;
        if(!ok){
            // The extra read above may have outlived this window. Never use its
            // cached request to authorize the corrective write to a replacement.
            if(repeated && !v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            ok=setTransform(mainConnection(),e->who.wid,requested)==0 && getTransform(mainConnection(),e->who.wid,&actual)==0 && v2SameTransform(actual,requested);
        }
        // Alpha is deduplicated only after a fresh native read proves the wanted value; the final identity fence still decides APPLIED.
        BOOL alphaOK=YES;float wantAlpha=0;
        BOOL wantsAlphaWrite=v2FrameAlpha(e,r,&wantAlpha);
        if(wantsAlphaWrite) {
            if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            float actualAlpha=-1;
            BOOL repeatedAlpha=e->appliedAlphaKnown&&e->appliedAlpha==wantAlpha;
            alphaOK=repeatedAlpha&&!getAlpha(mainConnection(),e->who.wid,&actualAlpha)&&actualAlpha==wantAlpha;
            e->appliedAlphaKnown=NO;
            if(!alphaOK) {
                if(repeatedAlpha&&!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
                alphaOK=!setAlpha(mainConnection(),e->who.wid,wantAlpha)
                    &&!getAlpha(mainConnection(),e->who.wid,&actualAlpha)&&actualAlpha==wantAlpha;
            }
            if(!alphaOK)ok=NO;else e->veiled=NO;
        }
        if(e->sublevelTouched) {
            int requestedSublevel=(r->flags&DW2_RECORD_PINNED)?CGWindowLevelForKey(kCGFloatingWindowLevelKey):e->originalSublevel;
            int sublevelStatus=0;if(!v2ApplySublevel(e,requestedSublevel,&sublevelStatus))ok=NO;
        }
        BOOL spaceOK=!target||(v2WindowSpace(e->who.wid)==target&&v2SpaceDisplay(target,YES));
        if(!v2EntryCurrent(e))status[i]=DW2_IDENTITY;
        else if(!spaceOK||!ok)status[i]=DW2_NOT_APPLIED;
        else {
            e->appliedTransform=requested;e->appliedTransformKnown=YES;
            if(wantsAlphaWrite){e->appliedAlpha=wantAlpha;e->appliedAlphaKnown=alphaOK;}
        }
    }
    for(DW2Entry *e in v2Table.objectEnumerator)e->spaceFresh=e->pendingSpaceFresh=NO;
    v2Count();
}

static void v2Apply(const struct dw2_record *records,uint32_t count,uint8_t *status) { v2ApplyWithSpaces(records,NULL,count,status); }

