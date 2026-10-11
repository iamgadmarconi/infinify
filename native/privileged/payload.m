// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation. Private ABI declarations cross-checked against
// yabai dd845723416f5fe92af49fad5ebab00369e07edd src/osax/payload.m.
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
#import <mach/mach_time.h>
#import <os/lock.h>
#import "protocol.h"
#import "protocol2.h"
#include <limits.h>

static int (*mainConnection)(void);
static CGError (*getOwner)(int, uint32_t, int *);
static CGError (*getTransform)(int, uint32_t, CGAffineTransform *);
static CGError (*setTransform)(int, uint32_t, CGAffineTransform);
static CGError (*getBounds)(int, uint32_t, CGRect *);
static CGError (*getScreenRect)(int, uint32_t, CGRect *);
// Optional, used by protocol v2 only. Signatures as declared by yabai (MIT),
// https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h lines 16, 17 and 79; resolved by dlsym like the six above.
static CGError (*getAlpha)(int, uint32_t, float *);
static CGError (*setAlpha)(int, uint32_t, float);
static CGError (*connectionPID)(int, pid_t *);
static NSDictionary *enrolled;
static NSString *secret;
// Optional spike allowlist of {pid,birth_sec,birth_usec}. When present the payload
// refuses to enroll or keep any window whose process is not listed, so a loaded
// Dock helper can be pinned to a single disposable fixture whatever a client sends.
static NSArray *allowlist;
static int directoryFD = -1;
static CGAffineTransform original;
static BOOL hasSnapshot = NO, dirty = NO, recoveryBlocked = NO;
static BOOL started = NO, fixtureOnly = YES, fixtureNativeFamilies = NO;
// Native restoration and durable receipt completion are separate obligations.
static NSDictionary *pendingRestoreReceipt;
static BOOL recoveryRetryScheduled = NO;
static unsigned recoveryRetryDelayMS = 250;
static NSDictionary *restore(NSString *reason);
// One protocol holds windows at a time, so v1's main queue and v2's own queue never
// both change a window. 1 is v1, 2 is v2; v1 is unaffected while v2 holds nothing.
static os_unfair_lock protocolLock=OS_UNFAIR_LOCK_INIT;
static int protocolHolder;
static BOOL protocolClaim(int protocol) {
    os_unfair_lock_lock(&protocolLock);
    BOOL held=protocolHolder==0 || protocolHolder==protocol;
    if(held)protocolHolder=protocol;
    os_unfair_lock_unlock(&protocolLock);
    return held;
}
static void protocolRelease(int protocol) {
    os_unfair_lock_lock(&protocolLock);
    if(protocolHolder==protocol)protocolHolder=0;
    os_unfair_lock_unlock(&protocolLock);
}
static void scheduleRecoveryRetry(void) {
    if(recoveryRetryScheduled)return;
    recoveryRetryScheduled=YES;
    unsigned delay=recoveryRetryDelayMS;
    recoveryRetryDelayMS=MIN(recoveryRetryDelayMS*2,2000U);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        recoveryRetryScheduled=NO;
        if(!recoveryBlocked)return;
        NSDictionary *result=restore(@"automatic retry");
        NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        fprintf(stderr,"RECOVERY_RETRY %s\n",data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "serialization failed");
    });
}

