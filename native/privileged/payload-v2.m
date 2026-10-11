// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol v2: many windows per frame, newest frame wins, restore of everything.
// Original implementation, compiled as part of payload.m (one translation unit, so
// it shares v1's resolved symbols, scope and runtime directory). Wire format:
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
@interface DW2Entry : NSObject { @public struct dw2_identity who; int owner; CGAffineTransform transform; CGRect bounds; float alpha; BOOL hasAlpha, alphaTouched, fresh, alphaFresh; uint32_t state; } @end
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
// Scope as v1 enforces it, allowlist first: decided from the record alone, before
// any window-server lookup, and again for every record of every frame and restore.
static BOOL v2InScope(const struct dw2_identity *who) {
    if(allowlist && !v2Listed(who))return NO;
    if(!fixtureOnly)return YES;
    if(who->pid!=getpid())return NO;
    for(uint32_t i=0;i<fixtureCount;i++)if(fixtureWids[i]==who->wid)return YES;
    return NO;
}
static int v2ListedPID(uint32_t wid) {
    int pid=0;
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    if(!rows)return 0;
    for(NSDictionary *w in (__bridge NSArray *)rows)
        if([w[(id)kCGWindowNumber] unsignedIntValue]==wid){pid=[w[(id)kCGWindowOwnerPID] intValue];break;}
    CFRelease(rows);
    return pid;
}
// The window's current owner connection, process instance and user, from the window
// server and the kernel. Nothing a client sent is trusted here.
static BOOL v2Resolve(uint32_t wid,int *owner,struct dw2_identity *who,uid_t *uid) {
    int pid=0;
    if(getOwner(mainConnection(),wid,owner))return NO;
    if(!connectionPID || connectionPID(*owner,&pid) || pid<=0)pid=v2ListedPID(wid);
    struct proc_bsdinfo b={0};
    if(pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b))return NO;
    *who=(struct dw2_identity){.pid=pid,.wid=wid,.birth_sec=b.pbi_start_tvsec,.birth_usec=b.pbi_start_tvusec};
    *uid=b.pbi_uid;
    return YES;
}
// The window server keeps transforms as 32-bit floats, so a request is applied when
// it reads back equal after the same rounding.
static BOOL v2SameTransform(CGAffineTransform a,CGAffineTransform b) {
    return (float)a.a==(float)b.a && (float)a.b==(float)b.b && (float)a.c==(float)b.c && (float)a.d==(float)b.d && (float)a.tx==(float)b.tx && (float)a.ty==(float)b.ty;
}
static void v2Count(void) {
    uint32_t restoring=0;
    for(DW2Entry *e in v2Table.objectEnumerator)if(e->state==DW2_RESTORING)restoring++;
    atomic_store(&v2Held,(uint32_t)v2Table.count-restoring);atomic_store(&v2Restoring,restoring);
    if(!v2Table.count)protocolRelease(2);
}

