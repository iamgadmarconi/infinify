// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol v2: many windows per frame, newest frame wins, journalled restoration.
// Original implementation, compiled as part of payload.m (one translation unit, so
// it shares resolved native symbols, scope and runtime directory). Wire format:
// protocol2.h. Semantics: README.md "Protocol v2".
#import <pthread.h>
#import <stdatomic.h>
#import <sys/uio.h>
#import "protocol2.h"

#ifndef DW_V2_MAIN_QUEUE
#define DW_V2_MAIN_QUEUE 0
#endif

// Every v2 native call, the table, the journal, restore and its retries run on v2q.
// Socket reads, parsing, heartbeats and the lease watch run on connection threads
// and never wait on it.
static dispatch_queue_t v2q;
static BOOL v2OnMain;
static uint32_t fixtureWids[16], fixtureCount;

@interface DW2Connection : NSObject { @public int fd; pthread_mutex_t writeLock; atomic_bool closed; int role; uint64_t session, lastFrame; } @end
@implementation DW2Connection
- (void)dealloc { close(fd);pthread_mutex_destroy(&writeLock); }
@end
@interface DW2Entry : NSObject { @public struct dw2_identity who; int owner; CGAffineTransform transform; CGRect bounds; float alpha; BOOL hasAlpha, alphaTouched, fresh, alphaFresh; uint32_t state;
    // A released original imported after its writer died needs the narrower
    // unchanged-geometry/reset guard on every retry, including after a crash.
    BOOL reattaching;
    // Apply-only state. Originals and restoration never depend on this hint.
    CGAffineTransform appliedTransform; BOOL appliedTransformKnown;
} @end
@implementation DW2Entry
@end

// Session, lease and the one-frame slot, shared between connection threads and v2q.
static pthread_mutex_t v2Lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t v2Session, v2Sessions, v2Barrier, v2SlotSeq;
static uint32_t v2SupersededPending;
static uint8_t v2Token[16];
static NSMutableArray<DW2Connection *> *v2Beats;
static NSData *v2Slot;
static DW2Connection *v2SlotOwner;
static _Atomic uint64_t v2Deadline, v2FramesReceived, v2FramesApplied, v2FramesSuperseded, v2JournalWrites;
static _Atomic uint32_t v2Held, v2Restoring;
static _Atomic int v2Connections;
// Touched on v2q only.
static NSMutableDictionary<NSNumber *,DW2Entry *> *v2Table;
static NSMutableDictionary<NSNumber *,DW2Entry *> *v2Released;
static NSDictionary *v2WriterIdentity;
static NSDictionary *v2LastRestore;
static uint64_t v2Generation;
static BOOL v2JournalStale, v2RetryScheduled;
static unsigned v2RetryDelayMS=250;

static uint64_t v2Now(void) { return (uint64_t)nowMS(); }
static BOOL v2SameProcess(const struct dw2_identity *a,const struct dw2_identity *b) { return a->pid==b->pid && a->birth_sec==b->birth_sec && a->birth_usec==b->birth_usec; }
static BOOL v2Listed(const struct dw2_identity *who) {
    for(NSDictionary *entry in allowlist)
        if([entry[@"pid"] longLongValue]==who->pid && [entry[@"birth_sec"] unsignedLongLongValue]==who->birth_sec && [entry[@"birth_usec"] unsignedLongLongValue]==who->birth_usec)return YES;
    return NO;
}
static uint32_t v2Caps(void) { return DW2_CAP_RESTORE_WINDOW|DW2_CAP_ENROLLMENT|DW2_CAP_INSPECT|(setAlpha&&getAlpha?DW2_CAP_ALPHA:0)|(fixtureOnly&&fixtureNativeFamilies?DW2_CAP_FIXTURE_FAMILY:0); }
// Scope, allowlist first: decided from the record alone, before
// any window-server lookup, and again for every record of every frame and restore.
static BOOL v2InScope(const struct dw2_identity *who) {
    if(allowlist && !v2Listed(who))return NO;
    if(!fixtureOnly)return YES;
    if(who->pid!=getpid())return NO;
    for(uint32_t i=0;i<fixtureCount;i++)if(fixtureWids[i]==who->wid)return YES;
    return NO;
}
// A missing enumeration is uncertainty, not evidence a recorded window is gone.
// A successful list can prove absence or a replacement owner PID.
enum { DW2_WINDOW_UNKNOWN=-1, DW2_WINDOW_ABSENT=0, DW2_WINDOW_PRESENT=1 };
static int v2ListedPID(uint32_t wid,int *pid) {
    *pid=0;
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    if(!rows)return DW2_WINDOW_UNKNOWN;
    int result=DW2_WINDOW_ABSENT;
    for(id row in (__bridge NSArray *)rows) {
        id windowNumber=[row isKindOfClass:NSDictionary.class] ? row[(id)kCGWindowNumber] : nil;
        if(!isNumber(windowNumber) || CFNumberIsFloatType((__bridge CFNumberRef)windowNumber)
            || [windowNumber longLongValue]<=0 || [windowNumber unsignedLongLongValue]>UINT32_MAX){result=DW2_WINDOW_UNKNOWN;break;}
        if([windowNumber unsignedLongLongValue]!=wid)continue;
        id ownerPID=row[(id)kCGWindowOwnerPID];
        if(!isNumber(ownerPID) || CFNumberIsFloatType((__bridge CFNumberRef)ownerPID)
            || [ownerPID longLongValue]<=0 || [ownerPID longLongValue]>INT_MAX){result=DW2_WINDOW_UNKNOWN;break;}
        *pid=[ownerPID intValue];result=DW2_WINDOW_PRESENT;break;
    }
    CFRelease(rows);
    return result;
}
// The window's current owner connection, process instance and user, from the window
// server and the kernel. Nothing a client sent is trusted here.
static BOOL v2Resolve(uint32_t wid,int *owner,struct dw2_identity *who,uid_t *uid) {
    int pid=0;
    if(getOwner(mainConnection(),wid,owner) || *owner<=0)return NO;
    if((!connectionPID || connectionPID(*owner,&pid) || pid<=0) && v2ListedPID(wid,&pid)!=DW2_WINDOW_PRESENT)return NO;
    struct proc_bsdinfo b={0};
    if(pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b))return NO;
    *who=(struct dw2_identity){.pid=pid,.wid=wid,.birth_sec=b.pbi_start_tvsec,.birth_usec=b.pbi_start_tvusec};
    *uid=b.pbi_uid;
    return YES;
}
// Journal I/O and preceding records can outlive a window. Recheck the exact
// admission at each mutation boundary; the saved entry is restoration state,
// not continuing authority over a reused window number.
static BOOL v2EntryCurrent(DW2Entry *entry) {
    int owner=0;struct dw2_identity current={0};uid_t uid=0;
    return v2InScope(&entry->who) && v2Resolve(entry->who.wid,&owner,&current,&uid)
        && owner==entry->owner && v2SameProcess(&current,&entry->who) && uid==getuid();
}
// Restore may discard an original only after a query positively establishes that
// its window instance is absent/reused. Transient lookup failures or a changed
// admission scope retain the obligation for a later authorized retry.
enum { DW2_INSTANCE_CURRENT, DW2_INSTANCE_GONE, DW2_INSTANCE_UNCERTAIN };
static NSString *v2RestoreIdentityName(int value) {
    return value==DW2_INSTANCE_CURRENT ? @"current" : value==DW2_INSTANCE_GONE ? @"gone" : @"uncertain";
}
static int v2RestoreIdentity(const struct dw2_identity *recorded,int recordedOwner) {
    int owner=0;struct dw2_identity current={0};uid_t uid=0;
    if(v2Resolve(recorded->wid,&owner,&current,&uid)) {
        if(!v2SameProcess(&current,recorded) || owner!=recordedOwner)return DW2_INSTANCE_GONE;
        return uid==getuid() && v2InScope(recorded) ? DW2_INSTANCE_CURRENT : DW2_INSTANCE_UNCERTAIN;
    }
    int pid=0;
    int listed=v2ListedPID(recorded->wid,&pid);
    if(listed==DW2_WINDOW_ABSENT)return DW2_INSTANCE_GONE;
    if(listed!=DW2_WINDOW_PRESENT)return DW2_INSTANCE_UNCERTAIN;
    if(pid!=recorded->pid)return DW2_INSTANCE_GONE;
    struct proc_bsdinfo process={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process))return DW2_INSTANCE_UNCERTAIN;
    return process.pbi_start_tvsec!=recorded->birth_sec || process.pbi_start_tvusec!=recorded->birth_usec ? DW2_INSTANCE_GONE : DW2_INSTANCE_UNCERTAIN;
}
// The window server keeps transforms as 32-bit floats, so a request is applied when
// it reads back equal after the same rounding.
static BOOL v2SameTransform(CGAffineTransform a,CGAffineTransform b) {
    return (float)a.a==(float)b.a && (float)a.b==(float)b.b && (float)a.c==(float)b.c && (float)a.d==(float)b.d && (float)a.tx==(float)b.tx && (float)a.ty==(float)b.ty;
}
static BOOL v2FiniteRect(CGRect r);
static BOOL v2ReattachCurrent(DW2Entry *e) {
    CGRect bounds=CGRectZero;CGAffineTransform actual=CGAffineTransformIdentity;float alpha=-1;
    return v2EntryCurrent(e) && !getBounds(mainConnection(),e->who.wid,&bounds) && v2FiniteRect(bounds)
        && CGRectEqualToRect(bounds,e->bounds) && !getTransform(mainConnection(),e->who.wid,&actual) && finiteMatrix(actual)
        && (v2SameTransform(actual,e->transform) || v2SameTransform(actual,CGAffineTransformIdentity))
        && (!e->alphaTouched || (getAlpha && !getAlpha(mainConnection(),e->who.wid,&alpha) && alpha==e->alpha)) && v2EntryCurrent(e);
}
static void v2Count(void) {
    uint32_t restoring=0;
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->state==DW2_RESTORING)restoring++;
    atomic_store(&v2Held,(uint32_t)v2Table.count-restoring);atomic_store(&v2Restoring,restoring);
}

