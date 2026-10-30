// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWPayloadState.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/desktop/native-presenter.m (37b27b1): session admission and lifetime, restoration, watchdog, debug, and the receipt classes.
#import "DWNativePresenter+Private.h"
#import "DWNativeFocus.h"
#import <Security/Security.h>
#include <libproc.h>
#include <unistd.h>

// What the answer to a veil request says about the helper. An acceptance, but also no answer in time (the request may still be
// carried out) and an answer that cannot be read (it may have been accepted) leave it possibly veiling: the shell then releases
// a window it will not manage explicitly, which costs a no-op record when nothing is held, where assuming otherwise would leave such a
// window invisible for the helper's whole bound. A refusal, a lost helper and a bad request say it is not.
static BOOL DWNativeVeilMayBeOn(int result) { return result==DW_CLIENT_OK||result==DW_CLIENT_TIMEOUT||result==DW_CLIENT_INVALID; }
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
@implementation DWNativeHiddenRoot
- (instancetype)initWithSession:(NSUUID *)value { if((self=[super init]))session=value;return self; }
@end
@implementation DWNativePlacementDescription
- (BOOL)isEqual:(id)object {
    if(object==self)return YES;
    if(![object isKindOfClass:DWNativePlacementDescription.class])return NO;
    DWNativePlacementDescription *other=object;
    return parked==other->parked&&!memcmp(&binding,&other->binding,sizeof(binding))&&[members isEqualToData:other->members];
}
- (NSUInteger)hash { return members.hash; }
@end
@implementation DWNativeAppliedPlacement {
    NSUUID *_session;uint64_t _sequence;DWNativePlacementDescription *_placementDescription;
}
- (instancetype)initWithSession:(NSUUID *)session sequence:(uint64_t)sequence description:(DWNativePlacementDescription *)description {
    if((self=[super init])){_session=session;_sequence=sequence;_placementDescription=description;}return self;
}
- (NSUUID *)session { return _session; }
- (uint64_t)sequence { return _sequence; }
- (uint64_t)window { return _placementDescription->binding.window; }
- (uint64_t)generation { return _placementDescription->binding.generation; }
- (uint64_t)output { return _placementDescription->binding.output; }
- (NSDictionary *)identity { return DWNativePlacementIdentity(_placementDescription->binding.identity); }
- (CGRect)requestedScreenRect { return _placementDescription->binding.screen; }
- (CGRect)requestedClipRect { return _placementDescription->binding.clip; }
- (CGRect)requestedViewport { return _placementDescription->binding.viewport; }
- (DWNativePlacementDescription *)placementDescription { return _placementDescription; }
- (NSArray<NSDictionary *> *)members {
    NSMutableArray *result=[NSMutableArray array];const DWNativePlacementMember *records=_placementDescription->members.bytes;
    for(NSUInteger i=0;i<_placementDescription->members.length/sizeof(*records);i++){
        const DWNativePlacementMember *member=&records[i];const struct dw2_record *record=&member->record;
        [result addObject:@{@"identity":DWNativePlacementIdentity(record->id),@"native_bounds":DWNativeRectArray(member->native),@"parent":@(member->parent),
            @"requested_transform":@[@(record->m[0]),@(record->m[1]),@(record->m[2]),@(record->m[3]),@(record->m[4]),@(record->m[5])],
            @"requested_alpha":record->flags&DW2_RECORD_HAS_ALPHA?@(record->alpha):NSNull.null,@"flags":@(record->flags),
            @"requested_space":member->targetSpace?@(member->targetSpace):NSNull.null}];
    }
    return result.copy;
}
@end
// How long the main thread may stay away from its run loop before the session is closed for it.
static const uint64_t DWStall=10000;
@implementation DWNativeSpaceReflow @end
@implementation DWNativeWindow @end
static const char *lostName(int reason) { return reason==DW_LOST_EOF?"the helper closed the connection":reason==DW_LOST_WRITE_TIMEOUT?"the helper stopped reading":reason==DW_LOST_HEARTBEAT?"no heartbeat was answered for a whole lease":"the helper broke the protocol"; }
static void DWDisposeNativeClient(dw_client *client,id activity) {
    dw_client_close(client);
    if(activity)[NSProcessInfo.processInfo endActivity:activity];
}
static void DWCloseNativeClient(dw_client *client,id activity) {
    if(!client){DWDisposeNativeClient(client,activity);return;}
    struct dw2_restore_result *results=calloc(DW2_MAX_TABLE,sizeof(*results));uint32_t count=0,pending=0,journalPersisted=0;
    int result=results?dw_client_restore_all(client,2000,results,DW2_MAX_TABLE,&count,&pending,&journalPersisted):DW_CLIENT_INVALID;
    free(results);
    if(result==DW_CLIENT_UNDURABLE)fprintf(stderr,"Infinify: the helper returned a valid restore summary (%u of %u still pending, journal_persisted=%u) but did not confirm the journal write; closing the session leaves restoration with the helper\n",pending,count,journalPersisted);
    else if(result!=DW_CLIENT_OK)fprintf(stderr,"Infinify: native restoration was not confirmed (%s); closing the session leaves restoration with the helper\n",result==DW_CLIENT_TIMEOUT?"no answer within 2 s":result==DW_CLIENT_LOST?"the helper is gone":"invalid reply");
    else if(pending)fprintf(stderr,"Infinify: %u of %u native windows still restoring; the helper keeps retrying them\n",pending,count);
    DWDisposeNativeClient(client,activity);
}
@implementation DWNativePresenter
- (instancetype)init {
    if((self=[super init])){
        _lock=OS_UNFAIR_LOCK_INIT;
        _windows=[NSMutableDictionary dictionary];_releases=[NSMutableDictionary dictionary];_families=[NSMutableDictionary dictionary];_withheld=[NSMutableDictionary dictionary];_rebases=[NSMutableDictionary dictionary];_rebased=[NSMutableSet set];_transitions=[NSMutableDictionary dictionary];
        _spaceReflows=[NSMutableDictionary dictionary];
        _records=[NSMutableData data];_frames=[NSMutableDictionary dictionary];_said=[NSMutableSet set];
        _placementSession=[NSUUID UUID];_desiredPlacements=@{};_acknowledgedPlacements=@{};_framePlacements=[NSMutableDictionary dictionary];
    }
    return self;
}
- (BOOL)ended { return atomic_load(&_ended); }
// Library threads. Neither takes the lock or closes anything: they leave a note for the main thread.
static void frameResult(void *context,uint64_t seq,const uint8_t *status,uint32_t count) {
    @autoreleasepool {
        DWNativePresenter *presenter=(__bridge DWNativePresenter *)context;
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
    return [self presenterAt:runtime nonce:nonce64 scope:nil subset:NO watch:NO desktop:YES why:why];
}
+ (instancetype)presenterAt:(NSString *)runtime nonce:(NSString *)nonce64 scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope subset:(BOOL)subset watch:(BOOL)watch desktop:(BOOL)desktop why:(NSString *__autoreleasing *)why {
    DWNativePresenter *presenter=[self new];
    atomic_store(&presenter->_preparing,true);
    // Native windows stay placed while the canvas is quiet or covered. Its
    // frame driver's activity ends at idle, but this user-requested session
    // still needs timely heartbeats. Allow system/display sleep and keep the
    // activity until client closure; no latency-critical or sleep assertion.
    presenter->_activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Maintaining native window presentation"];
    // The caller retains this object until its client threads have been joined.
    struct dw_client_callbacks callbacks={.context=(__bridge void *)presenter,.frame_result=frameResult,.lost=lost};
    int opened=dw_client_open(runtime.fileSystemRepresentation,nonce64.UTF8String,&callbacks,2000,&presenter->_client,&presenter->_info);
    if(opened!=DW_CLIENT_OK){
        atomic_store(&presenter->_preparing,false);
        id activity;dw_client *client=[presenter takeActivity:&activity];DWDisposeNativeClient(client,activity);
        if(why)*why=opened==DW_CLIENT_TIMEOUT?@"no helper answered there within 2 s":opened==DW_CLIENT_REFUSED?@"the helper refused the session (wrong nonce or protocol version)":@"the session could not be set up";
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
    if(!refusal&&(presenter->_info.caps&(DW2_CAP_ENROLLMENT|DW2_CAP_RESTORE_WINDOW|DW2_CAP_INSPECT))!=(DW2_CAP_ENROLLMENT|DW2_CAP_RESTORE_WINDOW|DW2_CAP_INSPECT))refusal=@"the native helper lacks the current scope audit, inspection or per-window restoration contract; rebuild it";
    // Every finite helper must freshly audit its process instances before any
    // window is admitted. Cooperative fixtures obey the same current contract.
    NSMutableDictionary *admitted=[NSMutableDictionary dictionary];
    if(!refusal){
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
    // Relaunching through a saved launcher record is an initial constructor,
    // too: every desktop admission must wait for the prior restore table.
    if(!refusal&&![presenter restorationEmpty])refusal=@"the helper's previous native restoration and journal are not yet confirmed empty";
    if(!refusal&&desktop&&![presenter->_dockBirth isEqual:DWNativeProcessBirth(presenter->_info.server_pid,presenter->_loginUID)])refusal=@"the Dock process instance changed during desktop admission";
    if(!refusal&&presenter.ended)refusal=@"the helper was lost during native scope admission";
    if(refusal){atomic_store(&presenter->_preparing,false);id activity;dw_client *client=[presenter takeActivity:&activity];DWDisposeNativeClient(client,activity);if(why)*why=refusal;return nil;}
    presenter->_desktopWide=desktop;
    presenter->_scope=subset?admitted.copy:[scope copy];
    // Only after the empty restoration table was confirmed: a window veiled earlier would have been a leftover. A helper that cannot, or
    // will not, simply leaves new windows to appear as they always did; the session is not refused for it.
    if(desktop&&(presenter->_info.caps&DW2_CAP_VEIL)){
        uint32_t held=0;int veiled=dw_client_veil(presenter->_client,2000,true,&held);
        presenter->_veiling=DWNativeVeilMayBeOn(veiled);
        if(veiled!=DW_CLIENT_OK&&!presenter.ended)fprintf(stderr,"Infinify: the helper did not confirm the arrival veil (%d)%s\n",veiled,presenter->_veiling?"; it may be on, so windows this shell will not manage are released explicitly":"; new windows show at their native place until placed");
    }
    atomic_store(&presenter->_preparing,false);
    if(presenter.ended){id activity;dw_client *client=[presenter takeActivity:&activity];DWDisposeNativeClient(client,activity);if(why)*why=@"the helper was lost before native admission completed";return nil;}
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
    return result==DW_CLIENT_OK&&length>=sizeof(head)&&head.scope==_info.scope&&head.caps==_info.caps&&head.queue==_info.queue&&head.lease_ms==_info.lease_ms&&head.server_pid==_info.server_pid&&!head.journal_pending&&!head.held&&!head.restoring&&!head.table_count&&head.fixture_count<=16&&length==sizeof(head)+(size_t)head.fixture_count*sizeof(struct dw2_identity)&&!self.ended;
}
- (BOOL)activate { if(self.ended||(_desktopWide&&![DWNativeProcessBirth(_info.server_pid,_loginUID)isEqual:_dockBirth]))return NO;if(!_observer)[self watch];return !self.ended; }
- (void)suspendWithCompletion:(void (^)(void))completed {
    id activity;dw_client *client=[self takeActivity:&activity];atomic_store(&_ended,true);[self unwatch];
    // Hold the callback context until the client's reader/writer/heartbeat join.
    DWNativePresenter *keep=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{DWCloseNativeClient(client,activity);
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
        id activity;dw_client *client=[presenter takeActivity:&activity];if(!client)return;
        DWDisposeNativeClient(client,activity);
        fprintf(stderr,"Infinify: native presentation ended: the main thread has not turned for %.0f s, so the session was closed and the helper puts every window back\n",away/1000.);});
    dispatch_resume(_watchdog);
}
// Transfer the session and its activity together: only the closer owns either
// after this lock. A concurrent loss/suspend cannot end an activity while the
// first closer is still restoring windows or joining the heartbeat thread.
- (dw_client *)takeActivity:(id __strong *)activity {
    os_unfair_lock_lock(&_lock);dw_client *client=_client;_client=NULL;
    *activity=_activity;_activity=nil;if(client)atomic_store(&_ended,true);
    os_unfair_lock_unlock(&_lock);return client;
}
- (void)unwatch { if(_watchdog){dispatch_source_cancel(_watchdog);_watchdog=nil;}if(_observer){CFRunLoopRemoveObserver(CFRunLoopGetMain(),_observer,kCFRunLoopCommonModes);CFRelease(_observer);_observer=NULL;} }
- (void)dealloc { [self unwatch]; }
// The helper went away, or stopped answering. Said once; the library has closed its side already, so whatever helper is still
// there restores, and one that died took its own windows with it.
- (void)lost:(int)reason {
    id activity;dw_client *client=[self takeActivity:&activity];if(!client)return;
    [self unwatch];DWDisposeNativeClient(client,activity);
    fprintf(stderr,"Infinify: native presentation lost (%s): windows are where the helper's restore left them\n",lostName(reason));
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
- (void)finish {
    id activity;dw_client *client=[self takeActivity:&activity];[self unwatch];if(!client)return;
    // The session is this method's alone now. Restored by request and confirmed, so that the windows are back before the canvas
    // closes; the close that follows would restore them too, but says nothing of how that went.
    DWCloseNativeClient(client,activity);
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
    const uint64_t *sentSpaces=_sentSpaces.bytes;
    for(NSUInteger i=0;i<_sent.length/sizeof(*sent);i++)[records addObject:@{@"window":i<_sentOrder.count?_sentOrder[i]:NSNull.null,@"wid":@(sent[i].id.wid),@"m":@[@(sent[i].m[0]),@(sent[i].m[1]),@(sent[i].m[2]),@(sent[i].m[3]),@(sent[i].m[4]),@(sent[i].m[5])],@"alpha":sent[i].flags&DW2_RECORD_HAS_ALPHA?@(sent[i].alpha):NSNull.null,
        @"requested_space":i<_sentSpaces.length/sizeof(*sentSpaces)&&sentSpaces[i]?@(sentSpaces[i]):NSNull.null,@"requested_pinned":@((sent[i].flags&DW2_RECORD_PINNED)!=0)}];
    reply[@"records"]=records;
    NSMutableArray *reflows=[NSMutableArray array];
    for(NSNumber *wid in [_spaceReflows.allKeys sortedArrayUsingSelector:@selector(compare:)]){DWNativeSpaceReflow *reflow=_spaceReflows[wid];
        [reflows addObject:@{@"identity":DWNativePlacementIdentity(reflow->identity),@"target_space":@(reflow->target),
            @"original_native_frame":DWNativeRectArray(reflow->original),@"before_native_frame":DWNativeRectArray(reflow->before),@"observed_native_frame":DWNativeRectArray(reflow->observed),
            @"frame_changed":@(reflow->changed),@"settled":@(reflow->settled),@"ended_by_native_input":@(reflow->nativeInput),
            @"acknowledged_sequence":@(reflow->acknowledgedSequence),@"native_frame_restored":@(CGRectEqualToRect(reflow->original,reflow->observed)),@"native_frame_restore_owned":@NO}];}
    reply[@"space_reflows"]=reflows;
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugNative":reply}} options:0 error:nil];
}
@end