// v1's persist technique under v2's own names; recovery.json is never touched.
static BOOL v2Persist(void) {
    NSMutableArray *windows=[NSMutableArray array];
    BOOL restoring=NO;
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(e->state==DW2_RESTORING)restoring=YES;
        [windows addObject:@{@"pid":@(e->who.pid),@"birth_sec":@(e->who.birth_sec),@"birth_usec":@(e->who.birth_usec),@"wid":@(e->who.wid),@"owner":@(e->owner),
            @"transform":matrix(e->transform),@"alpha":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,@"alpha_touched":@(e->alphaTouched),
            @"bounds":@[@(e->bounds.origin.x),@(e->bounds.origin.y),@(e->bounds.size.width),@(e->bounds.size.height)],@"state":e->state==DW2_HELD ? @"held" : @"restoring"}];
    }
    NSDictionary *journal=@{@"v":@2,@"server_pid":@(getpid()),@"generation":@(v2Generation+1),@"state":!windows.count ? @"empty" : restoring ? @"restoring" : @"holding",
        @"windows":windows,@"last_restore":v2LastRestore ?: (id)NSNull.null};
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
        struct dw2_restore_result r={.id=e->who,.outcome=DW2_GONE,.set_status=0};
        int owner=0;struct dw2_identity now={0};uid_t uid=0;
        if(!v2Resolve(e->who.wid,&owner,&now,&uid)) {
            // Unresolvable but still listed by the window server is not proof it is gone.
            int listed=v2ListedPID(e->who.wid);struct proc_bsdinfo b={0};
            if(listed==e->who.pid && proc_pidinfo(listed,PROC_PIDTBSDINFO,0,&b,sizeof(b))==sizeof(b) && b.pbi_start_tvsec==e->who.birth_sec && b.pbi_start_tvusec==e->who.birth_usec){r.outcome=DW2_PENDING;r.set_status=-1;}
        } else if(v2SameProcess(&now,&e->who) && owner==e->owner && uid==getuid() && v2InScope(&e->who)) {
            CGAffineTransform actual=CGAffineTransformIdentity;
            r.set_status=setTransform(mainConnection(),e->who.wid,e->transform);
            BOOL ok=r.set_status==0 && getTransform(mainConnection(),e->who.wid,&actual)==0 && v2SameTransform(actual,e->transform);
            if(e->alphaTouched) {
                float alpha=-1;int status=setAlpha(mainConnection(),e->who.wid,e->alpha);
                if(status && !r.set_status)r.set_status=status;
                if(status || getAlpha(mainConnection(),e->who.wid,&alpha) || alpha!=e->alpha)ok=NO;
            }
            r.outcome=ok ? DW2_RESTORED : DW2_PENDING;
        }
        if(r.outcome==DW2_PENDING){e->state=DW2_RESTORING;pending++;}
        else [v2Table removeObjectForKey:wid];
        count++;
        [results appendBytes:&r length:sizeof(r)];
        [report addObject:@{@"pid":@(r.id.pid),@"birth_sec":@(r.id.birth_sec),@"birth_usec":@(r.id.birth_usec),@"wid":@(r.id.wid),
            @"outcome":r.outcome==DW2_RESTORED ? @"restored" : r.outcome==DW2_GONE ? @"gone" : @"pending",@"set_status":@(r.set_status)}];
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
    BOOL changed=NO;
    for(uint32_t i=0;i<count;i++) {
        const struct dw2_record *r=&records[i];
        [entries addObject:NSNull.null];
        if(r->flags&~(uint32_t)DW2_RECORD_HAS_ALPHA){status[i]=DW2_MALFORMED;continue;}
        if(!v2InScope(&r->id)){status[i]=DW2_SCOPE;continue;}
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
            if(v2Table.count>=DW2_MAX_TABLE){status[i]=DW2_TABLE_FULL;continue;}
            if(!protocolClaim(2)){status[i]=DW2_BUSY_V1;continue;}
            e=[DW2Entry new];e->who=now;e->owner=owner;e->state=DW2_HELD;e->fresh=YES;
            if(getTransform(mainConnection(),now.wid,&e->transform) || !finiteMatrix(e->transform) || getBounds(mainConnection(),now.wid,&e->bounds)){status[i]=DW2_SNAPSHOT;continue;}
            // The original alpha is captured with the window, whether or not this
            // record changes it, so a later record can.
            if(getAlpha && setAlpha) {
                if(getAlpha(mainConnection(),now.wid,&e->alpha) || !isfinite(e->alpha)){status[i]=DW2_SNAPSHOT;continue;}
                e->hasAlpha=YES;
            }
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
                if(e->fresh)[v2Table removeObjectForKey:@(e->who.wid)];
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
        CGAffineTransform requested=CGAffineTransformMake(r->m[0],r->m[1],r->m[2],r->m[3],r->m[4],r->m[5]),actual=CGAffineTransformIdentity;
        BOOL ok=setTransform(mainConnection(),e->who.wid,requested)==0 && getTransform(mainConnection(),e->who.wid,&actual)==0 && v2SameTransform(actual,requested);
        if(r->flags&DW2_RECORD_HAS_ALPHA) {
            float alpha=-1;
            if(setAlpha(mainConnection(),e->who.wid,r->alpha) || getAlpha(mainConnection(),e->who.wid,&alpha) || alpha!=r->alpha)ok=NO;
        }
        if(!ok)status[i]=DW2_NOT_APPLIED;
    }
    v2Count();
}