// Durable no-follow staging and rename; original values survive every frame.
static NSDictionary *v2JournalEntry(DW2Entry *e,NSString *state) {
    return @{@"pid":@(e->who.pid),@"birth_sec":@(e->who.birth_sec),@"birth_usec":@(e->who.birth_usec),@"wid":@(e->who.wid),@"owner":@(e->owner),
        @"transform":matrix(e->transform),@"alpha":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,@"alpha_touched":@(e->alphaTouched),
        @"bounds":@[@(e->bounds.origin.x),@(e->bounds.origin.y),@(e->bounds.size.width),@(e->bounds.size.height)],@"state":state};
}
static BOOL v2Persist(void) {
    if(!v2WriterIdentity || v2Table.count+v2Released.count>DW2_MAX_TABLE)return NO;
    NSMutableArray *windows=[NSMutableArray array],*released=[NSMutableArray array];
    BOOL restoring=NO;
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(e->state==DW2_RESTORING)restoring=YES;
        [windows addObject:v2JournalEntry(e,e->reattaching ? @"reattaching" : e->state==DW2_HELD ? @"held" : @"restoring")];
    }
    for(NSNumber *wid in [v2Released.allKeys sortedArrayUsingSelector:@selector(compare:)])[released addObject:v2JournalEntry(v2Released[wid],@"released")];
    NSMutableDictionary *journal=[v2WriterIdentity mutableCopy];
    [journal addEntriesFromDictionary:@{@"v":@3,@"generation":@(v2Generation+1),@"state":!windows.count ? @"empty" : restoring ? @"restoring" : @"holding",
        @"windows":windows,@"released_windows":released,@"last_restore":v2LastRestore ?: (id)NSNull.null}];
    NSData *data=[NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingPrettyPrinted error:NULL];
    if(!data)return NO;
    int fd=openat(directoryFD,"v2-journal.next",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return NO;
    BOOL ok=writeAll(fd,data.bytes,data.length) && fsync(fd)==0;
    if(close(fd))ok=NO;
    if(ok)ok=renameat(directoryFD,"v2-journal.next",directoryFD,"v2-journal.json")==0 && fsync(directoryFD)==0;
    if(!ok){unlinkat(directoryFD,"v2-journal.next",0);return NO;}
    v2Generation++;atomic_fetch_add(&v2JournalWrites,1);
    return YES;
}

