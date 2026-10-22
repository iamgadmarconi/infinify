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
#import <sys/sysctl.h>
#import <CommonCrypto/CommonDigest.h>
#import "protocol.h"
#import "protocol2.h"
#include <limits.h>

static int (*mainConnection)(void);
static CGError (*getOwner)(int, uint32_t, int *);
static CGError (*getTransform)(int, uint32_t, CGAffineTransform *);
static CGError (*setTransform)(int, uint32_t, CGAffineTransform);
static CGError (*getBounds)(int, uint32_t, CGRect *);
static CGError (*getScreenRect)(int, uint32_t, CGRect *);
// Optional alpha operations. Signatures as declared by yabai (MIT),
// https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h lines 16, 17 and 79; resolved by dlsym like the six above.
static CGError (*getAlpha)(int, uint32_t, float *);
static CGError (*setAlpha)(int, uint32_t, float);
static CGError (*connectionPID)(int, pid_t *);
// Optional Space membership operations. Same pinned yabai commit, extern.h
// 22,40,42,54,56,63 and osax/payload.m:905-929. The move returns void;
// only fresh membership readback can establish that a request was applied.
static CFArrayRef (*copyWindowSpaces)(int,int,CFArrayRef);
static CFStringRef (*copySpaceDisplay)(int,uint64_t);
static uint64_t (*displayCurrentSpace)(int,CFStringRef);
static int (*getSpaceType)(int,uint64_t);
static void (*moveWindowsToSpace)(int,CFArrayRef,uint64_t);
static CFUUIDRef (*createDisplayUUID)(CGDirectDisplayID);
static NSDictionary *fixtureIdentity;
static NSString *secret;
static NSArray *allowlist;
static int directoryFD=-1;
static BOOL started=NO,fixtureOnly=YES,fixtureNativeFamilies=NO;
#define DW_SIDECAR_MAX_BYTES 4096

static NSArray *matrix(CGAffineTransform t) { return @[@(t.a),@(t.b),@(t.c),@(t.d),@(t.tx),@(t.ty)]; }
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
static BOOL writeAll(int fd, const void *bytes, size_t count) {
    const char *p=bytes;
    while (count) { ssize_t n=write(fd,p,count); if (n<0 && errno==EINTR) continue; if(n<=0)return NO; p+=n;count-=n; }
    return YES;
}
static BOOL isNumber(id n) { return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID(); }
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
static double nowMS(void) { return NSProcessInfo.processInfo.systemUptime*1000; }
#import "payload-v2.m"
static int startServer(const char *directory, const char *nonce, const uint32_t *wids, uint32_t count, BOOL fixture, NSArray *allow, BOOL v2Main,NSDictionary *recovery) {
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
    // Legacy recovery has no v2 replay contract. Preserve it byte-for-byte and
    // refuse this runtime rather than erasing an unknown restoration obligation.
    for(const char **name=(const char *[]){"recovery.json","recovery.next","helper.sock",DW2_SOCKET,NULL};*name;name++) {
        if(fstatat(directoryFD,*name,&st,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT){close(directoryFD);directoryFD=-1;return -__LINE__;}
    }
    secret=[NSString stringWithUTF8String:nonce];
    int status=v2Start(directory,v2Main,recovery);
    if(status){close(directoryFD);directoryFD=-1;return status;}
    started=YES;
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
    return startServer(directory,nonce,wids,count,YES,allow,v2OnMainQueue<0 ? DW_V2_MAIN_QUEUE : v2OnMainQueue!=0,nil);
}
int dw_privileged_fixture_start_windows(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON,int v2OnMainQueue) {
    return startFixture(directory,nonce,wids,count,allowlistJSON,v2OnMainQueue,NO);
}
int dw_privileged_fixture_start_family_windows(const char *directory,const char *nonce,const uint32_t *wids,uint32_t count,const char *allowlistJSON,int v2OnMainQueue) {
    return startFixture(directory,nonce,wids,count,allowlistJSON,v2OnMainQueue,YES);
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
    // Optional: which queue v2's native calls run on. Absent means the build's default.
    BOOL v2Main=DW_V2_MAIN_QUEUE;
    if(config[@"v2_queue"]) {
        if([config[@"v2_queue"] isEqual:@"main"])v2Main=YES;
        else if([config[@"v2_queue"] isEqual:@"own"])v2Main=NO;
        else {NSLog(@"DriftWM transform helper: sidecar v2_queue present but invalid; refusing to start");return;}
    }
    dispatch_async(dispatch_get_main_queue(),^{
        int status=startServer([config[@"runtime"] fileSystemRepresentation],[config[@"nonce"] UTF8String],NULL,0,NO,allow,v2Main,config[@"recovery_source_sha256"] ? config : nil);
        NSLog(@"DriftWM transform helper start status %d; explicit enrollment required",status);
    });
}
