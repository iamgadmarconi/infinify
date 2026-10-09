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
#import "protocol.h"

static int (*mainConnection)(void);
static CGError (*getOwner)(int, uint32_t, int *);
static CGError (*getTransform)(int, uint32_t, CGAffineTransform *);
static CGError (*setTransform)(int, uint32_t, CGAffineTransform);
static CGError (*getBounds)(int, uint32_t, CGRect *);
static CGError (*getScreenRect)(int, uint32_t, CGRect *);
static NSDictionary *enrolled;
static NSString *secret;
static int directoryFD = -1;
static CGAffineTransform original;
static BOOL hasSnapshot = NO, dirty = NO, recoveryBlocked = NO;
static BOOL started = NO, fixtureOnly = YES;
// Native restoration and durable receipt completion are separate obligations.
static NSDictionary *pendingRestoreReceipt;
static BOOL recoveryRetryScheduled = NO;
static unsigned recoveryRetryDelayMS = 250;
static NSDictionary *restore(NSString *reason);
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
    if(!dirty && !pendingRestoreReceipt && !recoveryBlocked) return @{@"v":@1,@"ok":@YES,@"restored":@YES,@"reason":reason,@"readback":readback()};
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
    else recoveryRetryDelayMS=250;
    NSMutableDictionary *response=[receipt mutableCopy]; response[@"recovery_persisted"]=@(saved);
    if(!saved) {response[@"ok"]=@NO;response[@"error"]=@"restoration readback obtained but receipt persistence failed";}
    return response;
}
static BOOL isNumber(id n) { return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID(); }
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
        if(fixtureOnly && ![candidate isEqual:enrolled])return failure(@"fixture scope violation");
        NSDictionary *actual=identity([candidate[@"wid"] unsignedIntValue]);
        struct proc_bsdinfo b={0};
        int pid=[candidate[@"pid"] intValue];
        if(![actual isEqual:candidate] || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b) || b.pbi_uid!=getuid())return failure(@"enrollment identity or owner UID mismatch");
        CGAffineTransform snapshot;
        if(getTransform(mainConnection(),[candidate[@"wid"] unsignedIntValue],&snapshot) || !finiteMatrix(snapshot))return failure(@"cannot snapshot enrollment");
        if(!persist(@{@"v":@1,@"state":@"enrolled",@"restored":@YES,@"identity":candidate,@"original":matrix(snapshot)}))return failure(@"cannot persist enrollment");
        enrolled=[candidate copy];original=snapshot;hasSnapshot=YES;
        return @{@"v":@1,@"ok":@YES,@"identity":enrolled,@"readback":readback()};
    }
    if(enrolled && !validIdentity())return failure(@"enrolled window identity changed");
    if([op isEqual:@"probe"] || [op isEqual:@"heartbeat"])return @{@"v":@1,@"ok":@YES,@"identity":enrolled ?: (id)NSNull.null,@"dirty":@(dirty),@"lease_ms":@(DW_LEASE_MS),@"readback":readback(),@"scope":fixtureOnly ? @"cooperative fixture only" : @"explicit same-UID enrollment"};
    if([op isEqual:@"restore"])return restore(@"explicit");
    if(![op isEqual:@"transform"])return failure(@"unknown operation");
    if(!enrolled)return failure(@"explicit enrollment required");
    if(recoveryBlocked)return failure(@"recovery unresolved; mutation disabled");
    if(![enrolled isEqual:request[@"identity"]])return failure(@"identity mismatch");
    NSArray *m=request[@"matrix"];
    if(![m isKindOfClass:NSArray.class] || m.count!=6)return failure(@"matrix must have six numbers");
    for(id n in m)if(!isNumber(n))return failure(@"matrix must contain numbers");
    CGAffineTransform requested=CGAffineTransformMake([m[0] doubleValue],[m[1] doubleValue],[m[2] doubleValue],[m[3] doubleValue],[m[4] doubleValue],[m[5] doubleValue]);
    if(!finiteMatrix(requested))return failure(@"matrix nonfinite, singular, or exceeds bound");
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
static int startServer(const char *directory, const char *nonce, uint32_t wid, BOOL fixture) {
    if(!NSThread.isMainThread || started || !directory || !nonce || strlen(nonce)!=64 || getuid()!=geteuid())return -__LINE__;
    for(const char *p=nonce;*p;p++)if(!((*p>='a'&&*p<='f')||(*p>='0'&&*p<='9')))return -__LINE__;
    // Explicit enrollment is restricted to a real NSWindow owned by this fixture host.
    if(fixture) { NSWindow *window=[NSApp windowWithWindowNumber:wid];
        if(!window || (uint32_t)window.windowNumber!=wid)return -__LINE__; }
    else if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.dock"])return -__LINE__;
    fixtureOnly=fixture;
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LOCAL|RTLD_NOW);
    if(!sky)return -__LINE__;
    mainConnection=dlsym(sky,"SLSMainConnectionID");getOwner=dlsym(sky,"SLSGetWindowOwner");
    getTransform=dlsym(sky,"SLSGetWindowTransform");setTransform=dlsym(sky,"SLSSetWindowTransform");getScreenRect=dlsym(sky,"SLSGetScreenRectForWindow");getBounds=dlsym(sky,"SLSGetWindowBounds");
    if(!mainConnection||!getOwner||!getTransform||!setTransform||!getScreenRect||!getBounds)return -__LINE__;
    if(fixture){enrolled=identity(wid);
        if(!enrolled || [enrolled[@"pid"] intValue]!=getpid())return -__LINE__;}
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
    return 0;
}

int dw_privileged_fixture_start(const char *directory,const char *nonce,uint32_t wid) { return startServer(directory,nonce,wid,YES); }
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
    dispatch_async(dispatch_get_main_queue(),^{
        int status=startServer([config[@"runtime"] fileSystemRepresentation],[config[@"nonce"] UTF8String],0,NO);
        NSLog(@"DriftWM transform helper start status %d; explicit enrollment required",status);
    });
}