static void v2Restore(NSString *reason,BOOL retry,NSMutableData *results,struct dw2_restore_reply *summary);
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
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(retry && e->state!=DW2_RESTORING)continue;
        struct dw2_restore_result r={.id=e->who,.outcome=DW2_PENDING,.set_status=-1};
        BOOL transformSet=NO,transformRead=NO,transformMatches=NO,alphaChecked=NO,alphaCurrent=NO,alphaSet=NO,alphaRead=NO;
        int transformSetStatus=0,transformGetStatus=0,alphaSetStatus=0,alphaGetStatus=0,finalIdentity=-1;
        CGAffineTransform actual=CGAffineTransformIdentity;float alpha=-1;CGRect releasedBounds=CGRectZero;
        int observed=v2RestoreIdentity(&e->who,e->owner);
        if(observed==DW2_INSTANCE_GONE){r.outcome=DW2_GONE;r.set_status=0;}
        else if(observed==DW2_INSTANCE_CURRENT && (!e->reattaching || v2ReattachCurrent(e))) {
            transformSet=YES;r.set_status=transformSetStatus=setTransform(mainConnection(),e->who.wid,e->transform);
            BOOL ok=r.set_status==0 && (transformRead=YES,transformGetStatus=getTransform(mainConnection(),e->who.wid,&actual))==0
                && (transformMatches=v2SameTransform(actual,e->transform));
            if(e->alphaTouched) {
                alphaChecked=YES;alphaCurrent=e->reattaching ? v2ReattachCurrent(e) : v2EntryCurrent(e);
                int status=alphaCurrent ? (alphaSet=YES,alphaSetStatus=setAlpha(mainConnection(),e->who.wid,e->alpha)) : -1;
                if(status && !r.set_status)r.set_status=status;
                if(status || (alphaRead=YES,alphaGetStatus=getAlpha(mainConnection(),e->who.wid,&alpha)) || alpha!=e->alpha)ok=NO;
            }
            // The retained release describes the geometry at restoration, not
            // the possibly resized geometry from first admission.
            ok=ok && !getBounds(mainConnection(),e->who.wid,&releasedBounds) && v2FiniteRect(releasedBounds)
                && (!e->reattaching || CGRectEqualToRect(releasedBounds,e->bounds));
            r.outcome=ok && (finalIdentity=v2RestoreIdentity(&e->who,e->owner))==DW2_INSTANCE_CURRENT ? DW2_RESTORED : DW2_PENDING;
        }
        if(r.outcome==DW2_PENDING){e->state=DW2_RESTORING;pending++;}
        else {
            if(r.outcome==DW2_RESTORED){e->bounds=releasedBounds;e->reattaching=NO;e->appliedTransformKnown=NO;v2Released[wid]=e;}
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
                @"actual_transform":transformRead && !transformGetStatus && finiteMatrix(actual) ? matrix(actual) : (id)NSNull.null,
                @"transform_matches":transformRead && !transformGetStatus ? @(transformMatches) : (id)NSNull.null,
                @"alpha":e->alphaTouched ? @{@"identity_current":alphaChecked ? @(alphaCurrent) : (id)NSNull.null,
                    @"set_status":alphaSet ? @(alphaSetStatus) : (id)NSNull.null,
                    @"get_status":alphaRead ? @(alphaGetStatus) : (id)NSNull.null,
                    @"saved":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,
                    @"actual":alphaRead && !alphaGetStatus && isfinite(alpha) ? @(alpha) : (id)NSNull.null} : (id)NSNull.null,
                @"final_identity":finalIdentity>=0 ? v2RestoreIdentityName(finalIdentity) : (id)NSNull.null};
        }
        [report addObject:receipt];
    }
    BOOL saved=YES;
    if(count || v2JournalStale) {
        if(count)v2LastRestore=@{@"reason":reason,@"results":report};
        saved=v2Persist();v2JournalStale=!saved;
    }
    v2Count();
    if(atomic_load(&v2Restoring) || v2JournalStale)v2ScheduleRetry();
    else v2RetryDelayMS=250;
    if(summary)*summary=(struct dw2_restore_reply){.count=count,.pending=pending,.journal_persisted=saved};
    if(!summary && count) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"reason":reason,@"results":report,@"journal_persisted":@(saved)} options:0 error:NULL];
        fprintf(stderr,"V2_RESTORE %s\n",data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "serialization failed");
    }
}

// One frame. A record that cannot be applied fails alone. Windows not yet in the
// table are captured first and journalled together, once, before any of them is
// changed; a frame of known windows writes nothing to disk.
static void v2Apply(const struct dw2_record *records,uint32_t count,uint8_t *status) {
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:count];
    NSMutableDictionary *replacedReleases=[NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *releasing=[NSMutableSet set];
    for(uint32_t i=0;i<count;i++)if(records[i].flags==DW2_RECORD_RESTORE)[releasing addObject:@(records[i].id.wid)];
    BOOL changed=NO;
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];
        [entries addObject:NSNull.null];
        if((r->flags&~(uint32_t)(DW2_RECORD_HAS_ALPHA|DW2_RECORD_RESTORE))||r->flags==(DW2_RECORD_HAS_ALPHA|DW2_RECORD_RESTORE)){status[i]=DW2_MALFORMED;continue;}
        if(!v2InScope(&r->id)){status[i]=DW2_SCOPE;continue;}
        if(r->flags==DW2_RECORD_RESTORE){
            DW2Entry *entry=v2Table[@(r->id.wid)];
            if(entry&&!v2SameProcess(&entry->who,&r->id)){status[i]=DW2_IDENTITY;continue;}
            // No entry means this identity was never changed or already restored.
            // Retry only marked entries; every other held window stays untouched.
            if(entry)entry->state=DW2_RESTORING;
            if(entry||v2JournalStale){struct dw2_restore_reply summary={0};v2Restore(@"window released",YES,nil,&summary);
                status[i]=v2Table[@(r->id.wid)]?DW2_RESTORE_PENDING:summary.journal_persisted?DW2_APPLIED:DW2_JOURNAL;}
            else status[i]=DW2_APPLIED;
            continue;
        }
        // A malformed frame cannot both release and transform the same number.
        // Restoration wins, regardless of its position in that frame.
        if([releasing containsObject:@(r->id.wid)]){status[i]=DW2_RESTORE_PENDING;continue;}
        if(!finiteMatrix(CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]))){status[i]=DW2_MATRIX;continue;}
        BOOL wantsAlpha=(r->flags&DW2_RECORD_HAS_ALPHA)!=0;
        if(wantsAlpha && (!setAlpha || !getAlpha || !isfinite(r->alpha) || r->alpha<0 || r->alpha>1)){status[i]=DW2_ALPHA;continue;}
        int owner=0;struct dw2_identity now={0};uid_t uid=0;
        if(!v2Resolve(r->id.wid,&owner,&now,&uid) || !v2SameProcess(&now,&r->id) || uid!=getuid()){status[i]=DW2_IDENTITY;continue;}
        NSNumber *key=@(r->id.wid);
        DW2Entry *e=v2Table[key];
        if(e && !v2SameProcess(&e->who,&now)) {
            // The number now names another process's window: the recorded one is gone.
            [v2Table removeObjectForKey:key];e=nil;changed=YES;
        }
        if(e && e->owner!=owner){status[i]=DW2_IDENTITY;continue;}
        if(e && e->state==DW2_RESTORING){status[i]=DW2_RESTORE_PENDING;continue;}
        if(!e) {
            // Live released originals remain obligations across connection death.
            // Make room only by proving a recorded instance is gone, never age.
            if(!v2Released[key] && v2Table.count+v2Released.count>=DW2_MAX_TABLE) {
                for(NSNumber *releasedKey in v2Released.allKeys){DW2Entry *old=v2Released[releasedKey];
                    if(v2RestoreIdentity(&old->who,old->owner)==DW2_INSTANCE_GONE){[v2Released removeObjectForKey:releasedKey];changed=YES;}}
            }
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
        if(wantsAlpha && !e->alphaTouched){e->alphaTouched=e->alphaFresh=YES;changed=YES;}
        entries[i]=e;status[i]=DW2_APPLIED;
    }
    if(changed) {
        BOOL saved=v2Persist();
        for(uint32_t i=0;i<count;i++) {
            DW2Entry *e=entries[i];
            if((id)e==NSNull.null || !(e->fresh || e->alphaFresh))continue;
            if(!saved) {
                // Nothing of this window (or of its alpha) is changed without a record on disk.
                status[i]=DW2_JOURNAL;entries[i]=NSNull.null;
                if(e->fresh){NSNumber *key=@(e->who.wid);[v2Table removeObjectForKey:key];if(replacedReleases[key])v2Released[key]=replacedReleases[key];}
                else e->alphaTouched=NO;
            }
        }
        for(DW2Entry *e in v2Table.objectEnumerator)e->fresh=e->alphaFresh=NO;
        if(!saved){v2JournalStale=YES;v2ScheduleRetry();}
    }
    for(uint32_t i=0;i<count;i++) {
        DW2Entry *e=entries[i];
        if((id)e==NSNull.null)continue;
        const struct dw2_record *r=&records[i];
        if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
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
        if(r->flags&DW2_RECORD_HAS_ALPHA) {
            if(!v2EntryCurrent(e)){status[i]=DW2_IDENTITY;continue;}
            float alpha=-1;
            if(setAlpha(mainConnection(),e->who.wid,r->alpha) || getAlpha(mainConnection(),e->who.wid,&alpha) || alpha!=r->alpha)ok=NO;
        }
        if(!v2EntryCurrent(e))status[i]=DW2_IDENTITY;
        else if(!ok)status[i]=DW2_NOT_APPLIED;
        else {e->appliedTransform=requested;e->appliedTransformKnown=YES;}
    }
    v2Count();
}

