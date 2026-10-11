// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/privileged (dwclient.h,
// protocol2.h). The two window-server queries are resolved by name, with the signatures
// native/privileged/payload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h); see
// native/families/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
#import "native-presenter.h"
#import "native-family.h"
#import "../focus/focus.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <libproc.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include "dwclient.h"

bool DWNativeBounds(uint32_t wid,CGRect *out) {
    static int (*connection)(void);static CGError (*bounds)(int,uint32_t,CGRect *);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;connection=dlsym(sky,"SLSMainConnectionID");bounds=dlsym(sky,"SLSGetWindowBounds");});
    CGRect r=CGRectZero;if(!connection||!bounds||!wid||bounds(connection(),wid,&r)!=kCGErrorSuccess)return false;
    if(!isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0)return false;
    if(out)*out=r;return true;
}

static bool DWNativeFiniteRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        &&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r));
}
bool DWNativeClipPlacement(CGRect native,CGRect rootNative,CGRect rootScreen,CGRect viewport,DWNativeClipGeometry *out) {
    if(!out||!DWNativeFiniteRect(native)||!DWNativeFiniteRect(rootNative)||!DWNativeFiniteRect(rootScreen)||!DWNativeFiniteRect(viewport))return false;
    double zx=rootScreen.size.width/rootNative.size.width,zy=rootScreen.size.height/rootNative.size.height;
    if(!isfinite(zx)||!isfinite(zy)||zx<=0||zy<=0)return false;
    CGRect screen=CGRectMake(rootScreen.origin.x+(native.origin.x-rootNative.origin.x)*zx,
        rootScreen.origin.y+(native.origin.y-rootNative.origin.y)*zy,native.size.width*zx,native.size.height*zy);
    if(!DWNativeFiniteRect(screen))return false;
    CGRect visible=CGRectIntersection(screen,viewport),local=CGRectZero;
    // A fully off-output child needs an empty local clip. Never serialize
    // CGRectNull's infinite origin as if it were a valid region.
    if(CGRectIsNull(visible)||CGRectIsEmpty(visible))visible=CGRectZero;
    else {
        double left=fmax(0,fmin(native.size.width,(CGRectGetMinX(visible)-CGRectGetMinX(screen))/zx));
        double top=fmax(0,fmin(native.size.height,(CGRectGetMinY(visible)-CGRectGetMinY(screen))/zy));
        double right=fmax(left,fmin(native.size.width,(CGRectGetMaxX(visible)-CGRectGetMinX(screen))/zx));
        double bottom=fmax(top,fmin(native.size.height,(CGRectGetMaxY(visible)-CGRectGetMinY(screen))/zy));
        local=CGRectMake(left,top,right-left,bottom-top);
    }
    *out=(DWNativeClipGeometry){.screen=screen,.visible=visible,.local=local,.required=!CGRectContainsRect(viewport,screen)};
    return true;
}
static CGRect DWNativeJSONRect(id value) {
    if(![value isKindOfClass:NSDictionary.class])return CGRectNull;
    NSDictionary *origin=value[@"origin"],*size=value[@"size"];
    if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class])return CGRectNull;
    for(id n in @[origin[@"x"]?:NSNull.null,origin[@"y"]?:NSNull.null,size[@"width"]?:NSNull.null,size[@"height"]?:NSNull.null])if(![n isKindOfClass:NSNumber.class])return CGRectNull;
    CGRect r=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);
    return DWNativeFiniteRect(r)?r:CGRectNull;
}
static NSArray *DWNativeRectArray(CGRect r) { return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; }
static NSArray<NSNumber *> *DWNativeProcessBirth(pid_t pid,uid_t uid) {
    struct proc_bsdinfo info={0};
    if(pid<=1||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=uid)return nil;
    return @[@(info.pbi_start_tvsec),@(info.pbi_start_tvusec)];
}
// Dynamic kernel-selected code, rather than a caller-supplied bundle path. The
// client independently binds HELLO and heartbeat to LOCAL_PEERPID/getpeereid.
// Public contract: Security.framework SecCode.h and Apple's requirement guide:
// https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)
// https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:)
// https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html
// "anchor apple" means Apple's own code, excluding Developer ID substitutes.
static NSArray<NSNumber *> *DWNativeDockBirth(pid_t pid,uid_t uid) {
    if(getuid()!=uid||geteuid()!=uid||pid==getpid())return nil;
    NSArray *before=DWNativeProcessBirth(pid,uid);if(!before)return nil;
    SecRequirementRef requirement=NULL;SecCodeRef code=NULL;
    OSStatus result=SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.dock\""),kSecCSDefaultFlags,&requirement);
    if(result==errSecSuccess)result=SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)@{(__bridge NSString *)kSecGuestAttributePid:@(pid)},kSecCSDefaultFlags,&code);
    if(result==errSecSuccess)result=SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement);
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);
    return result==errSecSuccess&&[before isEqual:DWNativeProcessBirth(pid,uid)]?before:nil;
}
// Kept as fixed-size geometry beside the frame, so normal presentation avoids
// allocating a dictionary per member just for read-only debug information.
typedef struct {
    struct dw2_identity identity;
    uint64_t logical,output;
    uint32_t root;
    CGRect viewport;
    DWNativeClipGeometry geometry;
} DWNativeClipRecord;