static NSData *v2Probe(void) {
    struct dw2_probe_reply head={.scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.caps=setAlpha && getAlpha ? DW2_CAP_ALPHA : 0,
        .queue=v2OnMain ? DW2_QUEUE_MAIN : DW2_QUEUE_OWN,.lease_ms=DW2_LEASE_MS,.server_pid=getpid(),.held=atomic_load(&v2Held),.restoring=atomic_load(&v2Restoring),
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
    struct dw2_hello_reply reply={.status=DW2_HELLO_OK,.lease_ms=DW2_LEASE_MS,.max_records=DW2_MAX_RECORDS,.max_body=DW2_MAX_BODY,.caps=setAlpha && getAlpha ? DW2_CAP_ALPHA : 0,
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
    if(h->length || (h->type!=DW2_RESTORE_ALL && h->type!=DW2_PROBE))return NO;
    pthread_mutex_lock(&v2Lock);
    atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
    if(h->type==DW2_PROBE)dispatch_async(v2q,^{NSData *reply=v2Probe();v2Send(c,DW2_PROBE,seq,reply.bytes,reply.length);});
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
static BOOL v2LoadJournal(void) {
    // A staging file left by an instance that died between writing and renaming it
    // would refuse every later write (it is opened exclusively). It was never the
    // journal; a directory in its place is left alone.
    unlinkat(directoryFD,"v2-journal.next",0);
    int fd=openat(directoryFD,"v2-journal.json",O_RDONLY|O_NOFOLLOW);
    if(fd<0)return errno==ENOENT;
    NSMutableData *data=[NSMutableData data];char chunk[4096];ssize_t n;
    while((n=read(fd,chunk,sizeof(chunk)))>0 && data.length<=4*1024*1024)[data appendBytes:chunk length:n];
    close(fd);
    NSDictionary *journal=n==0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if(![journal isKindOfClass:NSDictionary.class] || ![journal[@"v"] isEqual:@2] || !isNumber(journal[@"generation"]) || ![journal[@"windows"] isKindOfClass:NSArray.class] || [journal[@"windows"] count]>DW2_MAX_TABLE)return NO;
    NSMutableDictionary *loaded=[NSMutableDictionary dictionary];
    for(NSDictionary *w in journal[@"windows"]) {
        if(![w isKindOfClass:NSDictionary.class])return NO;
        for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid",@"owner"])if(!isNumber(w[key]))return NO;
        NSArray *t=w[@"transform"],*b=w[@"bounds"];
        if(![t isKindOfClass:NSArray.class] || t.count!=6 || ![b isKindOfClass:NSArray.class] || b.count!=4)return NO;
        for(id value in [t arrayByAddingObjectsFromArray:b])if(!isNumber(value))return NO;
        DW2Entry *e=[DW2Entry new];
        e->who=(struct dw2_identity){.pid=[w[@"pid"] intValue],.wid=[w[@"wid"] unsignedIntValue],.birth_sec=[w[@"birth_sec"] unsignedLongLongValue],.birth_usec=[w[@"birth_usec"] unsignedLongLongValue]};
        e->owner=[w[@"owner"] intValue];e->state=DW2_RESTORING;
        e->transform=CGAffineTransformMake([t[0] doubleValue],[t[1] doubleValue],[t[2] doubleValue],[t[3] doubleValue],[t[4] doubleValue],[t[5] doubleValue]);
        e->bounds=CGRectMake([b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue],[b[3] doubleValue]);
        if(!finiteMatrix(e->transform))return NO;
        if(isNumber(w[@"alpha"])){e->alpha=[w[@"alpha"] floatValue];e->hasAlpha=YES;}
        e->alphaTouched=e->hasAlpha && setAlpha && getAlpha && [w[@"alpha_touched"] isEqual:@YES];
        loaded[@(e->who.wid)]=e;
    }
    v2Generation=[journal[@"generation"] unsignedLongLongValue];
    if(loaded.count && !protocolClaim(2))return NO;
    [v2Table addEntriesFromDictionary:loaded];
    if(loaded.count)v2Restore(@"startup recovery",NO,nil,NULL);
    return YES;
}
// Started after v1's listener is up; a failure here leaves v1 serving as before.
static int v2Start(const char *directory,BOOL onMain) {
    v2OnMain=onMain;
    v2q=onMain ? dispatch_get_main_queue() : dispatch_queue_create("dw.v2",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    v2Table=[NSMutableDictionary dictionary];
    // Recovery finishes its first pass before anyone can connect. This runs on the
    // main thread, so with the main queue chosen the pass is made in place.
    __block BOOL loaded=NO;
    if(onMain)loaded=v2LoadJournal();
    else dispatch_sync(v2q,^{loaded=v2LoadJournal();});
    if(!loaded)return -__LINE__;
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/" DW2_SOCKET,directory)>=(int)sizeof(addr.sun_path))return -__LINE__;
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0 || bind(listener,(struct sockaddr *)&addr,sizeof(addr)) || chmod(addr.sun_path,0600) || listen(listener,DW2_MAX_CONNECTIONS)){if(listener>=0)close(listener);return -__LINE__;}
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
