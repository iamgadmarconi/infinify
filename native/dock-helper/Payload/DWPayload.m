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
// The Dock helper payload, one translation unit. This file holds the protocol v2 server (the enrollment, inspect and probe replies,
// the transport, sessions and their end), the listener, startup, the fixture entry points and the production constructor; the
// fragments it #imports below hold the rest. Every line of code here and in them is moved verbatim from native/privileged/payload.m
// (37b27b1), #import paths aside, except that startServer also resolves getLayer and setLayer (the placement-1 layer originals). scripts/build-privileged.sh compiles only this file, and the regression tests #import it after
// their native call substitutes: the same single translation unit in both.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <libproc.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <poll.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <CommonCrypto/CommonDigest.h>
#import "DWHelperProtocol.h"
#include <limits.h>

// The rest of the helper, textually and in this order: each fragment uses only what the files before it define.
#import "DWPayloadState.m"
#import "DWPayloadIdentity.m"
#import "DWPayloadJournal.m"
#import "DWPayloadSpace.m"
#import "DWPayloadRestore.m"
#import "DWPayloadFrames.m"
#import "DWPayloadArrival.m"
#import "DWPayloadMove.m"

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
        .queue=DW2_QUEUE_OWN,.lease_ms=DW2_LEASE_MS,.server_pid=getpid(),.held=atomic_load(&v2Held),.restoring=atomic_load(&v2Restoring),.journal_pending=v2JournalStale,
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
    uint16_t type=v2SlotType;
    struct dw2_frame_reply head={.disposition=DW2_FRAME_APPLIED,.superseded=v2SupersededPending};
    if(frame){v2Slot=nil;v2SlotOwner=nil;v2SupersededPending=0;}
    pthread_mutex_unlock(&v2Lock);
    if(!frame)return;
    BOOL spaces=type==DW2_FRAME_SPACE;
    head.count=(uint32_t)(frame.length/(spaces?sizeof(struct dw2_space_record):sizeof(struct dw2_record)));
    NSMutableData *reply=[NSMutableData dataWithLength:sizeof(head)+head.count];
    if(spaces){
        NSMutableData *base=[NSMutableData dataWithLength:head.count*sizeof(struct dw2_record)];
        NSMutableData *targets=[NSMutableData dataWithLength:head.count*sizeof(uint64_t)];
        const struct dw2_space_record *extended=frame.bytes;
        for(uint32_t i=0;i<head.count;i++){((struct dw2_record *)base.mutableBytes)[i]=extended[i].record;((uint64_t *)targets.mutableBytes)[i]=extended[i].target_space;}
        v2ApplyWithSpaces(base.bytes,targets.bytes,head.count,(uint8_t *)reply.mutableBytes+sizeof(head));
    }else v2Apply(frame.bytes,head.count,(uint8_t *)reply.mutableBytes+sizeof(head));
    head.frames_applied=atomic_fetch_add(&v2FramesApplied,1)+1;
    memcpy(reply.mutableBytes,&head,sizeof(head));
    v2Send(c,type,seq,reply.bytes,reply.length);
}
// Called with v2Lock held. The frame in the slot will never be applied.
static BOOL v2Discard(uint64_t *seq,uint32_t *superseded,uint16_t *type) {
    BOOL had=v2Slot!=nil;
    *seq=v2SlotSeq;*superseded=v2SupersededPending;if(type)*type=v2SlotType;
    v2Slot=nil;v2SlotOwner=nil;v2SupersededPending=0;v2Barrier++;
    if(had)atomic_fetch_add(&v2FramesSuperseded,1);
    return had;
}
static void v2SendDropped(DW2Connection *c,uint64_t seq,uint32_t superseded,uint16_t type) {
    struct dw2_frame_reply head={.disposition=DW2_FRAME_DROPPED,.superseded=superseded,.frames_applied=atomic_load(&v2FramesApplied)};
    v2Send(c,type,seq,&head,sizeof(head));
}