static NSData *v2Enrollment(void) {
    struct dw2_enrollment_reply head={.scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.server_pid=getpid()};
    NSMutableData *reply=[NSMutableData dataWithLength:sizeof(head)];
    if(fixtureOnly){
        struct dw2_process own={.pid=getpid(),.birth_sec=[fixtureIdentity[@"birth_sec"]unsignedLongLongValue],.birth_usec=[fixtureIdentity[@"birth_usec"]unsignedLongLongValue]};
        [reply appendBytes:&own length:sizeof(own)];head.count=1;
    }else for(NSDictionary *entry in allowlist){
        struct dw2_process process={.pid=[entry[@"pid"]intValue],.birth_sec=[entry[@"birth_sec"]unsignedLongLongValue],.birth_usec=[entry[@"birth_usec"]unsignedLongLongValue]};
        [reply appendBytes:&process length:sizeof(process)];head.count++;
    }
    memcpy(reply.mutableBytes,&head,sizeof(head));return reply;
}
static BOOL v2FiniteRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        && r.size.width>0 && r.size.height>0;
}
// Inspect is independent of the held-window table. It can read originals before
// first touch and verify restoration after removal without claiming the window.
static struct dw2_inspect_reply v2Inspect(struct dw2_identity requested) {
    struct dw2_inspect_reply reply={.id=requested,.status=DW2_SCOPE};
    if(!v2InScope(&requested))return reply;
    reply.status=DW2_IDENTITY;
    if(requested.pid<=0 || !requested.wid || !requested.birth_sec || requested.birth_usec>=1000000)return reply;
    int owner=0;struct dw2_identity before={0},after={0};uid_t uid=0;
    if(!v2Resolve(requested.wid,&owner,&before,&uid) || uid!=getuid() || !v2SameProcess(&before,&requested))return reply;
    CGAffineTransform transform={0};CGRect bounds=CGRectZero,screen=CGRectZero;
    reply.status=DW2_SNAPSHOT;
    if(getTransform(mainConnection(),requested.wid,&transform) || getBounds(mainConnection(),requested.wid,&bounds)
        || getScreenRect(mainConnection(),requested.wid,&screen) || !finiteMatrix(transform) || !v2FiniteRect(bounds) || !v2FiniteRect(screen))return reply;
    int afterOwner=0;
    reply.status=DW2_IDENTITY;
    if(!v2Resolve(requested.wid,&afterOwner,&after,&uid) || uid!=getuid() || owner!=afterOwner || !v2SameProcess(&after,&requested) || !v2InScope(&after))return reply;
    reply.status=DW2_APPLIED;reply.owner=owner;
    memcpy(reply.transform,(double[]){transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty},sizeof(reply.transform));
    memcpy(reply.bounds,(double[]){bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height},sizeof(reply.bounds));
    memcpy(reply.screen_rect,(double[]){screen.origin.x,screen.origin.y,screen.size.width,screen.size.height},sizeof(reply.screen_rect));
    return reply;
}
static NSData *v2Probe(void) {
    struct dw2_probe_reply head={.scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.caps=v2Caps(),
        .queue=v2OnMain ? DW2_QUEUE_MAIN : DW2_QUEUE_OWN,.lease_ms=DW2_LEASE_MS,.server_pid=getpid(),.held=atomic_load(&v2Held),.restoring=atomic_load(&v2Restoring),.journal_pending=v2JournalStale,
        .frames_received=atomic_load(&v2FramesReceived),.frames_applied=atomic_load(&v2FramesApplied),.frames_superseded=atomic_load(&v2FramesSuperseded),.journal_writes=atomic_load(&v2JournalWrites),
        .table_count=(uint32_t)v2Table.count,.fixture_count=fixtureOnly ? fixtureCount : 0};
    NSMutableData *reply=[NSMutableData dataWithBytes:&head length:sizeof(head)];
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        struct dw2_probe_entry p={.id=e->who,.state=e->state,.alpha=-1};
        CGAffineTransform t={0};CGRect r=CGRectZero;
        if(getTransform(mainConnection(),e->who.wid,&t)==0){p.transform[0]=t.a;p.transform[1]=t.b;p.transform[2]=t.c;p.transform[3]=t.d;p.transform[4]=t.tx;p.transform[5]=t.ty;}
        if(getScreenRect(mainConnection(),e->who.wid,&r)==0){p.screen_rect[0]=r.origin.x;p.screen_rect[1]=r.origin.y;p.screen_rect[2]=r.size.width;p.screen_rect[3]=r.size.height;}
        if(getAlpha)getAlpha(mainConnection(),e->who.wid,&p.alpha);
        [reply appendBytes:&p length:sizeof(p)];
    }
    // Cooperative scope only: the host's own windows, so a test can name them.
    for(uint32_t i=0;i<head.fixture_count;i++) {
        int owner=0;struct dw2_identity who={.wid=fixtureWids[i]};uid_t uid=0;
        v2Resolve(fixtureWids[i],&owner,&who,&uid);
        [reply appendBytes:&who length:sizeof(who)];
    }
    return reply;
}

// Replies are written without ever waiting long for a reader: a client that does
// not take its replies within a quarter second loses the connection, and for the
// control connection that ends the session and restores everything.
static BOOL v2Send(DW2Connection *c,uint16_t type,uint64_t seq,const void *body,size_t length) {
    struct dw2_header header={.length=(uint32_t)length,.type=type|DW2_REPLY,.seq=seq};
    struct iovec parts[2]={{&header,sizeof(header)},{(void *)body,length}};
    uint64_t deadline=v2Now()+250;
    pthread_mutex_lock(&c->writeLock);
    BOOL ok=!atomic_load(&c->closed);
    while(ok && parts[0].iov_len+parts[1].iov_len) {
        ssize_t n=writev(c->fd,parts,2);
        if(n<0 && errno==EINTR)continue;
        if(n<0 && errno==EAGAIN) {
            int remaining=(int)((int64_t)deadline-(int64_t)v2Now());
            struct pollfd p={.fd=c->fd,.events=POLLOUT};
            if(remaining<=0 || (poll(&p,1,remaining)<0 && errno!=EINTR))ok=NO;
            continue;
        }
        if(n<=0){ok=NO;break;}
        for(int i=0;i<2 && n;i++) {
            size_t part=MIN((size_t)n,parts[i].iov_len);
            parts[i].iov_base=(char *)parts[i].iov_base+part;parts[i].iov_len-=part;n-=part;
        }
    }
    if(!ok && !atomic_exchange(&c->closed,true))shutdown(c->fd,SHUT_RDWR);
    pthread_mutex_unlock(&c->writeLock);
    return ok;
}