static NSArray *matrix(CGAffineTransform t) { return @[@(t.a),@(t.b),@(t.c),@(t.d),@(t.tx),@(t.ty)]; }
static NSDictionary *failure(NSString *reason) { return @{@"v": @1, @"ok": @NO, @"error": reason}; }
static BOOL finiteMatrix(CGAffineTransform t) {
    const double m[] = {t.a,t.b,t.c,t.d,t.tx,t.ty};
    for (int i=0;i<6;i++) if (!isfinite(m[i]) || fabs(m[i]) > 1000000) return NO;
    double determinant=t.a*t.d-t.b*t.c;
    return isfinite(determinant) && fabs(determinant) >= 1e-8;
}
static NSDictionary *identity(uint32_t wid) {
    int owner=0, pid=0;
    int ownerStatus=getOwner(mainConnection(),wid,&owner);
    if (ownerStatus) {fprintf(stderr,"identity: owner status %d for wid %u cid %d\n",ownerStatus,wid,mainConnection());return nil;}
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    if (!rows) return nil;
    for (NSDictionary *w in (__bridge NSArray *)rows) {
        if ([w[(id)kCGWindowNumber] unsignedIntValue]==wid) { pid=[w[(id)kCGWindowOwnerPID] intValue]; break; }
    }
    CFRelease(rows);
    struct proc_bsdinfo b={0};
    if (pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)) {fprintf(stderr,"identity: process lookup failed for wid %u pid %d\n",wid,pid);return nil;}
    if(b.pbi_uid!=getuid())return nil;
    return @{@"pid": @(pid), @"birth_sec": @(b.pbi_start_tvsec), @"birth_usec": @(b.pbi_start_tvusec), @"wid": @(wid), @"owner": @(owner)};
}
static BOOL validIdentity(void) { return enrolled && [enrolled isEqual:identity([enrolled[@"wid"] unsignedIntValue])]; }
static NSDictionary *readback(void) {
    if(!enrolled)return @{@"readback_ok":@NO};
    CGAffineTransform t=CGAffineTransformIdentity; CGRect r=CGRectZero, b=CGRectZero;
    int ts=getTransform(mainConnection(),[enrolled[@"wid"] unsignedIntValue],&t);
    int bs=getBounds(mainConnection(),[enrolled[@"wid"] unsignedIntValue],&b);
    int rs=getScreenRect(mainConnection(),[enrolled[@"wid"] unsignedIntValue],&r);
    BOOL finite=finiteMatrix(t) && isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height) && isfinite(b.origin.x) && isfinite(b.origin.y) && isfinite(b.size.width) && isfinite(b.size.height);
    if (ts || rs || bs || !finite) return @{@"readback_ok": @NO, @"transform_status": @(ts), @"screen_rect_status": @(rs), @"bounds_status": @(bs)};
    return @{@"readback_ok": @YES, @"matrix": matrix(t), @"bounds": @[@(b.origin.x),@(b.origin.y),@(b.size.width),@(b.size.height)], @"screen_rect": @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]};
}
static BOOL writeAll(int fd, const void *bytes, size_t count) {
    const char *p=bytes;
    while (count) { ssize_t n=write(fd,p,count); if (n<0 && errno==EINTR) continue; if(n<=0)return NO; p+=n;count-=n; }
    return YES;
}
// Open relative to retained directory FD, never follow a replacement file symlink.
// fsync the file and directory before mutation: recovery.json is intentionally retained.
static BOOL persist(NSDictionary *receipt) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data) return NO;
    int fd=openat(directoryFD,"recovery.next",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return NO;
    BOOL ok=writeAll(fd,data.bytes,data.length) && fsync(fd)==0;
    if(close(fd))ok=NO;
    if(ok)ok=renameat(directoryFD,"recovery.next",directoryFD,"recovery.json")==0 && fsync(directoryFD)==0;
    if(!ok)unlinkat(directoryFD,"recovery.next",0);
    return ok;
}
static NSDictionary *restore(NSString *reason) {
    if(!dirty && !pendingRestoreReceipt && !recoveryBlocked) {protocolRelease(1);return @{@"v":@1,@"ok":@YES,@"restored":@YES,@"reason":reason,@"readback":readback()};}
    if(!validIdentity()) {
        recoveryBlocked=YES;scheduleRecoveryRetry();
        return failure(@"identity changed; original target cannot safely be restored");
    }
    // A receipt failure must not lose the successful native readback. Revalidate
    // identity and read back again on retry, but do not set a clean native matrix.
    NSDictionary *actual=readback();
    int status=pendingRestoreReceipt ? [pendingRestoreReceipt[@"set_status"] intValue] : 0;
    if(dirty || ![actual[@"readback_ok"] boolValue] || ![actual[@"matrix"] isEqual:matrix(original)]) {
        status=setTransform(mainConnection(),[enrolled[@"wid"] unsignedIntValue],original);
        actual=readback();
    }
    BOOL restored=status==0 && [actual[@"readback_ok"] boolValue] && [actual[@"matrix"] isEqual:matrix(original)];
    NSDictionary *receipt=@{@"v":@1,@"ok":@(restored),@"restored":@(restored),@"reason":reason,@"identity":enrolled,@"original":matrix(original),@"set_status":@(status),@"readback":actual};
    // Keep this pending until its exact successful restoration can be committed.
    pendingRestoreReceipt=receipt;
    BOOL saved=persist(pendingRestoreReceipt);
    dirty=!restored;
    if(saved)pendingRestoreReceipt=nil;
    recoveryBlocked=!restored || !saved;
    if(recoveryBlocked)scheduleRecoveryRetry();
    else {recoveryRetryDelayMS=250;protocolRelease(1);}
    NSMutableDictionary *response=[receipt mutableCopy]; response[@"recovery_persisted"]=@(saved);
    if(!saved) {response[@"ok"]=@NO;response[@"error"]=@"restoration readback obtained but receipt persistence failed";}
    return response;
}
static BOOL isNumber(id n) { return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID(); }
// Match on process pid and birth only: a window number is reused across processes,
// so scope follows the enrolled process, not the numeric window id.
static BOOL allowlistPermits(NSDictionary *who) {
    if(!allowlist)return YES;
    for(NSDictionary *entry in allowlist)
        if([entry[@"pid"] isEqual:who[@"pid"]] && [entry[@"birth_sec"] isEqual:who[@"birth_sec"]] && [entry[@"birth_usec"] isEqual:who[@"birth_usec"]])return YES;
    return NO;
}
static NSArray *validAllowlist(id raw) {
    if(![raw isKindOfClass:NSArray.class] || [raw count]==0 || [raw count]>DW2_MAX_PROCESSES)return nil;
    NSMutableSet *pids=[NSMutableSet set];
    for(id entry in raw) {
        if(![entry isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:[entry allKeys]] isEqual:[NSSet setWithArray:@[@"pid",@"birth_sec",@"birth_usec"]]])return nil;
        for(id key in (NSDictionary *)entry){id n=((NSDictionary *)entry)[key];if(!isNumber(n) || CFNumberIsFloatType((__bridge CFNumberRef)n))return nil;}
        int64_t pid=[entry[@"pid"]longLongValue],seconds=[entry[@"birth_sec"]longLongValue],microseconds=[entry[@"birth_usec"]longLongValue];
        if(pid<=0 || pid>INT_MAX || seconds<=0 || microseconds<0 || microseconds>=1000000 || [pids containsObject:entry[@"pid"]])return nil;
        [pids addObject:entry[@"pid"]];
    }
    return raw;
}
static NSDictionary *handle(NSDictionary *request) {
    if (![request isKindOfClass:NSDictionary.class] || !isNumber(request[@"v"]) || ![request[@"v"] isEqual:@1]) return failure(@"unsupported protocol version");
    if (![request[@"nonce"] isKindOfClass:NSString.class] || ![request[@"nonce"] isEqual:secret]) return failure(@"authentication failed");
    NSString *op=request[@"op"];
    if (![op isKindOfClass:NSString.class])return failure(@"invalid operation");
    NSSet *expected=[NSSet setWithArray:[op isEqual:@"transform"] ? @[@"v",@"nonce",@"op",@"identity",@"matrix"] : [op isEqual:@"enroll"] ? @[@"v",@"nonce",@"op",@"identity"] : @[@"v",@"nonce",@"op"]];
    if (![[NSSet setWithArray:request.allKeys] isEqual:expected])return failure(@"invalid request fields");
    if([op isEqual:@"enroll"]) {
        if(dirty || recoveryBlocked)return failure(@"restore current enrollment before replacing it");
        NSDictionary *candidate=request[@"identity"];
        if(![candidate isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:candidate.allKeys] isEqual:[NSSet setWithArray:@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"owner"]]])return failure(@"invalid enrollment identity");
        for(id key in candidate)if(!isNumber(candidate[key]))return failure(@"invalid identity numbers");
        // Refuse before resolving or touching anything the scope does not cover.
        if(!allowlistPermits(candidate))return failure(@"allowlist scope violation");
        if(fixtureOnly && ![candidate isEqual:enrolled])return failure(@"fixture scope violation");
        NSDictionary *actual=identity([candidate[@"wid"] unsignedIntValue]);
        struct proc_bsdinfo b={0};
        int pid=[candidate[@"pid"] intValue];
        if(![actual isEqual:candidate] || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b) || b.pbi_uid!=getuid())return failure(@"enrollment identity or owner UID mismatch");
        if(!protocolClaim(1))return failure(@"protocol v2 holds windows");
        CGAffineTransform snapshot;
        if(getTransform(mainConnection(),[candidate[@"wid"] unsignedIntValue],&snapshot) || !finiteMatrix(snapshot))return failure(@"cannot snapshot enrollment");
        if(!persist(@{@"v":@1,@"state":@"enrolled",@"restored":@YES,@"identity":candidate,@"original":matrix(snapshot)}))return failure(@"cannot persist enrollment");
        enrolled=[candidate copy];original=snapshot;hasSnapshot=YES;
        return @{@"v":@1,@"ok":@YES,@"identity":enrolled,@"readback":readback()};
    }
    if(enrolled && !validIdentity())return failure(@"enrolled window identity changed");
    if([op isEqual:@"probe"] || [op isEqual:@"heartbeat"]) {
        NSString *scope=fixtureOnly ? @"cooperative fixture only" : allowlist ? [NSString stringWithFormat:@"spike allowlist: %lu window(s) only",(unsigned long)allowlist.count] : @"explicit same-UID enrollment";
        return @{@"v":@1,@"ok":@YES,@"identity":enrolled ?: (id)NSNull.null,@"dirty":@(dirty),@"lease_ms":@(DW_LEASE_MS),@"readback":readback(),@"scope":scope};
    }
    if([op isEqual:@"restore"])return restore(@"explicit");
    if(![op isEqual:@"transform"])return failure(@"unknown operation");
    if(!enrolled)return failure(@"explicit enrollment required");
    if(recoveryBlocked)return failure(@"recovery unresolved; mutation disabled");
    // validIdentity() above already re-resolved this window's identity from the window
    // server and proved it still equals the enrolled process; since the allowlist is
    // immutable and the enrolled pid/birth are fixed, that keeps the window in scope.
    // This guard restates the allowlist invariant explicitly before every mutation.
    if(!allowlistPermits(enrolled))return failure(@"enrolled window left allowlist scope");
    if(![enrolled isEqual:request[@"identity"]])return failure(@"identity mismatch");
    NSArray *m=request[@"matrix"];
    if(![m isKindOfClass:NSArray.class] || m.count!=6)return failure(@"matrix must have six numbers");
    for(id n in m)if(!isNumber(n))return failure(@"matrix must contain numbers");
    CGAffineTransform requested=CGAffineTransformMake([m[0] doubleValue],[m[1] doubleValue],[m[2] doubleValue],[m[3] doubleValue],[m[4] doubleValue],[m[5] doubleValue]);
    if(!finiteMatrix(requested))return failure(@"matrix nonfinite, singular, or exceeds bound");
    if(!protocolClaim(1))return failure(@"protocol v2 holds windows");
    if(!hasSnapshot) {
        if(getTransform(mainConnection(),[enrolled[@"wid"] unsignedIntValue],&original) || !finiteMatrix(original))return failure(@"original readback failed");
        hasSnapshot=YES;
    }
    if(!persist(@{@"v":@1,@"state":@"pending",@"identity":enrolled,@"original":matrix(original),@"requested":matrix(requested),@"server_pid":@(getpid())})) return failure(@"cannot persist recovery before mutation");
    dirty=YES;
    int status=setTransform(mainConnection(),[enrolled[@"wid"] unsignedIntValue],requested);
    NSDictionary *actual=readback();
    BOOL matched=status==0 && [actual[@"readback_ok"] boolValue] && [actual[@"matrix"] isEqual:matrix(requested)];
    return @{@"v":@1,@"ok":@(matched),@"set_status":@(status),@"readback_matches_requested":@(matched),@"readback":actual,@"recovery_persisted":@YES};
}
static double nowMS(void) { return NSProcessInfo.processInfo.systemUptime*1000; }
static void serve(int fd) {
    uid_t uid; gid_t gid;
    if(getpeereid(fd,&uid,&gid) || uid!=getuid()) {close(fd);return;}
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    struct timeval sendTimeout={.tv_sec=1};setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&sendTimeout,sizeof(sendTimeout));
    char packet[DW_MAX_PACKET];size_t used=0;
    double deadline=nowMS()+DW_LEASE_MS;
    NSString *reason=@"disconnect";
    while(YES) {
        int remaining=(int)(deadline-nowMS());
        if(remaining<=0){reason=@"lease expired";break;}
        struct pollfd p={.fd=fd,.events=POLLIN};
        int ready=poll(&p,1,remaining);
        if(ready<0 && errno==EINTR)continue;
        if(ready<=0){reason=@"lease expired";break;}
        char c;ssize_t n=read(fd,&c,1);
        if(n<=0)break;
        if(c!='\n') {
            if(used==sizeof(packet)){reason=@"oversize packet";break;}
            packet[used++]=c;continue;
        }
        @autoreleasepool {
            NSData *data=[NSData dataWithBytes:packet length:used]; used=0;
            id request=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            __block NSDictionary *response;
            dispatch_sync(dispatch_get_main_queue(),^{response=handle(request);});
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
            if(!encoded || !writeAll(fd,encoded.bytes,encoded.length) || !writeAll(fd,"\n",1))break;
            if(![response[@"ok"] boolValue]){reason=@"rejected request";break;}
            deadline=nowMS()+DW_LEASE_MS;
        }
    }
    dispatch_sync(dispatch_get_main_queue(),^{
        NSDictionary *result=restore(reason);
        NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        fprintf(stderr,"RESTORE %s\n",data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "serialization failed");
    });
    close(fd);
}
#import "payload-v2.m"
static int startServer(const char *directory, const char *nonce, const uint32_t *wids, uint32_t count, BOOL fixture, NSArray *allow, BOOL v2Main) {
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
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LOCAL|RTLD_NOW);
    if(!sky)return -__LINE__;
    mainConnection=dlsym(sky,"SLSMainConnectionID");getOwner=dlsym(sky,"SLSGetWindowOwner");
    getTransform=dlsym(sky,"SLSGetWindowTransform");setTransform=dlsym(sky,"SLSSetWindowTransform");getScreenRect=dlsym(sky,"SLSGetScreenRectForWindow");getBounds=dlsym(sky,"SLSGetWindowBounds");
    if(!mainConnection||!getOwner||!getTransform||!setTransform||!getScreenRect||!getBounds)return -__LINE__;
    getAlpha=dlsym(sky,"SLSGetWindowAlpha");setAlpha=dlsym(sky,"SLSSetWindowAlpha");connectionPID=dlsym(sky,"SLSConnectionGetPID");
    // v1's one window is the first; v2 may name any of them.
    if(fixture){enrolled=identity(wids[0]);
        if(!enrolled || [enrolled[@"pid"] intValue]!=getpid())return -__LINE__;
        fixtureCount=0;
        for(uint32_t i=0;i<count;i++) { NSDictionary *own=identity(wids[i]);
            if(!own || [own[@"pid"] intValue]!=getpid())return -__LINE__;
            fixtureWids[fixtureCount++]=wids[i]; }
    }
    struct stat st;
    directoryFD=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if(directoryFD<0)return -__LINE__;
    if(fstat(directoryFD,&st) || st.st_uid!=getuid() || (st.st_mode&0777)!=0700){close(directoryFD);directoryFD=-1;return -__LINE__;}
    // Never overwrite a stale recovery journal: a fresh fixture gets a fresh directory.
    if(faccessat(directoryFD,"recovery.json",F_OK,AT_SYMLINK_NOFOLLOW)==0){close(directoryFD);directoryFD=-1;return -__LINE__;}
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if(snprintf(path,sizeof(path),"%s/helper.sock",directory)>=(int)sizeof(path)){close(directoryFD);directoryFD=-1;return -__LINE__;}
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    struct sockaddr_un addr={.sun_family=AF_UNIX};strlcpy(addr.sun_path,path,sizeof(addr.sun_path));
    if(listener<0 || bind(listener,(struct sockaddr *)&addr,sizeof(addr)) || chmod(path,0600) || listen(listener,4)) {if(listener>=0)close(listener);close(directoryFD);directoryFD=-1;return -__LINE__;}
    secret=[NSString stringWithUTF8String:nonce];started=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        for(;;) { int client=accept(listener,NULL,NULL);if(client<0){if(errno==EINTR)continue;break;} @autoreleasepool {serve(client);} }
        close(listener);
    });
    int v2=v2Start(directory,v2Main);
    if(v2)NSLog(@"DriftWM transform helper: protocol v2 not started (%d); v1 only",v2);
    return 0;
}