// The helper's lease clock and the library's: it stops while the machine sleeps, so a night asleep is not a hang.
static uint64_t uptime(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000000; }
// How long the main thread may stay away from its run loop before the session is closed for it.
static const uint64_t DWStall=10000;
// One bound window: who it is for the helper, its own frame, and whether an alpha was ever sent for it.
@interface DWNativeWindow : NSObject { @public struct dw2_identity identity;CGRect bounds;BOOL alpha;NSNumber *logical;uint64_t releaseSeq;uint32_t root; } @end
@implementation DWNativeWindow @end
static const char *lostName(int reason) { return reason==DW_LOST_EOF?"the helper closed the connection":reason==DW_LOST_WRITE_TIMEOUT?"the helper stopped reading":reason==DW_LOST_HEARTBEAT?"no heartbeat was answered for a whole lease":"the helper broke the protocol"; }
static const char *statusName(uint8_t status) {
    static const char *names[]={"applied","out of the helper's scope","no such window of that process","matrix refused","alpha refused","its original could not be read","the journal could not be written","the set failed or read back differently","a restore of it is pending","protocol v1 holds a window","the helper's table is full","malformed record"};
    return status<sizeof(names)/sizeof(*names)?names[status]:"unknown status";
}
@interface DWNativePresenterGroup : DWNativePresenter
@property NSArray<DWNativePresenter *> *sessions;
@property NSDictionary<NSNumber *,DWNativePresenter *> *owners;
@property BOOL groupEnded,finished;
@end
static void DWCloseNativeClient(dw_client *client) {
    if(!client)return;
    struct dw2_restore_result *results=calloc(DW2_MAX_TABLE,sizeof(*results));uint32_t count=0,pending=0;
    int result=results?dw_client_restore_all(client,2000,results,DW2_MAX_TABLE,&count,&pending):DW_CLIENT_INVALID;
    free(results);
    if(result!=DW_CLIENT_OK)fprintf(stderr,"Infinify: native restoration was not confirmed (%s); closing the session leaves restoration with the helper\n",result==DW_CLIENT_TIMEOUT?"no answer within 2 s":result==DW_CLIENT_LOST?"the helper is gone":"invalid reply");
    else if(pending)fprintf(stderr,"Infinify: %u of %u native windows still restoring; the helper keeps retrying them\n",pending,count);
    dw_client_close(client);
}
@implementation DWNativePresenter {
    // Every call into the library is made under this lock and for that call only (each is bounded: two seconds at most), and the
    // pointer is cleared under it, so the watchdog's close on its own queue never meets a call on the main thread.
    os_unfair_lock _lock;
    dw_client *_client;
    struct dw_client_info _info;
    NSDictionary<NSNumber *,NSArray<NSNumber *> *> *_scope;
    BOOL _desktopWide;
    uid_t _loginUID;
    NSArray<NSNumber *> *_dockBirth;
    _Atomic bool _preparing;
    _Atomic bool _ended;
    // When the main thread last turned its run loop or described a frame: written there, read by the watchdog.
    _Atomic uint64_t _turned;
    dispatch_source_t _watchdog;
    CFRunLoopObserverRef _observer;
    NSMutableDictionary<NSNumber *,DWNativeWindow *> *_windows; // by window number
    NSMutableDictionary<NSNumber *,DWNativeWindow *> *_releases; // originals to restore after unbinding
    NSMutableDictionary<NSNumber *,NSSet<NSNumber *> *> *_families;
    _Atomic bool _releasing;
    _Atomic bool _retrying;
    uint64_t _lastSent,_submittedSeq;
    NSMutableData *_records;                                    // the frame last described
    NSMutableData *_clips;                                      // desired geometry; never sent as a native clip
    NSData *_sent;                                              // the frame last handed over
    NSArray<NSNumber *> *_order,*_sentOrder;                    // the world window of each of their records, for -debug:
    BOOL _described,_forced;
    // The window numbers of the frames handed over, by sequence number, for a record status that comes back; and what was said of one.
    NSMutableDictionary<NSNumber *,NSData *> *_frames;
    NSMutableSet<NSString *> *_said;
}
- (BOOL)ended { return atomic_load(&_ended); }
- (BOOL)familiesNeeded { return _desktopWide||_info.scope==DW2_SCOPE_ALLOWLIST||(_info.scope==DW2_SCOPE_COOPERATIVE&&(_info.caps&DW2_CAP_FIXTURE_FAMILY)); }
// Library threads. Neither takes the lock or closes anything: they leave a note for the main thread.
static void frameResult(void *context,uint64_t seq,const uint8_t *status,uint32_t count) {
    @autoreleasepool {
        BOOL failed=NO;for(uint32_t i=0;i<count&&!failed;i++)failed=status[i]!=DW2_APPLIED;
        DWNativePresenter *presenter=(__bridge DWNativePresenter *)context;
        if(!failed&&!atomic_load(&presenter->_releasing)&&!atomic_load(&presenter->_retrying))return;
        NSData *statuses=[NSData dataWithBytes:status length:count];
        dispatch_async(dispatch_get_main_queue(),^{[presenter refused:statuses frame:seq];});
    }
}
static void lost(void *context,int reason) {
    @autoreleasepool {
        DWNativePresenter *presenter=(__bridge DWNativePresenter *)context;atomic_store(&presenter->_ended,true);
        // A recovery candidate is audited on a worker while main still runs.
        // Its constructor owns the client until every audit finishes: closing
        // it on main here could free an in-flight enrollment request. Loss is
        // already visible and preparation will reject/close the candidate.
        if(atomic_load(&presenter->_preparing))return;
        dispatch_async(dispatch_get_main_queue(),^{[presenter lost:reason];});
    }
}
static void turned(CFRunLoopObserverRef observer,CFRunLoopActivity activity,void *info) { (void)observer;(void)activity;atomic_store(&((__bridge DWNativePresenter *)info)->_turned,uptime()); }
+ (instancetype)presenterAt:(NSString *)runtime nonce:(NSString *)nonce64 scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope why:(NSString *__autoreleasing *)why {
    return [self presenterAt:runtime nonce:nonce64 scope:scope subset:NO watch:YES desktop:NO why:why];
}
+ (instancetype)desktopPresenterAt:(NSString *)runtime nonce:(NSString *)nonce64 why:(NSString *__autoreleasing *)why {
    return [self presenterAt:runtime nonce:nonce64 scope:nil subset:NO watch:YES desktop:YES why:why];
}
+ (instancetype)reconnectedDesktopPresenterAt:(NSString *)runtime nonce:(NSString *)nonce64 why:(NSString *__autoreleasing *)why {
    DWNativePresenter *presenter=[self presenterAt:runtime nonce:nonce64 scope:nil subset:NO watch:NO desktop:YES why:why];
    if(presenter&&![presenter restorationEmpty]){[presenter finish];if(why)*why=@"the Dock helper's previous native restoration is not yet confirmed empty";return nil;}
    return presenter;
}
+ (instancetype)presenterAt:(NSString *)runtime nonce:(NSString *)nonce64 scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope subset:(BOOL)subset watch:(BOOL)watch desktop:(BOOL)desktop why:(NSString *__autoreleasing *)why {
    DWNativePresenter *presenter=[self new];presenter->_lock=OS_UNFAIR_LOCK_INIT;
    atomic_store(&presenter->_preparing,true);
    presenter->_windows=[NSMutableDictionary dictionary];presenter->_releases=[NSMutableDictionary dictionary];presenter->_families=[NSMutableDictionary dictionary];presenter->_records=[NSMutableData data];presenter->_clips=[NSMutableData data];presenter->_frames=[NSMutableDictionary dictionary];presenter->_said=[NSMutableSet set];
    // The caller retains this object until its client threads have been joined.
    struct dw_client_callbacks callbacks={.context=(__bridge void *)presenter,.frame_result=frameResult,.lost=lost};
    int opened=dw_client_open(runtime.fileSystemRepresentation,nonce64.UTF8String,&callbacks,2000,&presenter->_client,&presenter->_info);
    if(opened!=DW_CLIENT_OK){
        atomic_store(&presenter->_preparing,false);
        if(why)*why=opened==DW_CLIENT_TIMEOUT?@"no helper answered there within 2 s":opened==DW_CLIENT_REFUSED?@"the helper refused the session (wrong nonce or protocol version)":opened==DW_CLIENT_NO_V2?@"the helper there serves protocol v1 only: its protocol v2 did not start":@"the session could not be set up";
        return nil;
    }
    NSString *refusal=nil;
    if(desktop){
        presenter->_loginUID=getuid();
        if(presenter->_info.scope!=DW2_SCOPE_SAME_USER)refusal=@"desktop presentation needs the explicit same-user Dock helper, not a finite process helper";
        else if((presenter->_info.caps&(DW2_CAP_ENROLLMENT|DW2_CAP_RESTORE_WINDOW|DW2_CAP_ALPHA))!=(DW2_CAP_ENROLLMENT|DW2_CAP_RESTORE_WINDOW|DW2_CAP_ALPHA))refusal=@"desktop presentation needs authenticated scope audit, alpha readback and per-window restoration";
        else if(!(presenter->_dockBirth=DWNativeDockBirth(presenter->_info.server_pid,presenter->_loginUID)))refusal=@"the authenticated helper peer is not this login user's valid Apple-signed Dock process";
    }else if(!scope.count || scope.count>DW2_MAX_PROCESSES)refusal=@"native presentation needs a finite nonempty process scope";
    else if(presenter->_info.scope==DW2_SCOPE_COOPERATIVE){
        if(!scope[@(presenter->_info.server_pid)])refusal=[NSString stringWithFormat:@"the helper there is process %d, which --only-pid does not name",presenter->_info.server_pid];
        else if(!subset&&scope.count!=1)refusal=@"a cooperative helper can present only its own process: --only-pid must name that process alone";
    }else if(presenter->_info.scope!=DW2_SCOPE_ALLOWLIST)refusal=@"the helper has no exact process allowlist; same-user presentation is refused";
    else if(!(presenter->_info.caps&DW2_CAP_ENROLLMENT))refusal=@"the helper cannot report its enrolled process instances; its allowlist cannot be verified";
    if(!refusal&&subset&&!(presenter->_info.caps&DW2_CAP_ENROLLMENT))refusal=@"every grouped helper must audit its exact enrolled process instances";
    // An allowlist helper is accepted only after an authenticated, read-only
    // report matches every PID and birth in --only-pid, with no extra process.
    // New cooperative helpers use the same birth check; older ones retain their
    // single-process guard and independently resolve every window before mutation.
    NSMutableDictionary *admitted=[NSMutableDictionary dictionary];
    if(!refusal && (presenter->_info.caps&DW2_CAP_ENROLLMENT)){
        struct dw2_process *processes=calloc(DW2_MAX_PROCESSES,sizeof(*processes));uint32_t count=0;
        int result=processes?dw_client_enrollment(presenter->_client,2000,processes,DW2_MAX_PROCESSES,&count):DW_CLIENT_INVALID;
        if(result!=DW_CLIENT_OK)refusal=@"the helper's process enrollment could not be verified within 2 s";
        else if(desktop){if(count)refusal=@"the desktop helper unexpectedly reports a finite process enrollment";}
        else if(!count||(!subset&&count!=scope.count))refusal=@"the helper's process allowlist differs from --only-pid";
        else if(presenter->_info.scope==DW2_SCOPE_COOPERATIVE&&(count!=1||processes[0].pid!=presenter->_info.server_pid))refusal=@"a cooperative helper must enroll only its own process";
        else for(uint32_t i=0;i<count;i++){
            NSArray *born=scope[@(processes[i].pid)];
            if(born.count!=2 || [born[0]unsignedLongLongValue]!=processes[i].birth_sec || [born[1]unsignedLongLongValue]!=processes[i].birth_usec){refusal=@"the helper's process instance differs from --only-pid (PID or birth timestamp)";break;}
            admitted[@(processes[i].pid)]=born;
        }
        free(processes);
    }
    if(!refusal&&desktop&&![presenter->_dockBirth isEqual:DWNativeProcessBirth(presenter->_info.server_pid,presenter->_loginUID)])refusal=@"the Dock process instance changed during desktop admission";
    if(!refusal&&presenter.ended)refusal=@"the helper was lost during native scope admission";
    if(refusal){atomic_store(&presenter->_preparing,false);dw_client_close([presenter take]);if(why)*why=refusal;return nil;}
    presenter->_desktopWide=desktop;
    presenter->_scope=subset?admitted.copy:[scope copy];
    atomic_store(&presenter->_preparing,false);
    if(presenter.ended){dw_client_close([presenter take]);if(why)*why=@"the helper was lost before native admission completed";return nil;}
    if(watch)[presenter watch];
    return presenter;
}
+ (instancetype)presentersAt:(NSArray<NSDictionary *> *)endpoints scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope why:(NSString *__autoreleasing *)why {
    return [self presentersAt:endpoints scope:scope recovering:NO why:why];
}
+ (instancetype)reconnectedPresentersAt:(NSArray<NSDictionary *> *)endpoints scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope why:(NSString *__autoreleasing *)why {
    // A PID recycled while the desktop slept can never inherit its authority.
    for(NSNumber *pid in scope){uint64_t sec=0,usec=0;NSArray *born=scope[pid];
        if(born.count!=2||!dw_focus_birth(pid.intValue,&sec,&usec)||sec!=[born[0]unsignedLongLongValue]||usec!=[born[1]unsignedLongLongValue]){if(why)*why=@"a selected process instance no longer exists; the native scope cannot be reused";return nil;}}
    return [self presentersAt:endpoints scope:scope recovering:YES why:why];
}
+ (instancetype)presentersAt:(NSArray<NSDictionary *> *)endpoints scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope recovering:(BOOL)recovering why:(NSString *__autoreleasing *)why {
    if(endpoints.count==1&&!recovering){NSDictionary *endpoint=endpoints.firstObject;return [self presenterAt:endpoint[@"runtime"] nonce:endpoint[@"nonce"] scope:scope why:why];}
    if(endpoints.count<1||endpoints.count>4){if(why)*why=@"native presentation accepts one to four explicit helper endpoints";return nil;}
    NSMutableSet *runtimes=[NSMutableSet set];
    for(NSDictionary *endpoint in endpoints){NSString *runtime=endpoint[@"runtime"],*nonce=endpoint[@"nonce"];
        if(![runtime isKindOfClass:NSString.class]||!runtime.isAbsolutePath||![nonce isKindOfClass:NSString.class]){if(why)*why=@"invalid native helper endpoint";return nil;}
        NSString *canonical=runtime.stringByResolvingSymlinksInPath;
        if([runtimes containsObject:canonical]){if(why)*why=@"a helper runtime was named more than once";return nil;}[runtimes addObject:canonical];}
    NSMutableArray *sessions=[NSMutableArray array];NSMutableDictionary *owners=[NSMutableDictionary dictionary];NSString *failure=nil;
    for(NSDictionary *endpoint in endpoints){
        DWNativePresenter *session=[self presenterAt:endpoint[@"runtime"] nonce:endpoint[@"nonce"] scope:scope subset:YES watch:!recovering desktop:NO why:&failure];
        if(!session)break;[sessions addObject:session];
        if(recovering&&![session restorationEmpty]){failure=@"the helper's previous native restoration is not yet confirmed empty";break;}
        for(NSNumber *pid in session->_scope){if(owners[pid]){failure=[NSString stringWithFormat:@"process %@ is enrolled in more than one helper",pid];break;}owners[pid]=session;}
        if(failure)break;
    }
    if(!failure&&owners.count!=scope.count)failure=@"the helper group does not cover exactly every --only-pid process instance";
    if(failure){for(DWNativePresenter *session in sessions)[session finish];if(why)*why=failure;return nil;}
    if(sessions.count==1)return sessions.firstObject;
    DWNativePresenterGroup *group=[DWNativePresenterGroup new];group.sessions=sessions.copy;group.owners=owners.copy;return group;
}
- (BOOL)restorationEmpty {
    size_t capacity=sizeof(struct dw2_probe_reply)+DW2_MAX_TABLE*sizeof(struct dw2_probe_entry)+16*sizeof(struct dw2_identity),length=0;
    uint8_t *bytes=malloc(capacity);if(!bytes)return NO;struct dw2_probe_reply head={0};
    os_unfair_lock_lock(&_lock);int result=_client?dw_client_probe(_client,2000,bytes,capacity,&length):DW_CLIENT_LOST;os_unfair_lock_unlock(&_lock);
    if(result==DW_CLIENT_OK&&length>=sizeof(head))memcpy(&head,bytes,sizeof(head));free(bytes);
    return result==DW_CLIENT_OK&&length>=sizeof(head)&&!head.held&&!head.restoring&&!head.table_count&&!self.ended;
}
- (BOOL)activate { if(self.ended||(_desktopWide&&![DWNativeProcessBirth(_info.server_pid,_loginUID)isEqual:_dockBirth]))return NO;if(!_observer)[self watch];return !self.ended; }
- (void)suspendWithCompletion:(void (^)(void))completed {
    dw_client *client=[self take];atomic_store(&_ended,true);[self unwatch];
    // Hold the callback context until the client's reader/writer/heartbeat join.
    DWNativePresenter *keep=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{DWCloseNativeClient(client);
        dispatch_async(dispatch_get_main_queue(),^{(void)keep;if(completed)completed();});});
}
// The library's heartbeat thread keeps the lease whatever the main thread does, which is what lets a slow frame keep its windows. A
// main thread that never comes back would then keep them, parked or scaled, without end: so it checks in at every turn of its run
// loop and at every frame it describes, and when it has not for ten seconds the session is closed from here, which makes the helper
// put every window back. The run is not resumed: -ended says so from then on.
- (void)watch {
    atomic_store(&_turned,uptime());
    CFRunLoopObserverContext context={.info=(__bridge void *)self};
    _observer=CFRunLoopObserverCreate(kCFAllocatorDefault,kCFRunLoopAllActivities,true,0,turned,&context);CFRunLoopAddObserver(CFRunLoopGetMain(),_observer,kCFRunLoopCommonModes);
    _watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_queue_create("org.infinify.native-presenter.watchdog",DISPATCH_QUEUE_SERIAL));
    dispatch_source_set_timer(_watchdog,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/10);
    __weak DWNativePresenter *weak=self;
    dispatch_source_set_event_handler(_watchdog,^{DWNativePresenter *presenter=weak;if(!presenter)return;
        uint64_t away=uptime()-atomic_load(&presenter->_turned);if(away<DWStall)return;
        dw_client *client=[presenter take];if(!client)return;
        dw_client_close(client);
        fprintf(stderr,"Infinify: native presentation ended: the main thread has not turned for %.0f s, so the session was closed and the helper puts every window back\n",away/1000.);});
    dispatch_resume(_watchdog);
}
// The session, taken from everything else for good: the caller closes it.
- (dw_client *)take { os_unfair_lock_lock(&_lock);dw_client *client=_client;_client=NULL;if(client)atomic_store(&_ended,true);os_unfair_lock_unlock(&_lock);return client; }
- (void)unwatch { if(_watchdog){dispatch_source_cancel(_watchdog);_watchdog=nil;}if(_observer){CFRunLoopRemoveObserver(CFRunLoopGetMain(),_observer,kCFRunLoopCommonModes);CFRelease(_observer);_observer=NULL;} }
- (void)dealloc { [self unwatch]; }
// The helper went away, or stopped answering. Said once; the library has closed its side already, so whatever helper is still
// there restores, and one that died took its own windows with it.
- (void)lost:(int)reason {
    dw_client *client=[self take];if(!client)return;
    [self unwatch];dw_client_close(client);
    fprintf(stderr,"Infinify: native presentation lost (%s): windows are where the helper's restore left them\n",lostName(reason));
}
// A record the helper did not apply: the window is not where the canvas shows it. Once per window and reason.
- (void)refused:(NSData *)statuses frame:(uint64_t)seq {
    NSData *frame=_frames[@(seq)];const struct dw2_record *records=frame.bytes;const uint8_t *status=statuses.bytes;
    BOOL retry=NO;
    for(NSUInteger i=0;i<statuses.length&&i<frame.length/sizeof(*records);i++){
        NSNumber *wid=@(records[i].id.wid);BOOL release=(records[i].flags&DW2_RECORD_RESTORE)!=0;
        if(status[i]==DW2_APPLIED){
            DWNativeWindow *pending=_releases[wid];
            if(release&&pending&&pending->releaseSeq&&seq>=pending->releaseSeq){[_releases removeObjectForKey:wid];_forced=YES;}
            continue;
        }
        if(status[i]==DW2_NOT_APPLIED||status[i]==DW2_RESTORE_PENDING||status[i]==DW2_SNAPSHOT||status[i]==DW2_JOURNAL)retry=YES;
        NSString *key=[NSString stringWithFormat:@"%@:%u:%d",wid,status[i],release];if([_said containsObject:key])continue;[_said addObject:key];
        fprintf(stderr,"Infinify: native presentation: window %u of process %d not %s: %s\n",wid.unsignedIntValue,records[i].id.pid,release?"restored":"placed",statusName(status[i]));
    }
    atomic_store(&_releasing,_releases.count!=0);
    // A rebind can race the helper's pending restoration. Once input stops, keep
    // retrying the latest complete frame until that restore no longer blocks it.
    // Old acknowledgements must not clear a newer frame's retry requirement.
    if(frame&&seq==_submittedSeq)atomic_store(&_retrying,retry);
}
- (NSArray<NSNumber *> *)admittedBirth:(NSDictionary *)identity {
    if(!_desktopWide)return _scope[identity[@"pid"]];
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"]){id n=identity[key];if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID())return nil;}
    long long pid=[identity[@"pid"]longLongValue];unsigned long long wid=[identity[@"wid"]unsignedLongLongValue];
    if(self.ended||getuid()!=_loginUID||geteuid()!=_loginUID||pid<=1||pid>INT32_MAX||pid==getpid()||pid==_info.server_pid||!wid||wid>UINT32_MAX
        ||![identity[@"pid"]isEqual:@(pid)]||![identity[@"wid"]isEqual:@(wid)]
        ||![_dockBirth isEqual:DWNativeProcessBirth(_info.server_pid,_loginUID)])return nil;
    NSArray *born=DWNativeProcessBirth((pid_t)pid,_loginUID);
    return born.count==2&&[born[0]isEqual:identity[@"birth_sec"]]&&[born[1]isEqual:identity[@"birth_usec"]]?born:nil;
}
- (BOOL)allowsWindow:(NSDictionary *)identity {
    if(![identity[@"pid"]isKindOfClass:NSNumber.class]||![identity[@"wid"]isKindOfClass:NSNumber.class]||![identity[@"wid"]unsignedIntValue])return NO;
    NSArray *born=[self admittedBirth:identity];if(born.count!=2||![born[0]isEqual:identity[@"birth_sec"]]||![born[1]isEqual:identity[@"birth_usec"]])return NO;
    if(!self.familiesNeeded)return YES;
    uint32_t parent=0;return DWNativeWindowParent(identity,&parent)&&!parent;
}
- (NSNumber *)rootWindowFor:(CGWindowID)window {
    DWNativeWindow *member=window?_windows[@(window)]:nil;return member&&!self.ended?@(member->root):nil;
}
- (void)forgetChildrenOf:(NSNumber *)root reason:(NSString *)reason {
    for(NSNumber *child in _families[root])if(![child isEqual:root]){DWNativeWindow *old=_windows[child];if(old)[self releaseWindow:old];}
    _families[root]=[NSSet setWithObject:root];
    NSString *key=[NSString stringWithFormat:@"family:%@:%@",root,reason];
    if(![_said containsObject:key]){[_said addObject:key];fprintf(stderr,"Infinify: native family #%u unavailable: %s\n",root.unsignedIntValue,reason.UTF8String);}
}
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native { [self bound:identity bounds:native family:nil]; }
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family {
    NSNumber *wid=identity[@"wid"];NSArray *born=[self admittedBirth:identity];
    if(!wid.unsignedIntValue || born.count!=2 || ![born[0]isEqual:identity[@"birth_sec"]] || ![born[1]isEqual:identity[@"birth_usec"]])return;
    if(_desktopWide&&![self allowsWindow:identity])return;
    DWNativeWindow *window=_windows[wid];
    if(window && (window->identity.pid!=[identity[@"pid"]intValue] || window->identity.birth_sec!=[identity[@"birth_sec"]unsignedLongLongValue] || window->identity.birth_usec!=[identity[@"birth_usec"]unsignedLongLongValue])){[self unbound:@{@"pid":@(window->identity.pid),@"wid":wid,@"birth_sec":@(window->identity.birth_sec),@"birth_usec":@(window->identity.birth_usec)}];window=nil;}
    if(_releases[wid]){[_releases removeObjectForKey:wid];atomic_store(&_releasing,_releases.count!=0);_forced=YES;}
    if(!window){window=_windows[wid]=[DWNativeWindow new];window->identity=(struct dw2_identity){.pid=[identity[@"pid"]intValue],.wid=wid.unsignedIntValue,.birth_sec=[identity[@"birth_sec"]unsignedLongLongValue],.birth_usec=[identity[@"birth_usec"]unsignedLongLongValue]};window->bounds=CGRectNull;window->root=wid.unsignedIntValue;_families[wid]=[NSSet setWithObject:wid];}
    // A window that moved or took a new size by itself: what the window server then does to its transform is not known, so the frame is sent again.
    if(!CGRectEqualToRect(window->bounds,native)){window->bounds=native;_forced=YES;}
    if(!self.familiesNeeded)return;
    NSString *why=nil;if(!family)family=DWNativeWindowFamily(identity,&why);
    if(!family||![family[@"identity"]isEqual:identity]||![family[@"root"]isEqual:wid]){
        [self forgetChildrenOf:wid reason:why?:@"identity changed"];return;
    }
    NSArray *report=[family[@"members"]isKindOfClass:NSArray.class]?family[@"members"]:nil;
    if(!report.count||report.count>64){[self forgetChildrenOf:wid reason:@"missing or unbounded family report"];return;}
    NSMutableSet<NSNumber *> *members=[NSMutableSet set];BOOL sound=YES;
    // Validate the whole report before installing any child. A separately bound
    // root or a child already belonging to another root makes it ambiguous.
    for(id value in report){
        if(![value isKindOfClass:NSDictionary.class]){sound=NO;break;}NSDictionary *member=value,*who=member[@"identity"],*frame=member[@"native_bounds"];
        if(![who isKindOfClass:NSDictionary.class]||![frame isKindOfClass:NSDictionary.class]){sound=NO;break;}
        NSNumber *child=who[@"wid"];if(![child isKindOfClass:NSNumber.class]||!child.unsignedIntValue){sound=NO;break;}DWNativeWindow *existing=_windows[child];
        NSDictionary *origin=frame[@"origin"],*size=frame[@"size"];
        if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class]){sound=NO;break;}
        for(id number in @[origin[@"x"]?:NSNull.null,origin[@"y"]?:NSNull.null,size[@"width"]?:NSNull.null,size[@"height"]?:NSNull.null])if(![number isKindOfClass:NSNumber.class])sound=NO;
        if(!sound)break;
        double x=[origin[@"x"]doubleValue],y=[origin[@"y"]doubleValue],w=[size[@"width"]doubleValue],h=[size[@"height"]doubleValue];
        if(!isfinite(x)||!isfinite(y)||!isfinite(w)||!isfinite(h)||w<=0||h<=0
            ||![who[@"pid"]isEqual:identity[@"pid"]]||![who[@"birth_sec"]isEqual:born[0]]||![who[@"birth_usec"]isEqual:born[1]]
            ||(existing&&existing->root!=wid.unsignedIntValue)||[members containsObject:child]
            ||([child isEqual:wid]&&!CGRectEqualToRect(CGRectMake(x,y,w,h),native))
            ||(_desktopWide&&(![self admittedBirth:who]||!DWNativeWindowBelongsToRoot(who,identity)))){sound=NO;break;}
        [members addObject:child];
    }
    if(!sound||![members containsObject:wid]){[self forgetChildrenOf:wid reason:@"inconsistent, duplicate or changed family member"];return;}
    for(NSNumber *old in _families[wid])if(![members containsObject:old]){DWNativeWindow *removed=_windows[old];if(removed)[self releaseWindow:removed];}
    for(NSDictionary *member in report){
        NSDictionary *who=member[@"identity"];NSNumber *child=who[@"wid"];if([child isEqual:wid])continue;
        NSDictionary *origin=member[@"native_bounds"][@"origin"],*size=member[@"native_bounds"][@"size"];
        CGRect frame=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);
        DWNativeWindow *attached=_windows[child];if(!attached){attached=_windows[child]=[DWNativeWindow new];attached->identity=window->identity;attached->identity.wid=child.unsignedIntValue;attached->root=wid.unsignedIntValue;attached->bounds=CGRectNull;_forced=YES;}
        if(_releases[child]){[_releases removeObjectForKey:child];atomic_store(&_releasing,_releases.count!=0);_forced=YES;}
        if(!CGRectEqualToRect(attached->bounds,frame)){attached->bounds=frame;_forced=YES;}
    }
    _families[wid]=members.copy;
}
- (void)releaseWindow:(DWNativeWindow *)window {
    NSNumber *wid=@(window->identity.wid);[_windows removeObjectForKey:wid];if(self.ended)return;
    if(!(_info.caps&DW2_CAP_RESTORE_WINDOW)){fprintf(stderr,"Infinify: native presentation ended: the helper cannot restore one unbound window; restoring the session\n");[self finish];return;}
    window->releaseSeq=0;_releases[wid]=window;atomic_store(&_releasing,true);_forced=YES;
}
- (void)unbound:(NSDictionary *)identity {
    NSNumber *wid=identity[@"wid"];DWNativeWindow *window=wid?_windows[wid]:nil;if(!window)return;
    if(window->identity.pid!=[identity[@"pid"]intValue]||window->identity.birth_sec!=[identity[@"birth_sec"]unsignedLongLongValue]||window->identity.birth_usec!=[identity[@"birth_usec"]unsignedLongLongValue])return;
    NSSet *members=_families[wid]?:[NSSet setWithObject:wid];for(NSNumber *child in members){DWNativeWindow *attached=_windows[child];if(attached)[self releaseWindow:attached];}[_families removeObjectForKey:wid];
}
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    atomic_store(&_turned,uptime());
    if(self.ended||![snapshot[@"outputs"]isKindOfClass:NSArray.class]||![snapshot[@"outputs"]count])return;
    // One placement per window: where it is shown on several outputs, the one that shows most of it. A transform has one target.
    NSMutableDictionary<NSNumber *,NSDictionary *> *placed=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *shown=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSValue *> *viewports=[NSMutableDictionary dictionary];
    for(NSDictionary *output in snapshot[@"outputs"]){CGRect viewport=DWNativeJSONRect(output[@"screen_bounds"]);NSNumber *identifier=output[@"id"];
        if([identifier isKindOfClass:NSNumber.class]&&!CGRectIsNull(viewport))viewports[identifier]=[NSValue valueWithRect:NSRectFromCGRect(viewport)];}
    for(NSDictionary *p in snapshot[@"placements"]){
        NSNumber *logical=p[@"window"];NSDictionary *clip=p[@"clip_rect"][@"size"];if(!logical||!identities[logical])continue;
        double area=[clip[@"width"]doubleValue]*[clip[@"height"]doubleValue];if(placed[logical]&&area<=shown[logical].doubleValue)continue;
        placed[logical]=p;shown[logical]=@(area);
    }
    // Beyond every display, by a translation alone: the window keeps its size and is drawn nowhere. 256 points clear of the far
    // corner of the displays' union, so that neither the window nor its shadow reaches one.
    CGRect all=CGRectNull;CGFloat top=NSMaxY(NSScreen.screens.firstObject.frame);
    for(NSScreen *screen in NSScreen.screens)all=CGRectUnion(all,CGRectMake(screen.frame.origin.x,top-NSMaxY(screen.frame),screen.frame.size.width,screen.frame.size.height));
    if(CGRectIsNull(all))return;
    double parkX=ceil(CGRectGetMaxX(all))+256,parkY=ceil(CGRectGetMaxY(all))+256;
    NSMutableDictionary<NSNumber *,NSNumber *> *logicals=[NSMutableDictionary dictionary];
    for(NSNumber *logical in identities){NSNumber *wid=identities[logical][@"wid"];DWNativeWindow *root=_windows[wid];if(!root||root->root!=wid.unsignedIntValue)continue;for(NSNumber *member in _families[wid]?:[NSSet setWithObject:wid])if(_windows[member])logicals[member]=logical;}
    [_records setLength:0];[_clips setLength:0];NSMutableArray<NSNumber *> *order=[NSMutableArray array];
    // In the order of the window numbers: the same scene is then the same bytes, and is not sent twice.
    for(NSNumber *wid in [logicals.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        DWNativeWindow *window=_windows[wid];NSDictionary *p=placed[logicals[wid]];CGSize own=window->bounds.size;
        window->logical=logicals[wid];
        struct dw2_record record={.id=window->identity,.m={1,0,0,1,-parkX,-parkY}};
        NSDictionary *origin=p[@"screen_rect"][@"origin"],*size=p[@"screen_rect"][@"size"];
        double sx=[origin[@"x"]doubleValue],sy=[origin[@"y"]doubleValue],sw=[size[@"width"]doubleValue],sh=[size[@"height"]doubleValue];
        DWNativeWindow *root=_windows[@(window->root)];CGSize rootSize=root?root->bounds.size:own;
        if(p&&sw>=1&&sh>=1&&own.width>0&&own.height>0&&rootSize.width>0&&rootSize.height>0){
            // Screen to window-local (protocol2.h): the window's own width and height are drawn across the placement's.
            double mx=rootSize.width/sw,my=rootSize.height/sh;
            double dx=root?window->bounds.origin.x-root->bounds.origin.x:0,dy=root?window->bounds.origin.y-root->bounds.origin.y:0;
            double m[6]={mx,0,0,my,-sx*mx-dx,-sy*my-dy};BOOL sound=YES;
            // The helper's bounds on a matrix; a placement they cannot express (a window a million points off, a zoom of a thousandth) is parked.
            for(int i=0;i<6;i++)if(!isfinite(m[i])||fabs(m[i])>1e6)sound=NO;
            if(sound){
                memcpy(record.m,m,sizeof(m));
                NSValue *viewport=viewports[p[@"output"]];DWNativeClipGeometry geometry={0};
                if(viewport&&root&&DWNativeClipPlacement(window->bounds,root->bounds,CGRectMake(sx,sy,sw,sh),NSRectToCGRect(viewport.rectValue),&geometry)){
                    DWNativeClipRecord clip={.identity=window->identity,.logical=logicals[wid].unsignedLongLongValue,.output=[p[@"output"]unsignedLongLongValue],.root=window->root,.viewport=NSRectToCGRect(viewport.rectValue),.geometry=geometry};
                    [_clips appendBytes:&clip length:sizeof(clip)];
                    if(geometry.required){
                        NSString *key=[NSString stringWithFormat:@"clip:%d:%llu:%llu:%u",window->identity.pid,(unsigned long long)window->identity.birth_sec,(unsigned long long)window->identity.birth_usec,window->identity.wid];
                        if(![_said containsObject:key]){[_said addObject:key];fprintf(stderr,"Infinify: native window %u of process %d needs display clipping; the helper cannot restore original native regions yet, so its transformed content may extend outside the selected output\n",window->identity.wid,window->identity.pid);}
                    }
                }
            }
        }
        // Alpha is sent for a window from the first frame its opacity is not 1, and from then on always, 1 included: a window whose
        // alpha nobody asked to change is never written, and the helper journals no alpha for it.
        double opacity=[p[@"opacity"]isKindOfClass:NSNumber.class]?fmax(0,fmin(1,[p[@"opacity"]doubleValue])):1;
        if(p&&opacity!=1&&(_info.caps&DW2_CAP_ALPHA))window->alpha=YES;
        if(window->alpha){record.flags=DW2_RECORD_HAS_ALPHA;record.alpha=(float)opacity;}
        [_records appendBytes:&record length:sizeof(record)];[order addObject:logicals[wid]];
    }
    for(NSNumber *wid in [_releases.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        DWNativeWindow *window=_releases[wid];struct dw2_record record={.id=window->identity,.flags=DW2_RECORD_RESTORE};
        [_records appendBytes:&record length:sizeof(record)];[order addObject:window->logical?:wid];
    }
    _order=order;_described=YES;
}
- (NSArray<NSDictionary *> *)clippingPlan {
    if(self.ended)return @[];
    NSMutableArray *result=[NSMutableArray array];const DWNativeClipRecord *records=_clips.bytes;
    for(NSUInteger i=0;i<_clips.length/sizeof(*records);i++){
        const DWNativeClipRecord *record=&records[i];DWNativeWindow *window=_windows[@(record->identity.wid)];
        if(!window||memcmp(&window->identity,&record->identity,sizeof(record->identity))||window->root!=record->root)continue;
        DWNativeClipGeometry geometry=record->geometry;CGRect screen=geometry.screen,viewport=record->viewport;
        [result addObject:@{@"identity":@{@"pid":@(record->identity.pid),@"birth_sec":@(record->identity.birth_sec),@"birth_usec":@(record->identity.birth_usec),@"wid":@(record->identity.wid)},
            @"window":@(record->logical),@"root":@(record->root),@"output":@(record->output),@"required":@(geometry.required),
            @"screen_rect":DWNativeRectArray(screen),@"viewport":DWNativeRectArray(viewport),@"visible_screen_rect":DWNativeRectArray(geometry.visible),@"local_clip_rect":DWNativeRectArray(geometry.local),
            @"overflow":@{@"left":@(CGRectGetMinX(screen)<CGRectGetMinX(viewport)),@"top":@(CGRectGetMinY(screen)<CGRectGetMinY(viewport)),@"right":@(CGRectGetMaxX(screen)>CGRectGetMaxX(viewport)),@"bottom":@(CGRectGetMaxY(screen)>CGRectGetMaxY(viewport))}}];
    }
    return result;
}
- (void)submit {
    BOOL retry=_releases.count||atomic_load(&_retrying);
    if(self.ended||!_described||(!_forced&&[_records isEqualToData:_sent]&&(!retry||uptime()-_lastSent<250)))return;
    NSUInteger count=_records.length/sizeof(struct dw2_record);
    // A frame describes every bound window. Sending a prefix would leave the omitted
    // windows at an old placement while pretending the full snapshot was submitted.
    if(count>_info.max_records){fprintf(stderr,"Infinify: native presentation ended: %lu windows exceed the helper's frame limit of %u; restoring all windows\n",(unsigned long)count,_info.max_records);[self finish];return;}
    uint64_t seq=0;os_unfair_lock_lock(&_lock);int result=_client?dw_client_submit_frame(_client,_records.bytes,(uint32_t)count,&seq):DW_CLIENT_LOST;os_unfair_lock_unlock(&_lock);
    if(result!=DW_CLIENT_OK)return;
    _sent=[_records copy];_sentOrder=_order;_forced=NO;_lastSent=uptime();_submittedSeq=seq;
    if(_releases.count)for(DWNativeWindow *window in _releases.objectEnumerator)if(!window->releaseSeq)window->releaseSeq=seq;
    // A frame the next one replaced is never answered: what is kept is bounded by age.
    _frames[@(seq)]=_sent;for(NSNumber *old in _frames.allKeys)if(old.unsignedLongLongValue+64<seq)[_frames removeObjectForKey:old];
}
- (void)finish {
    dw_client *client=[self take];[self unwatch];if(!client)return;
    // The session is this method's alone now. Restored by request and confirmed, so that the windows are back before the canvas
    // closes; the close that follows would restore them too, but says nothing of how that went.
    DWCloseNativeClient(client);
}
- (NSData *)debug:(NSDictionary *)request {
    NSNumber *stall=[request[@"stall"]isKindOfClass:NSNumber.class]?request[@"stall"]:nil;
    if(stall){
        double seconds=fmax(0,fmin(30,stall.doubleValue));
        // After the answer is written: the main thread is then kept from its run loop, as a hang of it would keep it.
        dispatch_async(dispatch_get_main_queue(),^{[NSThread sleepForTimeInterval:seconds];});
        return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugNative":@{@"stall":@(seconds)}}} options:0 error:nil];
    }
    NSMutableDictionary *reply=[@{@"ended":@(self.ended),@"scope":@(_info.scope),@"server_pid":@(_info.server_pid),@"lease_ms":@(_info.lease_ms),@"pending_releases":@(_releases.count)} mutableCopy];
    size_t capacity=sizeof(struct dw2_probe_reply)+DW2_MAX_TABLE*sizeof(struct dw2_probe_entry)+16*sizeof(struct dw2_identity),length=0;uint8_t *bytes=malloc(capacity);
    struct dw_client_stats stats={0};int probed=DW_CLIENT_LOST;
    os_unfair_lock_lock(&_lock);if(_client){dw_client_stats(_client,&stats);if(bytes)probed=dw_client_probe(_client,500,bytes,capacity,&length);}os_unfair_lock_unlock(&_lock);
    reply[@"stats"]=@{@"submitted":@(stats.submitted),@"written":@(stats.written),@"dropped_local":@(stats.dropped_local),@"applied":@(stats.applied),@"superseded":@(stats.superseded),@"discarded":@(stats.discarded),@"records_applied":@(stats.records_applied),@"records_failed":@(stats.records_failed),@"heartbeats_sent":@(stats.heartbeats_sent),@"heartbeats_acked":@(stats.heartbeats_acked),@"last_applied_seq":@(stats.last_applied_seq)};
    if(probed==DW_CLIENT_OK&&length>=sizeof(struct dw2_probe_reply)){
        struct dw2_probe_reply head;memcpy(&head,bytes,sizeof(head));NSMutableArray *table=[NSMutableArray array];
        for(uint32_t i=0;i<head.table_count&&sizeof(head)+(i+1)*sizeof(struct dw2_probe_entry)<=length;i++){
            struct dw2_probe_entry e;memcpy(&e,bytes+sizeof(head)+i*sizeof(e),sizeof(e));
            [table addObject:@{@"pid":@(e.id.pid),@"wid":@(e.id.wid),@"state":@(e.state),@"alpha":@(e.alpha),@"transform":@[@(e.transform[0]),@(e.transform[1]),@(e.transform[2]),@(e.transform[3]),@(e.transform[4]),@(e.transform[5])],@"screen_rect":@[@(e.screen_rect[0]),@(e.screen_rect[1]),@(e.screen_rect[2]),@(e.screen_rect[3])]}];
        }
        reply[@"probe"]=@{@"held":@(head.held),@"restoring":@(head.restoring),@"frames_received":@(head.frames_received),@"frames_applied":@(head.frames_applied),@"frames_superseded":@(head.frames_superseded),@"journal_writes":@(head.journal_writes),@"table":table};
    } else reply[@"probe"]=NSNull.null;
    free(bytes);
    NSMutableArray *records=[NSMutableArray array];const struct dw2_record *sent=_sent.bytes;
    for(NSUInteger i=0;i<_sent.length/sizeof(*sent);i++)[records addObject:@{@"window":i<_sentOrder.count?_sentOrder[i]:NSNull.null,@"wid":@(sent[i].id.wid),@"m":@[@(sent[i].m[0]),@(sent[i].m[1]),@(sent[i].m[2]),@(sent[i].m[3]),@(sent[i].m[4]),@(sent[i].m[5])],@"alpha":sent[i].flags&DW2_RECORD_HAS_ALPHA?@(sent[i].alpha):NSNull.null}];
    reply[@"records"]=records;
    reply[@"clipping"]=@{@"native_supported":@NO,@"planning_only":@YES,@"basis":@"last described placement and cached native family bounds; content rectangles only",
        @"remaining":@"exact original native shape, event and shadow region snapshot/persistence, apply/readback and restoration support",@"plan":[self clippingPlan]};
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugNative":reply}} options:0 error:nil];
}
@end

// Each helper keeps its existing authenticated scope and journal. Grouping
// routes a logical canvas frame to those already admitted sessions; it never
// enrolls a process, loads code, or grants a helper another process's windows.
@implementation DWNativePresenterGroup
- (BOOL)activate {
    if(self.ended)return NO;
    for(DWNativePresenter *session in self.sessions)if(![session activate])return NO;
    return !self.ended;
}
- (void)suspendWithCompletion:(void (^)(void))completed {
    self.groupEnded=YES;self.finished=YES;dispatch_group_t drain=dispatch_group_create();
    for(DWNativePresenter *session in self.sessions){dispatch_group_enter(drain);[session suspendWithCompletion:^{dispatch_group_leave(drain);}];}
    dispatch_group_notify(drain,dispatch_get_main_queue(),^{if(completed)completed();});
}
- (void)finish {
    self.groupEnded=YES;if(self.finished)return;self.finished=YES;
    for(DWNativePresenter *session in self.sessions)[session finish];
}
- (BOOL)ended {
    if(self.groupEnded)return YES;
    for(DWNativePresenter *session in self.sessions)if(session.ended){
        self.groupEnded=YES;
        // Restore the whole presentation on a partial loss. Frame/input checks
        // stop now; draining sibling sessions belongs to the next main turn.
        dispatch_async(dispatch_get_main_queue(),^{[self finish];});return YES;
    }
    return NO;
}
- (BOOL)familiesNeeded { for(DWNativePresenter *session in self.sessions)if(session.familiesNeeded)return YES;return NO; }
- (BOOL)allowsWindow:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]allowsWindow:identity]; }
- (NSNumber *)rootWindowFor:(CGWindowID)window {
    if(self.ended)return nil;for(DWNativePresenter *session in self.sessions){NSNumber *root=[session rootWindowFor:window];if(root)return root;}return nil;
}
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native { [self bound:identity bounds:native family:nil]; }
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family {
    if(!self.ended)[self.owners[identity[@"pid"]]bound:identity bounds:native family:family];
}
- (void)unbound:(NSDictionary *)identity { [self.owners[identity[@"pid"]]unbound:identity]; }
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    if(self.ended)return;
    for(DWNativePresenter *session in self.sessions){NSMutableDictionary *owned=[NSMutableDictionary dictionary];
        for(NSNumber *logical in identities)if(self.owners[identities[logical][@"pid"]]==session)owned[logical]=identities[logical];
        [session describe:snapshot bound:owned];}
}
- (void)submit { if(self.ended)return;for(DWNativePresenter *session in self.sessions){[session submit];if(self.ended)break;} }
- (NSArray<NSDictionary *> *)clippingPlan {
    if(self.ended)return @[];NSMutableArray *result=[NSMutableArray array];for(DWNativePresenter *session in self.sessions)[result addObjectsFromArray:[session clippingPlan]];return result;
}
- (NSData *)debug:(NSDictionary *)request {
    if([request[@"stall"]isKindOfClass:NSNumber.class])return [self.sessions.firstObject debug:request];
    NSMutableArray *sessions=[NSMutableArray array],*records=[NSMutableArray array],*table=[NSMutableArray array];NSMutableDictionary *stats=[NSMutableDictionary dictionary],*probe=[NSMutableDictionary dictionary];
    BOOL complete=YES;
    for(DWNativePresenter *session in self.sessions){NSDictionary *value=[NSJSONSerialization JSONObjectWithData:[session debug:request] options:0 error:nil][@"Ok"][@"DebugNative"];
        if(![value isKindOfClass:NSDictionary.class]){complete=NO;continue;}[sessions addObject:value];[records addObjectsFromArray:value[@"records"]?:@[]];
        for(NSString *key in value[@"stats"])if(![key isEqual:@"last_applied_seq"])stats[key]=@([stats[key]unsignedLongLongValue]+[value[@"stats"][key]unsignedLongLongValue]);
        NSDictionary *local=value[@"probe"];
        if(![local isKindOfClass:NSDictionary.class]){complete=NO;continue;}
        [table addObjectsFromArray:local[@"table"]?:@[]];
        for(NSString *key in @[@"held",@"restoring",@"frames_received",@"frames_applied",@"frames_superseded",@"journal_writes"])probe[key]=@([probe[key]unsignedLongLongValue]+[local[key]unsignedLongLongValue]);
    }
    probe[@"table"]=table;
    NSDictionary *reply=@{@"group":@YES,@"ended":@(self.ended),@"sessions":sessions,@"records":records,@"stats":stats,@"probe":complete?probe:(id)NSNull.null,
        @"clipping":@{@"native_supported":@NO,@"planning_only":@YES,@"plan":[self clippingPlan]}};
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugNative":reply}} options:0 error:nil];
}
@end