// Takes the newest frame, if no later request has discarded it, and applies it.
// One of these is queued per frame received; all but the one that finds the slot
// full return at once, so the queue never holds work for a frame already replaced.
static void v2Drain(uint64_t barrier) {
    pthread_mutex_lock(&v2Lock);
    NSData *frame=barrier==v2Barrier ? v2Slot : nil;
    DW2Connection *c=v2SlotOwner;
    uint64_t seq=v2SlotSeq;
    struct dw2_frame_reply head={.disposition=DW2_FRAME_APPLIED,.superseded=v2SupersededPending};
    if(frame){v2Slot=nil;v2SlotOwner=nil;v2SupersededPending=0;}
    pthread_mutex_unlock(&v2Lock);
    if(!frame)return;
    head.count=(uint32_t)(frame.length/sizeof(struct dw2_record));
    NSMutableData *reply=[NSMutableData dataWithLength:sizeof(head)+head.count];
    v2Apply(frame.bytes,head.count,(uint8_t *)reply.mutableBytes+sizeof(head));
    head.frames_applied=atomic_fetch_add(&v2FramesApplied,1)+1;
    memcpy(reply.mutableBytes,&head,sizeof(head));
    v2Send(c,DW2_FRAME,seq,reply.bytes,reply.length);
}
// Called with v2Lock held. The frame in the slot will never be applied.
static BOOL v2Discard(uint64_t *seq,uint32_t *superseded) {
    BOOL had=v2Slot!=nil;
    *seq=v2SlotSeq;*superseded=v2SupersededPending;
    v2Slot=nil;v2SlotOwner=nil;v2SupersededPending=0;v2Barrier++;
    if(had)atomic_fetch_add(&v2FramesSuperseded,1);
    return had;
}
static void v2SendDropped(DW2Connection *c,uint64_t seq,uint32_t superseded) {
    struct dw2_frame_reply head={.disposition=DW2_FRAME_DROPPED,.superseded=superseded,.frames_applied=atomic_load(&v2FramesApplied)};
    v2Send(c,DW2_FRAME,seq,&head,sizeof(head));
}

static BOOL v2Hello(DW2Connection *c,const struct dw2_header *h,const void *body) {
    struct dw2_hello_reply reply={.status=DW2_HELLO_OK,.lease_ms=DW2_LEASE_MS,.max_records=DW2_MAX_RECORDS,.max_body=DW2_MAX_BODY,.caps=v2Caps(),
        .scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.queue=v2OnMain ? DW2_QUEUE_MAIN : DW2_QUEUE_OWN,.server_pid=getpid()};
    struct dw2_hello hello;
    if(h->type!=DW2_HELLO)return NO;
    if(h->length!=sizeof(hello))reply.status=DW2_HELLO_MALFORMED;
    else {
        memcpy(&hello,body,sizeof(hello));
        if(memcmp(hello.magic,DW2_MAGIC,4) || hello.version!=DW2_VERSION)reply.status=DW2_HELLO_VERSION;
        else if(memcmp(hello.nonce,secret.UTF8String,64))reply.status=DW2_HELLO_AUTH;
        else if(hello.role!=DW2_ROLE_CONTROL && hello.role!=DW2_ROLE_HEARTBEAT)reply.status=DW2_HELLO_MALFORMED;
        else {
            pthread_mutex_lock(&v2Lock);
            if(hello.role==DW2_ROLE_CONTROL) {
                // One session at a time: its end restores everything it placed.
                if(v2Session)reply.status=DW2_HELLO_BUSY;
                else {
                    v2Session=++v2Sessions;v2Beats=[NSMutableArray array];
                    arc4random_buf(v2Token,sizeof(v2Token));
                }
            } else if(!v2Session || memcmp(hello.token,v2Token,sizeof(v2Token)))reply.status=DW2_HELLO_TOKEN;
            else [v2Beats addObject:c];
            if(!reply.status) {
                c->role=hello.role;c->session=v2Session;memcpy(reply.token,v2Token,sizeof(v2Token));
                atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
            }
            pthread_mutex_unlock(&v2Lock);
        }
    }
    return v2Send(c,DW2_HELLO,h->seq,&reply,sizeof(reply)) && !reply.status;
}
// NO is a protocol error: the connection ends, and with it, for the control
// connection, the session.
static BOOL v2Handle(DW2Connection *c,const struct dw2_header *h,const void *body) {
    if(!c->role)return v2Hello(c,h,body);
    if(h->type==DW2_HEARTBEAT) {
        if(h->length)return NO;
        pthread_mutex_lock(&v2Lock);
        BOOL live=c->session==v2Session;
        if(live)atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        pthread_mutex_unlock(&v2Lock);
        if(!live)return NO;
        // Answered here, from counters: a stalled apply queue never delays a heartbeat.
        struct dw2_heartbeat_reply reply={.status=0,.lease_ms=DW2_LEASE_MS,.held=atomic_load(&v2Held),.restoring=atomic_load(&v2Restoring)};
        return v2Send(c,DW2_HEARTBEAT,h->seq,&reply,sizeof(reply));
    }
    if(c->role!=DW2_ROLE_CONTROL)return NO;
    uint64_t seq=h->seq;
    if(h->type==DW2_INSPECT) {
        if(h->length!=sizeof(struct dw2_identity))return NO;
        struct dw2_identity requested;memcpy(&requested,body,sizeof(requested));
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        dispatch_async(v2q,^{struct dw2_inspect_reply reply=v2Inspect(requested);v2Send(c,DW2_INSPECT,seq,&reply,sizeof(reply));});
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->type==DW2_FRAME) {
        struct dw2_frame head;
        if(h->length<sizeof(head))return NO;
        memcpy(&head,body,sizeof(head));
        if(head.reserved || head.count>DW2_MAX_RECORDS || h->length!=sizeof(head)+(size_t)head.count*sizeof(struct dw2_record) || seq<=c->lastFrame)return NO;
        c->lastFrame=seq;
        NSData *frame=[NSData dataWithBytes:(const char *)body+sizeof(head) length:h->length-sizeof(head)];
        atomic_fetch_add(&v2FramesReceived,1);
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        // Newest wins: a frame not yet taken is replaced, never queued behind.
        if(v2Slot){v2SupersededPending++;atomic_fetch_add(&v2FramesSuperseded,1);}
        v2Slot=frame;v2SlotSeq=seq;v2SlotOwner=c;
        uint64_t barrier=v2Barrier;
        dispatch_async(v2q,^{v2Drain(barrier);});
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->length || (h->type!=DW2_RESTORE_ALL && h->type!=DW2_PROBE && h->type!=DW2_ENROLLMENT))return NO;
    pthread_mutex_lock(&v2Lock);
    atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
    if(h->type==DW2_PROBE)dispatch_async(v2q,^{NSData *reply=v2Probe();v2Send(c,DW2_PROBE,seq,reply.bytes,reply.length);});
    else if(h->type==DW2_ENROLLMENT)dispatch_async(v2q,^{NSData *reply=v2Enrollment();v2Send(c,DW2_ENROLLMENT,seq,reply.bytes,reply.length);});
    else {
        // A frame still waiting is older than this request and must not follow it.
        uint64_t droppedSeq;uint32_t superseded;
        BOOL dropped=v2Discard(&droppedSeq,&superseded);
        dispatch_async(v2q,^{
            if(dropped)v2SendDropped(c,droppedSeq,superseded);
            struct dw2_restore_reply summary;
            NSMutableData *reply=[NSMutableData dataWithLength:sizeof(summary)];
            v2Restore(@"explicit",NO,reply,&summary);
            memcpy(reply.mutableBytes,&summary,sizeof(summary));
            v2Send(c,DW2_RESTORE_ALL,seq,reply.bytes,reply.length);
        });
    }
    pthread_mutex_unlock(&v2Lock);
    return YES;
}
static void *v2Serve(void *argument) { @autoreleasepool {
    DW2Connection *c=(__bridge_transfer DW2Connection *)argument;
    const size_t capacity=sizeof(struct dw2_header)+DW2_MAX_BODY+65536;
    char *buffer=malloc(capacity);size_t used=0;
    uint64_t helloDeadline=v2Now()+DW2_LEASE_MS;
    NSString *reason=@"disconnect";
    while(buffer && !atomic_load(&c->closed)) {
        // The control connection carries the lease, which a heartbeat on the second
        // connection also renews: on a timeout the deadline is simply read again.
        int remaining=-1;
        if(c->role!=DW2_ROLE_HEARTBEAT) {
            int64_t left=(int64_t)(c->role ? atomic_load(&v2Deadline) : helloDeadline)-(int64_t)v2Now();
            if(left<=0){reason=@"lease expired";break;}
            remaining=(int)left;
        }
        struct pollfd p={.fd=c->fd,.events=POLLIN};
        int ready=poll(&p,1,remaining);
        if(ready<0 && errno!=EINTR)break;
        if(ready<=0)continue;
        ssize_t n=read(c->fd,buffer+used,MIN((size_t)65536,capacity-used));
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
        if(n<=0)break;
        used+=n;
        size_t offset=0;BOOL ok=YES;
        while(ok && used-offset>=sizeof(struct dw2_header)) { @autoreleasepool {
            struct dw2_header h;memcpy(&h,buffer+offset,sizeof(h));
            if(h.flags || h.length>DW2_MAX_BODY || (h.type&DW2_REPLY)){ok=NO;reason=@"protocol error";break;}
            if(used-offset<sizeof(h)+h.length)break;
            if(!v2Handle(c,&h,buffer+offset+sizeof(h))){ok=NO;reason=@"protocol error";break;}
            offset+=sizeof(h)+h.length;
        } }
        if(!ok)break;
        memmove(buffer,buffer+offset,used-offset);used-=offset;
    }
    free(buffer);
    pthread_mutex_lock(&v2Lock);
    if(c->role==DW2_ROLE_HEARTBEAT)[v2Beats removeObject:c];
    else if(c->role==DW2_ROLE_CONTROL) {
        // End of session, whatever the cause: nothing it placed outlives it. Queued
        // under the lock, so no request of a later session can precede the restore.
        NSArray<DW2Connection *> *beats=v2Beats;
        uint64_t droppedSeq;uint32_t superseded;
        v2Discard(&droppedSeq,&superseded);
        v2Beats=nil;v2Session=0;
        for(DW2Connection *beat in beats)if(!atomic_exchange(&beat->closed,true))shutdown(beat->fd,SHUT_RDWR);
        dispatch_async(v2q,^{v2Restore(reason,NO,nil,NULL);});
    }
    pthread_mutex_unlock(&v2Lock);
    if(!atomic_exchange(&c->closed,true))shutdown(c->fd,SHUT_RDWR);
    atomic_fetch_sub(&v2Connections,1);
    return NULL;
} }