static int startFixture(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON,int v2OnMainQueue,BOOL families) {
    NSArray *allow=nil;
    if(allowlistJSON) {
        id raw=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:allowlistJSON length:strlen(allowlistJSON)] options:0 error:NULL];
        allow=validAllowlist(raw);
        if(!allow)return -__LINE__;
    }
    if(started)return -__LINE__;fixtureNativeFamilies=families;
    return startServer(directory,nonce,wids,count,YES,allow,v2OnMainQueue<0 ? DW_V2_MAIN_QUEUE : v2OnMainQueue!=0);
}
int dw_privileged_fixture_start_windows(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON,int v2OnMainQueue) {
    return startFixture(directory,nonce,wids,count,allowlistJSON,v2OnMainQueue,NO);
}
int dw_privileged_fixture_start_family_windows(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON,int v2OnMainQueue) {
    return startFixture(directory,nonce,wids,count,allowlistJSON,v2OnMainQueue,YES);
}
int dw_privileged_fixture_start(const char *directory,const char *nonce,uint32_t wid,const char *allowlistJSON) {
    return dw_privileged_fixture_start_windows(directory,nonce,&wid,1,allowlistJSON,-1);
}
// Loader writes this explicit opt-in sidecar before dlopen. No sidecar means no
// listener and no mutation. Production configuration is never inferred from env.
__attribute__((constructor)) static void productionStart(void) {
    if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.dock"])return;
    Dl_info info={0};if(!dladdr((void *)&productionStart,&info)||!info.dli_fname)return;
    NSString *path=[[NSString stringWithUTF8String:info.dli_fname] stringByAppendingString:@".json"];
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0)return;
    struct stat st;char buffer[DW_MAX_PACKET];
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0600||st.st_size<=0||st.st_size>=DW_MAX_PACKET){close(fd);return;}
    ssize_t count=read(fd,buffer,sizeof(buffer));close(fd);if(count!=st.st_size)return;
    id config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:count] options:0 error:NULL];
    if(![config isKindOfClass:NSDictionary.class] || ![config[@"runtime"] isKindOfClass:NSString.class] || ![config[@"nonce"] isKindOfClass:NSString.class])return;
    // An optional spike allowlist pins the helper to the disposable fixture.
    NSArray *allow=nil;
    if(config[@"allowlist"]) {
        // A present allowlist key must be a valid allowlist. A null or malformed value
        // fails closed rather than silently granting open same-UID scope.
        allow=validAllowlist(config[@"allowlist"]);
        if(!allow){NSLog(@"DriftWM transform helper: sidecar allowlist present but invalid; refusing to start");return;}
    }
    // Optional: which queue v2's native calls run on. Absent means the build's default.
    BOOL v2Main=DW_V2_MAIN_QUEUE;
    if(config[@"v2_queue"]) {
        if([config[@"v2_queue"] isEqual:@"main"])v2Main=YES;
        else if([config[@"v2_queue"] isEqual:@"own"])v2Main=NO;
        else {NSLog(@"DriftWM transform helper: sidecar v2_queue present but invalid; refusing to start");return;}
    }
    dispatch_async(dispatch_get_main_queue(),^{
        int status=startServer([config[@"runtime"] fileSystemRepresentation],[config[@"nonce"] UTF8String],NULL,0,NO,allow,v2Main);
        NSLog(@"DriftWM transform helper start status %d; explicit enrollment required",status);
    });
}