static BOOL v2Hello(DW2Connection *c,const struct dw2_header *h,const void *body) {
    struct dw2_hello_reply reply={.status=DW2_HELLO_OK,.lease_ms=DW2_LEASE_MS,.max_records=DW2_MAX_RECORDS,.max_body=DW2_MAX_BODY,.caps=v2Caps(),
        .scope=fixtureOnly ? DW2_SCOPE_COOPERATIVE : allowlist ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER,.queue=DW2_QUEUE_OWN,.server_pid=getpid()};
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
                    // The client's own windows are never veiled; without its process there is no veil.
                    pid_t peer=0;socklen_t peerSize=sizeof(peer);
                    if(getsockopt(c->fd,SOL_LOCAL,LOCAL_PEERPID,&peer,&peerSize)||peerSize!=sizeof(peer)||peer<=1)peer=0;
                    atomic_store(&v2VeilClient,peer);
                    atomic_store(&v2VeilOn,false);
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
    if(h->type==DW2_MOVE) {
        struct dw2_move request;
        if(h->length!=sizeof(request))return NO;
        memcpy(&request,body,sizeof(request));
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        dispatch_async(v2q,^{
            // A move is a change to a held window: only for the session that holds it, checked on the queue that applies frames.
            pthread_mutex_lock(&v2Lock);BOOL live=c->session==v2Session;pthread_mutex_unlock(&v2Lock);
            struct dw2_move_reply reply={.id=request.id,.status=DW2_SCOPE};
            if(live)reply=v2Move(request.id,CGPointMake(request.origin[0],request.origin[1]));
            v2Send(c,DW2_MOVE,seq,&reply,sizeof(reply));
        });
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->type==DW2_VEIL) {
        struct dw2_veil request;
        if(h->length!=sizeof(request))return NO;
        memcpy(&request,body,sizeof(request));
        if(request.reserved || request.mode>1)return NO;
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        dispatch_async(v2q,^{
            // The session may have ended since the request was read: it then enables nothing. Checked and stored under the lock the
            // session's end takes to clear it, so no interleaving leaves the veil on for a session that is gone.
            struct dw2_veil_reply reply={.status=DW2_SCOPE,.timeout_ms=DW2_VEIL_TIMEOUT_MS};
            pthread_mutex_lock(&v2Lock);
            BOOL allowed=c->session==v2Session && (!request.mode || (v2VeilAvailable() && atomic_load(&v2VeilClient)));
            if(allowed){atomic_store(&v2VeilOn,request.mode!=0);reply.status=DW2_APPLIED;}
            pthread_mutex_unlock(&v2Lock);
            if(allowed && !request.mode)v2VeilRelease();
            v2Send(c,DW2_VEIL,seq,&reply,sizeof(reply));
        });
        pthread_mutex_unlock(&v2Lock);
        return YES;
    }
    if(h->type==DW2_FRAME||h->type==DW2_FRAME_SPACE) {
        BOOL spaces=h->type==DW2_FRAME_SPACE;
        if(spaces&&!v2SpaceAPI())return NO;
        struct dw2_frame head;
        if(h->length<sizeof(head))return NO;
        memcpy(&head,body,sizeof(head));
        size_t stride=spaces?sizeof(struct dw2_space_record):sizeof(struct dw2_record);
        if(head.reserved || head.count>DW2_MAX_RECORDS || h->length!=sizeof(head)+(size_t)head.count*stride || seq<=c->lastFrame)return NO;
        c->lastFrame=seq;
        NSData *frame=[NSData dataWithBytes:(const char *)body+sizeof(head) length:h->length-sizeof(head)];
        atomic_fetch_add(&v2FramesReceived,1);
        pthread_mutex_lock(&v2Lock);
        atomic_store(&v2Deadline,v2Now()+DW2_LEASE_MS);
        // Newest wins: a frame not yet taken is replaced, never queued behind.
        if(v2Slot){v2SupersededPending++;atomic_fetch_add(&v2FramesSuperseded,1);}
        v2Slot=frame;v2SlotSeq=seq;v2SlotOwner=c;v2SlotType=h->type;
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
        uint64_t droppedSeq;uint32_t superseded;uint16_t droppedType;
        BOOL dropped=v2Discard(&droppedSeq,&superseded,&droppedType);
        dispatch_async(v2q,^{
            if(dropped)v2SendDropped(c,droppedSeq,superseded,droppedType);
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
        v2Discard(&droppedSeq,&superseded,NULL);
        v2Beats=nil;v2Session=0;
        // No veil outlives its session: the restore queued below releases what it still holds.
        atomic_store(&v2VeilOn,false);atomic_store(&v2VeilClient,0);
        for(DW2Connection *beat in beats)if(!atomic_exchange(&beat->closed,true))shutdown(beat->fd,SHUT_RDWR);
        dispatch_async(v2q,^{v2Restore(reason,NO,nil,NULL);});
    }
    pthread_mutex_unlock(&v2Lock);
    if(!atomic_exchange(&c->closed,true))shutdown(c->fd,SHUT_RDWR);
    atomic_fetch_sub(&v2Connections,1);
    return NULL;
} }

// The listener. A failure is startup failure, never a fallback server.
static int v2Start(const char *directory,NSDictionary *recovery) {
    v2ResolveSublevels();
    v2ResolveFamily();
    v2ResolveMove();
    v2WriterIdentity=v2CurrentWriterIdentity();if(!v2WriterIdentity)return -__LINE__;
    v2q=dispatch_queue_create("dw.v2",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    v2Table=[NSMutableDictionary dictionary];v2Released=[NSMutableDictionary dictionary];
    // Announcements of new windows, for the arrival veil. Delivered on this (the main) thread, which has an
    // NSApplication in the Dock; the handler does nothing until a session asks for the veil.
    if(!fixtureOnly&&!allowlist&&v2RegisterNotify)v2VeilRegistered=v2RegisterNotify(mainConnection(),v2WindowAdded,1325,NULL)==0;
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/" DW2_SOCKET,directory)>=(int)sizeof(addr.sun_path))return -__LINE__;
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0)return -__LINE__;
    if(bind(listener,(struct sockaddr *)&addr,sizeof(addr))){close(listener);return -__LINE__;}
    if(chmod(addr.sun_path,0600) || listen(listener,DW2_MAX_CONNECTIONS)){close(listener);unlinkat(directoryFD,DW2_SOCKET,0);return -__LINE__;}
    // Recovery's first pass finishes before accepting clients. Readiness cannot
    // succeed on a malformed journal, and there is no other listener to fall back to.
    __block BOOL loaded=NO;
    dispatch_sync(v2q,^{loaded=v2LoadJournal(recovery);});
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
static int startServer(const char *directory, const char *nonce, const uint32_t *wids, uint32_t count, BOOL fixture, NSArray *allow, NSDictionary *recovery) {
    if(!NSThread.isMainThread || started || !directory || !nonce || strlen(nonce)!=64 || getuid()!=geteuid())return -__LINE__;
    for(const char *p=nonce;*p;p++)if(!((*p>='a'&&*p<='f')||(*p>='0'&&*p<='9')))return -__LINE__;
    // Explicit enrollment is restricted to a real NSWindow owned by this fixture host.
    if(fixture) {
        if(!wids || !count || count>sizeof(fixtureWids)/sizeof(*fixtureWids))return -__LINE__;
        for(uint32_t i=0;i<count;i++) { NSWindow *window=[NSApp windowWithWindowNumber:wids[i]];
            if(!window || (uint32_t)window.windowNumber!=wids[i])return -__LINE__; }
    }
    else if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.dock"])return -__LINE__;
    fixtureOnly=fixture;allowlist=allow;
    void *sky=v2Sky();
    if(!sky)return -__LINE__;
    mainConnection=dlsym(sky,"SLSMainConnectionID");getOwner=dlsym(sky,"SLSGetWindowOwner");
    skyGetPlacement=dlsym(sky,"SLSGetWindowTransformAtPlacement");skySetPlacement=dlsym(sky,"SLSSetWindowTransformAtPlacement");
    getScreenRect=dlsym(sky,"SLSGetScreenRectForWindow");getBounds=dlsym(sky,"SLSGetWindowBounds");
    // No fallback to SLSGetWindowTransform / SLSSetWindowTransform: a placement-0 write is the Dock-death corner bug.
    if(!mainConnection||!getOwner||!skyGetPlacement||!skySetPlacement||!getScreenRect||!getBounds)return -__LINE__;
    getTransform=dwReadAbsolute;setTransform=dwWriteAbsolute;getLayer=dwReadLayer;setLayer=dwWriteLayer;
    getAlpha=dlsym(sky,"SLSGetWindowAlpha");setAlpha=dlsym(sky,"SLSSetWindowAlpha");connectionPID=dlsym(sky,"SLSConnectionGetPID");
    v2RegisterNotify=dlsym(sky,"SLSRegisterConnectionNotifyProc");
    copyWindowSpaces=dlsym(sky,"SLSCopySpacesForWindows");copySpaceDisplay=dlsym(sky,"SLSCopyManagedDisplayForSpace");
    displayCurrentSpace=dlsym(sky,"SLSManagedDisplayGetCurrentSpace");getSpaceType=dlsym(sky,"SLSSpaceGetType");
    moveWindowsToSpace=dlsym(sky,"SLSMoveWindowsToManagedSpace");createDisplayUUID=dlsym(RTLD_DEFAULT,"CGDisplayCreateUUIDFromDisplayID");
    if(fixture){fixtureIdentity=identity(wids[0]);
        if(!fixtureIdentity || [fixtureIdentity[@"pid"] intValue]!=getpid())return -__LINE__;
        fixtureCount=0;
        for(uint32_t i=0;i<count;i++) { NSDictionary *own=identity(wids[i]);
            if(!own || [own[@"pid"] intValue]!=getpid())return -__LINE__;
            fixtureWids[fixtureCount++]=wids[i]; }
    }
    struct stat st;
    directoryFD=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if(directoryFD<0)return -__LINE__;
    if(fstat(directoryFD,&st) || st.st_uid!=getuid() || (st.st_mode&0777)!=0700){close(directoryFD);directoryFD=-1;return -__LINE__;}
    // A recovery file or socket from an earlier helper has no replay contract
    // here. Preserve it byte-for-byte and refuse this runtime rather than
    // erasing an unknown restoration obligation; a stale socket marks a
    // runtime another helper may still own.
    for(const char **name=(const char *[]){"recovery.json","recovery.next","helper.sock",DW2_SOCKET,NULL};*name;name++) {
        if(fstatat(directoryFD,*name,&st,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT){close(directoryFD);directoryFD=-1;return -__LINE__;}
    }
    secret=[NSString stringWithUTF8String:nonce];
    int status=v2Start(directory,recovery);
    if(status){close(directoryFD);directoryFD=-1;return status;}
    started=YES;
    return 0;
}

static int startFixture(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON,BOOL families) {
    NSArray *allow=nil;
    if(allowlistJSON) {
        id raw=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:allowlistJSON length:strlen(allowlistJSON)] options:0 error:NULL];
        allow=validAllowlist(raw);
        if(!allow)return -__LINE__;
    }
    if(started)return -__LINE__;fixtureNativeFamilies=families;
    return startServer(directory,nonce,wids,count,YES,allow,nil);
}
int dw_privileged_fixture_start_windows(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON) {
    return startFixture(directory,nonce,wids,count,allowlistJSON,NO);
}
int dw_privileged_fixture_start_family_windows(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON) {
    return startFixture(directory,nonce,wids,count,allowlistJSON,YES);
}
// Loader writes this explicit opt-in sidecar before dlopen. No sidecar means no
// listener and no mutation. Production configuration is never inferred from env.
__attribute__((constructor)) static void productionStart(void) {
    if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.dock"])return;
    Dl_info info={0};if(!dladdr((void *)&productionStart,&info)||!info.dli_fname)return;
    NSString *path=[[NSString stringWithUTF8String:info.dli_fname] stringByAppendingString:@".json"];
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);if(fd<0)return;
    struct stat st;char buffer[DW_SIDECAR_MAX_BYTES];
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0600||st.st_size<=0||st.st_size>=DW_SIDECAR_MAX_BYTES){close(fd);return;}
    ssize_t count=read(fd,buffer,sizeof(buffer));close(fd);if(count!=st.st_size)return;
    id config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:count] options:0 error:NULL];
    if(![config isKindOfClass:NSDictionary.class] || ![config[@"runtime"] isKindOfClass:NSString.class] || ![config[@"nonce"] isKindOfClass:NSString.class])return;
    if(!v2RecoveryConfigValid(config))return;
    // An optional allowlist pins the helper to explicit process instances.
    NSArray *allow=nil;
    if(config[@"allowlist"]) {
        // A present allowlist key must be a valid allowlist. A null or malformed value
        // fails closed rather than silently granting open same-UID scope.
        allow=validAllowlist(config[@"allowlist"]);
        if(!allow){NSLog(@"DriftWM transform helper: sidecar allowlist present but invalid; refusing to start");return;}
    }
    dispatch_async(dispatch_get_main_queue(),^{
        int status=startServer([config[@"runtime"] fileSystemRepresentation],[config[@"nonce"] UTF8String],NULL,0,NO,allow,config[@"recovery_source_sha256"] ? config : nil);
        NSLog(@"DriftWM transform helper start status %d; explicit enrollment required",status);
    });
}