// A journal left by an instance that died holding windows. Each recorded window is
// restored only if its whole recorded identity still resolves to the same process
// instance and passes this instance's scope; the value written is the one captured
// before any helper touched it. A bare window number is never trusted.
static BOOL v2Keys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:value.allKeys]isEqual:[NSSet setWithArray:keys]];
}
static BOOL v2Integer(id value,uint64_t minimum,uint64_t maximum) {
    return isNumber(value) && !CFNumberIsFloatType((__bridge CFNumberRef)value)
        && [value compare:@(minimum)]!=NSOrderedAscending && [value compare:@(maximum)]!=NSOrderedDescending;
}
static BOOL v2Boolean(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID(); }
static BOOL v2LastRestoreValid(id value) {
    if(value==NSNull.null)return YES;
    if(!v2Keys(value,@[@"reason",@"results"]) || ![value[@"reason"]isKindOfClass:NSString.class] || ![value[@"reason"]length]
        || ![value[@"results"]isKindOfClass:NSArray.class] || [value[@"results"]count]>DW2_MAX_TABLE)return NO;
    NSMutableSet *windows=[NSMutableSet set];
    for(NSDictionary *r in value[@"results"]) {
        if(![r isKindOfClass:NSDictionary.class])return NO;
        // Diagnostics never authorize writes and cannot make valid originals
        // unrecoverable. Keep validating the original restoration receipt only.
        NSMutableDictionary *fields=[r mutableCopy];[fields removeObjectForKey:@"diagnostic"];
        if(!v2Keys(fields,@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"outcome",@"set_status"])
            || !v2Integer(r[@"pid"],1,INT_MAX) || !v2Integer(r[@"birth_sec"],1,UINT64_MAX) || !v2Integer(r[@"birth_usec"],0,999999)
            || !v2Integer(r[@"wid"],1,UINT32_MAX) || !isNumber(r[@"set_status"]) || CFNumberIsFloatType((__bridge CFNumberRef)r[@"set_status"])
            || [r[@"set_status"]compare:@(INT_MIN)]==NSOrderedAscending || [r[@"set_status"]compare:@(INT_MAX)]==NSOrderedDescending
            || ![@[@"restored",@"gone",@"pending"]containsObject:r[@"outcome"]] || [windows containsObject:r[@"wid"]])return NO;
        [windows addObject:r[@"wid"]];
    }
    return YES;
}
// Schema 3 preserves released originals for a later, explicitly authorized
// connection handoff. No schema-2 journal can establish that missing obligation.
static NSArray *v2WriterKeys(void) {
    return @[@"server_pid",@"server_birth_sec",@"server_birth_usec",@"server_uid",@"boot_uuid"];
}
static BOOL v2BootUUIDValid(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=36)return NO;
    for(NSUInteger i=0;i<36;i++) {
        unichar c=[value characterAtIndex:i];
        if(i==8 || i==13 || i==18 || i==23){if(c!='-')return NO;}
        else if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return NO;
    }
    return YES;
}
static BOOL v2WriterValid(NSDictionary *value) {
    return v2Integer(value[@"server_pid"],1,INT_MAX) && v2Integer(value[@"server_birth_sec"],1,UINT64_MAX)
        && v2Integer(value[@"server_birth_usec"],0,999999) && v2Integer(value[@"server_uid"],0,UINT32_MAX)
        && v2BootUUIDValid(value[@"boot_uuid"]);
}
static NSDictionary *v2CurrentWriterIdentity(void) {
    struct proc_bsdinfo process={0};char boot[37]={0};size_t length=sizeof(boot);
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process)
        || process.pbi_uid!=getuid() || sysctlbyname("kern.bootsessionuuid",boot,&length,NULL,0) || length!=sizeof(boot)
        || boot[36]!='\0' || !process.pbi_start_tvsec)return nil;
    // Unlike calendar boottime, this kernel identity does not move when the
    // wall clock changes. Persist only its exact canonical uppercase spelling.
    NSString *bootUUID=[[NSString alloc]initWithBytes:boot length:36 encoding:NSASCIIStringEncoding];
    if(!v2BootUUIDValid(bootUUID))return nil;
    return @{@"server_pid":@(getpid()),@"server_birth_sec":@(process.pbi_start_tvsec),@"server_birth_usec":@(process.pbi_start_tvusec),
        @"server_uid":@(getuid()),@"boot_uuid":bootUUID};
}
static BOOL v2WriterSame(NSDictionary *a,NSDictionary *b) {
    for(NSString *key in v2WriterKeys())if(![a[key]isEqual:b[key]])return NO;
    return YES;
}
static BOOL v2OldWriterDead(NSDictionary *writer) {
    int pid=[writer[@"server_pid"]intValue];struct proc_bsdinfo process={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process))
        return process.pbi_start_tvsec!=[writer[@"server_birth_sec"]unsignedLongLongValue]
            || process.pbi_start_tvusec!=[writer[@"server_birth_usec"]unsignedLongLongValue];
    // An inaccessible process is not dead. ESRCH is affirmative kernel absence.
    errno=0;return kill(pid,0)<0 && errno==ESRCH;
}
static BOOL v2RetiredWriter(NSDictionary *writer) {
    return [writer[@"server_uid"]isEqual:v2WriterIdentity[@"server_uid"]]
        && [writer[@"boot_uuid"]isEqual:v2WriterIdentity[@"boot_uuid"]]
        && !v2WriterSame(writer,v2WriterIdentity) && v2OldWriterDead(writer);
}
static BOOL v2RecoveryConfigValid(NSDictionary *config) {
    NSArray *keys=@[@"recovery_source_sha256",@"recovery_server_pid",@"recovery_server_birth_sec",@"recovery_server_birth_usec",
        @"recovery_server_uid",@"recovery_boot_uuid"];
    NSUInteger count=0;
    for(NSString *key in config)if([key hasPrefix:@"recovery_"]){if(![keys containsObject:key])return NO;count++;}
    if(!count)return YES;
    NSString *hash=config[@"recovery_source_sha256"];
    if(count!=keys.count || ![hash isKindOfClass:NSString.class] || hash.length!=64)return NO;
    for(NSUInteger i=0;i<hash.length;i++){unichar c=[hash characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return NO;}
    NSMutableDictionary *writer=[NSMutableDictionary dictionary];
    for(NSString *key in v2WriterKeys())writer[key]=config[[@"recovery_"stringByAppendingString:key]];
    return v2WriterValid(writer);
}
static NSData *v2ReadJournal(const char *name,BOOL *absent) {
    *absent=NO;int fd=openat(directoryFD,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0){*absent=errno==ENOENT;return nil;}
    struct stat st;
    if(fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&0777)!=0600
        || st.st_size<=0 || st.st_size>4*1024*1024){close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];char chunk[4096];ssize_t n;
    for(;;){n=read(fd,chunk,sizeof(chunk));if(n<0&&errno==EINTR)continue;if(n<=0)break;
        [data appendBytes:chunk length:n];if(data.length>4*1024*1024){n=-1;break;}}
    close(fd);return n==0 && data.length==(NSUInteger)st.st_size ? data : nil;
}
static BOOL v2RemoveStaging(void) {
    struct stat stage;
    if(fstatat(directoryFD,"v2-journal.next",&stage,AT_SYMLINK_NOFOLLOW)==0) {
        if(!S_ISREG(stage.st_mode) || stage.st_uid!=getuid() || (stage.st_mode&0777)!=0600)return NO;
        return !unlinkat(directoryFD,"v2-journal.next",0) && !fsync(directoryFD);
    }
    return errno==ENOENT;
}
static DW2Entry *v2DecodeEntry(NSDictionary *w,BOOL released) {
    if(!v2Keys(w,@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"owner",@"transform",@"alpha",@"alpha_touched",@"bounds",@"state"])
        || !v2Integer(w[@"pid"],1,INT_MAX) || !v2Integer(w[@"birth_sec"],1,UINT64_MAX) || !v2Integer(w[@"birth_usec"],0,999999)
        || !v2Integer(w[@"wid"],1,UINT32_MAX) || !v2Integer(w[@"owner"],1,INT_MAX) || !v2Boolean(w[@"alpha_touched"])
        || !(released ? [w[@"state"]isEqual:@"released"] : [@[@"held",@"restoring",@"reattaching"]containsObject:w[@"state"]]))return nil;
    NSArray *t=w[@"transform"],*b=w[@"bounds"];
    if(![t isKindOfClass:NSArray.class] || t.count!=6 || ![b isKindOfClass:NSArray.class] || b.count!=4)return nil;
    for(id value in [t arrayByAddingObjectsFromArray:b])if(!isNumber(value) || !isfinite([value doubleValue]))return nil;
    DW2Entry *e=[DW2Entry new];
    e->who=(struct dw2_identity){.pid=[w[@"pid"]intValue],.wid=[w[@"wid"]unsignedIntValue],.birth_sec=[w[@"birth_sec"]unsignedLongLongValue],.birth_usec=[w[@"birth_usec"]unsignedLongLongValue]};
    e->owner=[w[@"owner"]intValue];e->state=DW2_RESTORING;e->reattaching=[w[@"state"]isEqual:@"reattaching"];
    e->transform=CGAffineTransformMake([t[0]doubleValue],[t[1]doubleValue],[t[2]doubleValue],[t[3]doubleValue],[t[4]doubleValue],[t[5]doubleValue]);
    e->bounds=CGRectMake([b[0]doubleValue],[b[1]doubleValue],[b[2]doubleValue],[b[3]doubleValue]);
    if(!finiteMatrix(e->transform) || !v2FiniteRect(e->bounds))return nil;
    if(w[@"alpha"]!=NSNull.null) {
        if(!isNumber(w[@"alpha"]) || !isfinite([w[@"alpha"]doubleValue]) || [w[@"alpha"]doubleValue]<0 || [w[@"alpha"]doubleValue]>1)return nil;
        e->alpha=[w[@"alpha"]floatValue];e->hasAlpha=YES;
    }
    e->alphaTouched=[w[@"alpha_touched"]boolValue];
    if(e->alphaTouched && (!e->hasAlpha || !setAlpha || !getAlpha))return nil;
    return e;
}
static NSDictionary *v2DecodeJournal(NSData *data,NSMutableDictionary *active,NSMutableDictionary *released) {
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *keys=[v2WriterKeys()arrayByAddingObjectsFromArray:@[@"v",@"generation",@"state",@"windows",@"released_windows",@"last_restore"]];
    if(!v2Keys(journal,keys) || !v2Integer(journal[@"v"],3,3) || !v2WriterValid(journal) || !v2Integer(journal[@"generation"],0,UINT64_MAX-1)
        || ![journal[@"windows"]isKindOfClass:NSArray.class] || ![journal[@"released_windows"]isKindOfClass:NSArray.class]
        || [journal[@"windows"]count]+[journal[@"released_windows"]count]>DW2_MAX_TABLE || !v2LastRestoreValid(journal[@"last_restore"]))return nil;
    BOOL restoring=NO;
    for(NSDictionary *w in journal[@"windows"]) {
        DW2Entry *e=v2DecodeEntry(w,NO);if(!e || active[@(e->who.wid)])return nil;
        restoring|=![w[@"state"]isEqual:@"held"];active[@(e->who.wid)]=e;
    }
    for(NSDictionary *w in journal[@"released_windows"]) {
        DW2Entry *e=v2DecodeEntry(w,YES);if(!e || active[@(e->who.wid)] || released[@(e->who.wid)])return nil;
        released[@(e->who.wid)]=e;
    }
    NSString *state=!active.count ? @"empty" : restoring ? @"restoring" : @"holding";
    return [journal[@"state"]isEqual:state] ? journal : nil;
}
static BOOL v2LoadJournal(NSDictionary *recovery) {
    BOOL absent=NO;NSData *data=v2ReadJournal("v2-journal.json",&absent);
    if(!data&&!absent)return NO;
    BOOL sourceAbsent=NO;NSData *source=v2ReadJournal("recovery-source.json",&sourceAbsent);
    if(recovery) {
        if(!source || !v2RecoveryConfigValid(recovery))return NO;
        unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(source.bytes,(CC_LONG)source.length,bytes);
        NSMutableString *hash=[NSMutableString stringWithCapacity:64];for(unsigned i=0;i<sizeof(bytes);i++)[hash appendFormat:@"%02x",bytes[i]];
        if(![hash isEqual:recovery[@"recovery_source_sha256"]])return NO;
        NSDictionary *history=v2DecodeJournal(source,[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]);if(!history)return NO;
        for(NSString *key in v2WriterKeys())if(![history[key]isEqual:recovery[[@"recovery_"stringByAppendingString:key]]])return NO;
        if(!v2RetiredWriter(history))return NO;
        // After a second crash the newer committed journal is the sole active
        // authority. Validate historical provenance, but never merge or fall
        // back to it when a newer committed journal is malformed.
        if(absent)data=source;
    }else if(!sourceAbsent)return NO;
    if(!data)return v2RemoveStaging();
    NSMutableDictionary *active=[NSMutableDictionary dictionary],*released=[NSMutableDictionary dictionary];
    NSDictionary *journal=v2DecodeJournal(data,active,released);if(!journal)return NO;
    BOOL handoff=!v2WriterSame(journal,v2WriterIdentity);
    if(handoff) {
        if(!v2RetiredWriter(journal))return NO;
        for(NSNumber *wid in released){DW2Entry *e=released[wid];e->reattaching=YES;active[wid]=e;}
        [released removeAllObjects];
    }
    if(!v2RemoveStaging())return NO;
    v2Generation=recovery && absent ? 0 : [journal[@"generation"]unsignedLongLongValue];
    v2LastRestore=journal[@"last_restore"]==NSNull.null ? nil : journal[@"last_restore"];
    [v2Table addEntriesFromDictionary:active];[v2Released addEntriesFromDictionary:released];v2Count();
    // Commit the new writer's complete recovery obligation before any native
    // setter. Reattaching records retain their stricter guard durably on retry.
    if(handoff && !v2Persist())return NO;
    if(active.count)v2Restore(handoff ? @"connection handoff" : @"startup recovery",NO,nil,NULL);
    return YES;
}
// The sole listener. A failure is startup failure, never a fallback server.
static int v2Start(const char *directory,BOOL onMain,NSDictionary *recovery) {
    v2WriterIdentity=v2CurrentWriterIdentity();if(!v2WriterIdentity)return -__LINE__;
    v2OnMain=onMain;
    v2q=onMain ? dispatch_get_main_queue() : dispatch_queue_create("dw.v2",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    v2Table=[NSMutableDictionary dictionary];v2Released=[NSMutableDictionary dictionary];
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/" DW2_SOCKET,directory)>=(int)sizeof(addr.sun_path))return -__LINE__;
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0)return -__LINE__;
    if(bind(listener,(struct sockaddr *)&addr,sizeof(addr))){close(listener);return -__LINE__;}
    if(chmod(addr.sun_path,0600) || listen(listener,DW2_MAX_CONNECTIONS)){close(listener);unlinkat(directoryFD,DW2_SOCKET,0);return -__LINE__;}
    // Recovery's first pass finishes before accepting clients. Readiness cannot
    // succeed on a malformed journal, and there is no other listener to fall back to.
    __block BOOL loaded=NO;
    if(onMain)loaded=v2LoadJournal(recovery);
    else dispatch_sync(v2q,^{loaded=v2LoadJournal(recovery);});
    if(!loaded){close(listener);unlinkat(directoryFD,DW2_SOCKET,0);return -__LINE__;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        for(;;) {
            int client=accept(listener,NULL,NULL);
            if(client<0) {
                if(errno==EINTR || errno==ECONNABORTED)continue;
                // Out of descriptors or buffers is the process's passing trouble, not
                // the end of the listener: wait and accept again.
                if(errno==EMFILE || errno==ENFILE || errno==ENOBUFS || errno==ENOMEM){usleep(100000);continue;}
                break;
            }
            uid_t uid;gid_t gid;int one=1,size=65536;
            if(getpeereid(client,&uid,&gid) || uid!=getuid()){close(client);continue;}
            if(atomic_fetch_add(&v2Connections,1)>=DW2_MAX_CONNECTIONS){atomic_fetch_sub(&v2Connections,1);close(client);continue;}
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
            setsockopt(client,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));setsockopt(client,SOL_SOCKET,SO_RCVBUF,&size,sizeof(size));
            fcntl(client,F_SETFL,fcntl(client,F_GETFL)|O_NONBLOCK);
            DW2Connection *c=[DW2Connection new];c->fd=client;pthread_mutex_init(&c->writeLock,NULL);
            pthread_t thread;pthread_attr_t attributes;pthread_attr_init(&attributes);pthread_attr_setdetachstate(&attributes,PTHREAD_CREATE_DETACHED);
            void *argument=(__bridge_retained void *)c;
            if(pthread_create(&thread,&attributes,v2Serve,argument)){c=(__bridge_transfer DW2Connection *)argument;atomic_fetch_sub(&v2Connections,1);}
            pthread_attr_destroy(&attributes);
        }
        close(listener);
    });
    return 0;
}
