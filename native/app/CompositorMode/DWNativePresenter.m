// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWPayload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
#import "DWNativePresenter.h"
#import "DWGeometryJSON.h"
#import "DWNativeFamily.h"
#import "DWNativeDisplaySpace.h"
#import "DWNativeFocus.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <libproc.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include "DWHelperClient.h"

bool DWNativeBounds(uint32_t wid,CGRect *out) {
    static int (*connection)(void);static CGError (*bounds)(int,uint32_t,CGRect *);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;connection=dlsym(sky,"SLSMainConnectionID");bounds=dlsym(sky,"SLSGetWindowBounds");});
    CGRect r=CGRectZero;if(!connection||!bounds||!wid||bounds(connection(),wid,&r)!=kCGErrorSuccess)return false;
    if(!isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0)return false;
    if(out)*out=r;return true;
}

// yabai dd845723416f5fe92af49fad5ebab00369e07edd src/misc/extern.h:23-24;
// src/window_manager.c:618-699 brackets AX writes plus its own proxy swap.
// This app-connection bracket still requires independent live observation.
CGError DWNativeScreenUpdates(BOOL enabled) {
    static int (*connection)(void);static CGError (*disable)(int),(*enable)(int);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;
        connection=dlsym(sky,"SLSMainConnectionID");disable=dlsym(sky,"SLSDisableUpdate");enable=dlsym(sky,"SLSReenableUpdate");});
    if(!connection||!disable||!enable)return kCGErrorNotImplemented;
    return enabled?enable(connection()):disable(connection());
}

// What the answer to a veil request says about the helper. An acceptance, but also no answer in time (the request may still be
// carried out) and an answer that cannot be read (it may have been accepted) leave it possibly veiling: the shell then releases
// a window it will not manage explicitly, which costs a no-op record when nothing is held, where assuming otherwise would leave such a
// window invisible for the helper's whole bound. A refusal, a lost helper and a bad request say it is not.
static BOOL DWNativeVeilMayBeOn(int result) { return result==DW_CLIENT_OK||result==DW_CLIENT_TIMEOUT||result==DW_CLIENT_INVALID; }
bool DWNativeClipPlacement(CGRect native,CGRect rootNative,CGRect rootScreen,CGRect viewport,DWNativeClipGeometry *out) {
    if(!out||!DWFiniteRect(native)||!DWFiniteRect(rootNative)||!DWFiniteRect(rootScreen)||!DWFiniteRect(viewport))return false;
    double zx=rootScreen.size.width/rootNative.size.width,zy=rootScreen.size.height/rootNative.size.height;
    if(!isfinite(zx)||!isfinite(zy)||zx<=0||zy<=0)return false;
    CGRect screen=CGRectMake(rootScreen.origin.x+(native.origin.x-rootNative.origin.x)*zx,
        rootScreen.origin.y+(native.origin.y-rootNative.origin.y)*zy,native.size.width*zx,native.size.height*zy);
    if(!DWFiniteRect(screen))return false;
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
    return DWFiniteRect(r)?r:CGRectNull;
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
// Compact, immutable correspondence alongside an emitted frame. Public receipt
// dictionaries are made only when queried, never for every presentation member.
typedef struct {
    struct dw2_identity identity;
    uint64_t window,generation,output,revision;
    CGRect screen,clip,viewport;
} DWNativePlacementBinding;
typedef struct {
    struct dw2_record record;
    uint64_t targetSpace;
    CGRect native;
    uint32_t index,parent;
} DWNativePlacementMember;
@interface DWNativeHiddenRoot () {
@public NSUUID *session;struct dw2_record record;NSInteger phase;
}
@property(nonatomic,readwrite,copy) NSDictionary *identity;
@property(nonatomic,readwrite) CGRect nativeBounds,screenRect;
- (instancetype)initWithSession:(NSUUID *)value;
@end
@implementation DWNativeHiddenRoot
- (instancetype)initWithSession:(NSUUID *)value { if((self=[super init]))session=value;return self; }
@end
@interface DWNativePlacementDescription : NSObject {
@public DWNativePlacementBinding binding;NSData *members;BOOL parked;
}
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
static NSDictionary *DWNativePlacementIdentity(struct dw2_identity identity) {
    return @{@"pid":@(identity.pid),@"wid":@(identity.wid),@"birth_sec":@(identity.birth_sec),@"birth_usec":@(identity.birth_usec)};
}
static BOOL DWNativePlacementSourceMatches(id value,NSDictionary *identity) {
    if(![value isKindOfClass:NSDictionary.class])return NO;
    id owner=value[@"owner"];if(owner&&owner!=NSNull.null)return NO;
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(![value[key]isEqual:identity[key]])return NO;
    return YES;
}
static BOOL DWNativePlacementInteger(id value,uint64_t *integer) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()
        ||CFNumberIsFloatType((__bridge CFNumberRef)value)||[value compare:@0]==NSOrderedAscending)return NO;
    *integer=[value unsignedLongLongValue];return [value isEqual:@(*integer)];
}
@interface DWNativeAppliedPlacement ()
- (instancetype)initWithSession:(NSUUID *)session sequence:(uint64_t)sequence description:(DWNativePlacementDescription *)description;
@property(nonatomic,readonly) DWNativePlacementDescription *placementDescription;
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

// The helper's lease clock and the library's: it stops while the machine sleeps, so a night asleep is not a hang.
static uint64_t uptime(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000000; }
// How long the main thread may stay away from its run loop before the session is closed for it.
static const uint64_t DWStall=10000;
// How long the last audited family of a root is kept when the window server's answer cannot be read again. Chromium's hover cards, tooltips and
// completion lists are windows that come without a parent or without a size for a few frames; every read that met one failed the whole report
// for 4 to 100 ms in the guest. A family the shell has just audited is still the best account of the windows it placed, and a root is not
// parked on account of a read that failed once. Past this the family is let go (children restored) as it always was.
static const uint64_t DWNativeFamilyGraceMS=500;
// One bound window: who it is for the helper, its own frame, and whether an alpha was ever sent for it.
@interface DWNativeWindow : NSObject { @public struct dw2_identity identity;CGRect bounds;BOOL alpha,familyKnown,declined;NSNumber *logical;uint64_t releaseSeq,familyAt;uint32_t root,parent; } @end
@interface DWNativeSpaceReflow : NSObject { @public
    struct dw2_identity identity;
    CGRect original,before,observed;
    uint64_t target,submittedAt,changedAt,acknowledgedSequence;
    BOOL settled,changed,nativeInput;
} @end
@implementation DWNativeSpaceReflow @end
@implementation DWNativeWindow @end
static const char *lostName(int reason) { return reason==DW_LOST_EOF?"the helper closed the connection":reason==DW_LOST_WRITE_TIMEOUT?"the helper stopped reading":reason==DW_LOST_HEARTBEAT?"no heartbeat was answered for a whole lease":"the helper broke the protocol"; }
static const char *statusName(uint8_t status) {
    static const char *names[]={"applied","out of the helper's scope","no such window of that process","matrix refused","alpha refused","its original could not be read","the journal could not be written","the set failed or read back differently","a restore of it is pending","the helper's table is full","malformed record","the window and destination do not have eligible display Spaces","the helper cannot safely read or change the native sublevel"};
    return status<sizeof(names)/sizeof(*names)?names[status]:"unknown status";
}
@interface DWNativePresenterGroup : DWNativePresenter
@property NSArray<DWNativePresenter *> *sessions;
@property NSDictionary<NSNumber *,DWNativePresenter *> *owners;
@property BOOL groupEnded,finished;
@end
@interface DWNativePresenter ()
- (BOOL)placementDescriptionCurrent:(DWNativePlacementDescription *)description;
- (dw_client *)takeActivity:(id __strong *)activity;
@end
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
@implementation DWNativePresenter {
    // Every call into the library is made under this lock and for that call only (each is bounded: two seconds at most), and the
    // pointer is cleared under it, so the watchdog's close on its own queue never meets a call on the main thread.
    os_unfair_lock _lock;
    dw_client *_client;
    id _activity; // travels with the client to its final close, including asynchronous restoration
    struct dw_client_info _info;
    NSDictionary<NSNumber *,NSArray<NSNumber *> *> *_scope;
    BOOL _desktopWide;
    BOOL _veiling; // the helper holds each window an application opens invisible until a frame places it, a release lets it go, or its own bound passes
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
    NSMutableDictionary<NSNumber *,DWNativeSpaceReflow *> *_spaceReflows;
    NSMutableDictionary<NSNumber *,NSSet<NSNumber *> *> *_families;
    NSMutableDictionary<NSNumber *,NSDictionary *> *_withheld;
    NSMutableDictionary<NSNumber *,NSData *> *_rebases; // exact temporary neutral records
    NSMutableDictionary<NSNumber *,DWNativeHiddenRoot *> *_transitions;
    NSMutableSet<NSNumber *> *_rebased; // neutral ACK received; awaiting omission ACK
    _Atomic bool _releasing;
    _Atomic bool _retrying;
    uint64_t _lastSent,_submittedSeq;
    NSMutableData *_records;                                    // the frame last described
    NSData *_recordSpaces,*_sentSpaces;                         // parallel uint64 targets; zero preserves membership
    NSData *_sent;                                              // the frame last handed over
    NSArray<NSNumber *> *_order,*_sentOrder;                    // the world window of each of their records, for -debug:
    BOOL _described,_forced;
    // Unanswered frames, by sequence number, for a record status that comes back; and what was said of one.
    NSMutableDictionary<NSNumber *,NSData *> *_frames;
    NSMutableSet<NSString *> *_said;
    NSUUID *_placementSession;
    NSDictionary<NSNumber *,DWNativePlacementDescription *> *_desiredPlacements,*_acknowledgedPlacements;
    NSMutableDictionary<NSNumber *,NSDictionary<NSNumber *,DWNativePlacementDescription *> *> *_framePlacements;
    uint64_t _acknowledgedSequence,_placementRevision;
}
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
- (BOOL)familiesNeeded { return _desktopWide||_info.scope==DW2_SCOPE_ALLOWLIST||(_info.scope==DW2_SCOPE_COOPERATIVE&&(_info.caps&DW2_CAP_FIXTURE_FAMILY)); }
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
// A record the helper did not apply: the window is not where the canvas shows it. Once per window and reason.
- (void)refused:(NSData *)statuses frame:(uint64_t)seq {
    NSData *frame=_frames[@(seq)];const struct dw2_record *records=frame.bytes;const uint8_t *status=statuses.bytes;
    BOOL currentFrame=!self.ended&&seq==_submittedSeq&&frame&&statuses.length==frame.length/sizeof(*records);
    if(currentFrame){
        NSMutableDictionary *acknowledged=[NSMutableDictionary dictionary];
        for(NSNumber *logical in _framePlacements[@(seq)]){
            DWNativePlacementDescription *description=_framePlacements[@(seq)][logical];
            if(![description isEqual:_desiredPlacements[logical]]||![self placementDescriptionCurrent:description])continue;
            const DWNativePlacementMember *members=description->members.bytes;BOOL applied=YES;
            for(NSUInteger i=0;i<description->members.length/sizeof(*members);i++){
                uint32_t index=members[i].index;
                if(index>=statuses.length||status[index]!=DW2_APPLIED||memcmp(&members[i].record,&records[index],sizeof(*records))){applied=NO;break;}
            }
            if(applied)acknowledged[logical]=description;
        }
        _acknowledgedPlacements=acknowledged.copy;_acknowledgedSequence=seq;
        for(DWNativePlacementDescription *description in acknowledged.objectEnumerator){
            DWNativeSpaceReflow *reflow=_spaceReflows[@(description->binding.identity.wid)];
            const DWNativePlacementMember *members=description->members.bytes;
            if(reflow&&description->members.length>=sizeof(*members)&&!memcmp(&reflow->identity,&description->binding.identity,sizeof(reflow->identity)))
                for(NSUInteger i=0;i<description->members.length/sizeof(*members);i++)if(members[i].record.id.wid==reflow->identity.wid&&members[i].targetSpace==reflow->target)
                    reflow->acknowledgedSequence=seq;
        }
        BOOL drained=NO;
        for(NSNumber *wid in _rebases.allKeys){NSData *expected=_rebases[wid];
            for(NSUInteger i=0;i<statuses.length;i++)if(records[i].id.wid==wid.unsignedIntValue&&status[i]==DW2_APPLIED
                &&expected.length==sizeof(*records)&&!memcmp(expected.bytes,&records[i],sizeof(*records))){
                [_rebases removeObjectForKey:wid];[_rebased addObject:wid];drained=YES;break;}
        }
        for(DWNativeHiddenRoot *transition in _transitions.objectEnumerator){
            if(transition->phase!=1&&transition->phase!=2&&transition->phase!=4)continue;
            for(NSUInteger i=0;i<statuses.length;i++)if(status[i]==DW2_APPLIED&&!memcmp(&transition->record,&records[i],sizeof(*records))){
                if(transition->phase==1){CGRect own=transition.nativeBounds;transition->record=(struct dw2_record){.id=transition->record.id,.flags=DW2_RECORD_HAS_ALPHA,.alpha=0,.m={1,0,0,1,-own.origin.x,-own.origin.y}};transition->phase=2;drained=YES;}
                else if(transition->phase==2){transition->phase=3;drained=YES;}
                else transition->phase=5;
                break;
            }
        }
        if(drained)[self requireFreshPlacementAcknowledgement];
    }
    BOOL retry=NO;
    for(NSUInteger i=0;i<statuses.length&&i<frame.length/sizeof(*records);i++){
        NSNumber *wid=@(records[i].id.wid);BOOL release=(records[i].flags&DW2_RECORD_RESTORE)!=0;
        // A decline is a hint that spares the helper's own bound: whatever it answers, it is not asked again.
        DWNativeWindow *declined=release?_releases[wid]:nil;
        if(declined&&declined->declined&&declined->releaseSeq&&seq>=declined->releaseSeq){[_releases removeObjectForKey:wid];_forced=YES;continue;}
        if(status[i]==DW2_APPLIED){
            DWNativeWindow *pending=_releases[wid];
            if(release&&pending&&pending->releaseSeq&&seq>=pending->releaseSeq){[_releases removeObjectForKey:wid];_forced=YES;}
            continue;
        }
        if(status[i]==DW2_NOT_APPLIED||status[i]==DW2_RESTORE_PENDING||status[i]==DW2_SNAPSHOT||status[i]==DW2_JOURNAL||status[i]==DW2_SPACE)retry=YES;
        NSString *key=[NSString stringWithFormat:@"%@:%u:%d",wid,status[i],release];if([_said containsObject:key])continue;[_said addObject:key];
        fprintf(stderr,"Infinify: native presentation: window %u of process %d not %s: %s\n",wid.unsignedIntValue,records[i].id.pid,release?"restored":"placed",statusName(status[i]));
    }
    atomic_store(&_releasing,_releases.count!=0);
    // A rebind can race the helper's pending restoration. Once input stops, keep
    // retrying the latest complete frame until that restore no longer blocks it.
    // Old acknowledgements must not clear a newer frame's retry requirement.
    if(frame&&seq==_submittedSeq)atomic_store(&_retrying,retry);
    // The client accepts a complete reply only for a written frame and accounts
    // for every older unanswered write as superseded before calling us. Those
    // frames can never receive another result. Keep the acknowledged placement
    // descriptions through _acknowledgedPlacements, but release their duplicate
    // history and locally coalesced frames now, rather than after 65 submissions.
    // A missing or short substituted reply does not settle any history.
    if(frame&&statuses.length==frame.length/sizeof(*records))for(NSNumber *resolved in _frames.allKeys)if(resolved.unsignedLongLongValue<=seq){
        [_frames removeObjectForKey:resolved];[_framePlacements removeObjectForKey:resolved];
    }
    // The callback can describe/submit the next transition frame. Finish all
    // ACK bookkeeping first so a reentrant submission retains its own history.
    if(currentFrame&&!self.ended&&self.transitionFrameAcknowledged)self.transitionFrameAcknowledged();
}
- (void)invalidatePlacementReadiness {
    _acknowledgedPlacements=@{};_acknowledgedSequence=0;++_placementRevision;
}
- (void)requireFreshPlacementAcknowledgement {
    if(!NSThread.isMainThread||self.ended)return;
    [self invalidatePlacementReadiness];_described=NO;_forced=YES;
}
- (BOOL)placementDescriptionCurrent:(DWNativePlacementDescription *)description {
    if(!description||self.ended||description->binding.revision!=_placementRevision)return NO;
    const DWNativePlacementBinding *binding=&description->binding;
    DWNativeWindow *root=_windows[@(binding->identity.wid)];NSSet *family=_families[@(binding->identity.wid)];
    NSUInteger count=description->members.length/sizeof(DWNativePlacementMember);
    if(!root||!root->familyKnown||memcmp(&root->identity,&binding->identity,sizeof(root->identity))||root->root!=binding->identity.wid
        ||!family.count||family.count!=count||![root->logical isEqual:@(binding->window)])return NO;
    const DWNativePlacementMember *members=description->members.bytes;
    for(NSUInteger i=0;i<count;i++){
        const DWNativePlacementMember *member=&members[i];DWNativeWindow *current=_windows[@(member->record.id.wid)];
        if(!current||![family containsObject:@(member->record.id.wid)]||current->root!=binding->identity.wid
            ||current->parent!=member->parent||memcmp(&current->identity,&member->record.id,sizeof(current->identity))||!CGRectEqualToRect(current->bounds,member->native))return NO;
    }
    return YES;
}
- (DWNativeAppliedPlacement *)acknowledgedPlacementForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation output:(NSNumber *)output {
    uint64_t wantedWindow=0,wantedGeneration=0,wantedOutput=0;
    if(!NSThread.isMainThread||self.ended||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq||!DWNativePlacementInteger(window,&wantedWindow))return nil;
    DWNativePlacementDescription *description=_acknowledgedPlacements[window];
    if(!description||description->parked||description->binding.window!=wantedWindow||!DWNativePlacementInteger(generation,&wantedGeneration)||!DWNativePlacementInteger(output,&wantedOutput)
        ||description->binding.generation!=wantedGeneration||description->binding.output!=wantedOutput
        ||![DWNativePlacementIdentity(description->binding.identity)isEqual:identity]
        ||![description isEqual:_desiredPlacements[window]]||![self placementDescriptionCurrent:description])return nil;
    return [[DWNativeAppliedPlacement alloc]initWithSession:_placementSession sequence:_acknowledgedSequence description:description];
}
- (BOOL)isParkingAcknowledgedForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation {
    uint64_t wantedWindow=0,wantedGeneration=0;
    if(!NSThread.isMainThread||self.ended||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq
        ||!DWNativePlacementInteger(window,&wantedWindow)||!DWNativePlacementInteger(generation,&wantedGeneration))return NO;
    DWNativePlacementDescription *description=_acknowledgedPlacements[window];
    if(!description||!description->parked||description->binding.window!=wantedWindow||description->binding.generation!=wantedGeneration
        ||description->binding.output||_withheld[@(description->binding.identity.wid)]
        ||![DWNativePlacementIdentity(description->binding.identity)isEqual:identity]
        ||![description isEqual:_desiredPlacements[window]]||![self placementDescriptionCurrent:description])return NO;
    const DWNativePlacementMember *members=description->members.bytes;
    for(NSUInteger i=0;i<description->members.length/sizeof(*members);i++){
        const struct dw2_record *record=&members[i].record;
        if(members[i].targetSpace||(record->flags&DW2_RECORD_RESTORE)||record->m[0]!=1||record->m[1]!=0||record->m[2]!=0||record->m[3]!=1)return NO;
    }
    return YES;
}
- (BOOL)isAcknowledgedPlacementCurrent:(DWNativeAppliedPlacement *)placement {
    if(!NSThread.isMainThread||self.ended||![placement isKindOfClass:DWNativeAppliedPlacement.class]
        ||placement.session!=_placementSession||!_acknowledgedSequence||placement.sequence!=_acknowledgedSequence||placement.sequence!=_submittedSeq)return NO;
    DWNativePlacementDescription *description=placement.placementDescription;
    return description&&!description->parked&&description==_acknowledgedPlacements[@(placement.window)]&&[description isEqual:_desiredPlacements[@(placement.window)]]&&[self placementDescriptionCurrent:description];
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
    DWNativeWindow *window=_windows[root];if(window&&window->familyKnown){window->familyKnown=NO;[self invalidatePlacementReadiness];}
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
    if(!CGRectEqualToRect(window->bounds,native)){[self invalidatePlacementReadiness];window->bounds=native;_forced=YES;}
    // A cooperative helper's narrow scope does not supply native ancestry.
    // Receipt readiness in every scope requires an actual audited family report.
    // Without one, retain the existing ordinary placement rather than discovering
    // additional windows outside that helper's explicitly enrolled WID scope.
    if(!self.familiesNeeded&&!family){
        if(window->familyKnown){window->familyKnown=NO;[self invalidatePlacementReadiness];}
        return;
    }
    NSString *why=nil;if(!family)family=DWNativeWindowFamily(identity,&why);
    // A report that could not be read (nil, or the empty marker of a requested audit that failed) is not a report of a changed family: a root whose
    // family was audited a moment ago keeps it, with its children placed, until the next read; one that stays unreadable is let go as before.
    if((!family||![family isKindOfClass:NSDictionary.class]||!family.count)&&window->familyKnown&&uptime()-window->familyAt<DWNativeFamilyGraceMS){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native family kept root=%u reason=%s\n",wid.unsignedIntValue,why.UTF8String?:"unreadable");
        return;
    }
    if(!family||![family[@"identity"]isEqual:identity]||![family[@"root"]isEqual:wid]){
        [self forgetChildrenOf:wid reason:why?:@"identity changed"];return;
    }
    NSArray *report=[family[@"members"]isKindOfClass:NSArray.class]?family[@"members"]:nil;
    if(!report.count||report.count>64){[self forgetChildrenOf:wid reason:@"missing or unbounded family report"];return;}
    NSMutableSet<NSNumber *> *members=[NSMutableSet set];NSMutableDictionary<NSNumber *,NSNumber *> *parents=[NSMutableDictionary dictionary];BOOL sound=YES;
    // Validate the whole report before installing any child. A separately bound
    // root or a child already belonging to another root makes it ambiguous.
    for(id value in report){
        if(![value isKindOfClass:NSDictionary.class]){sound=NO;break;}NSDictionary *member=value,*who=member[@"identity"],*frame=member[@"native_bounds"];
        if(![who isKindOfClass:NSDictionary.class]||![frame isKindOfClass:NSDictionary.class]){sound=NO;break;}
        NSNumber *child=who[@"wid"];uint64_t childID=0,parent=0;
        if(!DWNativePlacementInteger(child,&childID)||!childID||childID>UINT32_MAX
            ||!DWNativePlacementInteger(member[@"parent"],&parent)||parent>UINT32_MAX
            ||([child isEqual:wid]?parent!=0:parent==0)){sound=NO;break;}
        DWNativeWindow *existing=_windows[child];
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
        [members addObject:child];parents[child]=@(parent);
    }
    // Preserve the reported topology, rather than treating missing parents as
    // roots or trusting a root label without a complete acyclic parent chain.
    if(sound)for(NSNumber *child in members){
        NSNumber *cursor=child;NSMutableSet *seen=[NSMutableSet set];
        while(![cursor isEqual:wid]){
            if([seen containsObject:cursor]||!parents[cursor]||![members containsObject:parents[cursor]]){sound=NO;break;}
            [seen addObject:cursor];cursor=parents[cursor];
        }
        if(!sound)break;
    }
    if(!sound||![members containsObject:wid]){[self forgetChildrenOf:wid reason:@"inconsistent, duplicate or changed family member"];return;}
    for(NSNumber *old in _families[wid])if(![members containsObject:old]){DWNativeWindow *removed=_windows[old];if(removed)[self releaseWindow:removed];}
    for(NSDictionary *member in report){
        NSDictionary *who=member[@"identity"];NSNumber *child=who[@"wid"];
        NSDictionary *origin=member[@"native_bounds"][@"origin"],*size=member[@"native_bounds"][@"size"];
        CGRect frame=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);
        DWNativeWindow *attached=_windows[child];if(!attached){attached=_windows[child]=[DWNativeWindow new];attached->identity=window->identity;attached->identity.wid=child.unsignedIntValue;attached->root=wid.unsignedIntValue;attached->bounds=CGRectNull;_forced=YES;}
        if(_releases[child]){[_releases removeObjectForKey:child];atomic_store(&_releasing,_releases.count!=0);_forced=YES;}
        uint32_t parent=[parents[child]unsignedIntValue];
        if(attached->parent!=parent){[self invalidatePlacementReadiness];attached->parent=parent;_forced=YES;}
        if(!CGRectEqualToRect(attached->bounds,frame)){[self invalidatePlacementReadiness];attached->bounds=frame;_forced=YES;}
    }
    _families[wid]=members.copy;window->familyAt=uptime();if(!window->familyKnown){window->familyKnown=YES;[self invalidatePlacementReadiness];}
}
- (void)releaseWindow:(DWNativeWindow *)window {
    [self invalidatePlacementReadiness];
    [_spaceReflows removeObjectForKey:@(window->identity.wid)];
    NSNumber *wid=@(window->identity.wid);[_windows removeObjectForKey:wid];if(self.ended)return;
    window->releaseSeq=0;_releases[wid]=window;atomic_store(&_releasing,true);_forced=YES;
}
- (BOOL)observeSpaceReflow:(NSDictionary *)identity bounds:(CGRect)native nativeInput:(BOOL)nativeInput {
    if(!NSThread.isMainThread||self.ended)return NO;
    DWNativeSpaceReflow *reflow=_spaceReflows[identity[@"wid"]];
    if(!reflow||![DWNativePlacementIdentity(reflow->identity)isEqual:identity])return NO;
    if(reflow->settled)return NO;
    uint64_t now=uptime();
    if(!CGRectEqualToRect(reflow->observed,native)){
        reflow->observed=native;reflow->changedAt=now;reflow->changed=YES;
        if(!reflow->settled)reflow->acknowledgedSequence=0;
    }
    if(nativeInput){reflow->nativeInput=YES;reflow->settled=YES;return NO;}
    // Space membership ACK can precede AppKit's asynchronous reflow. Keep a
    // two-second settling window and require a quiet frame plus a fresh ACK
    // after every observed geometry change. The final observation is still
    // basis-only; later equal observations must not resize the world again.
    if(reflow->acknowledgedSequence&&now-reflow->submittedAt>=2000&&now-reflow->changedAt>=250)reflow->settled=YES;
    return YES;
}
- (void)unbound:(NSDictionary *)identity {
    NSNumber *wid=identity[@"wid"];DWNativeWindow *window=wid?_windows[wid]:nil;if(!window)return;
    if(window->identity.pid!=[identity[@"pid"]intValue]||window->identity.birth_sec!=[identity[@"birth_sec"]unsignedLongLongValue]||window->identity.birth_usec!=[identity[@"birth_usec"]unsignedLongLongValue])return;
    [_withheld removeObjectForKey:wid];[_transitions removeObjectForKey:wid];[_rebases removeObjectForKey:wid];[_rebased removeObject:wid];
    NSSet *members=_families[wid]?:[NSSet setWithObject:wid];for(NSNumber *child in members){DWNativeWindow *attached=_windows[child];if(attached)[self releaseWindow:attached];}[_families removeObjectForKey:wid];
}
// A window this shell will not manage, which the helper's arrival veil may hold invisible: asked to release it now. The helper
// answers a release of a window it holds nothing of with a no-op, and lets the window go itself after its own bound otherwise.
- (void)declineWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended||!_veiling)return;
    NSNumber *wid=identity[@"wid"];NSArray *born=[self admittedBirth:identity];
    if(!wid.unsignedIntValue||born.count!=2||![born[0]isEqual:identity[@"birth_sec"]]||![born[1]isEqual:identity[@"birth_usec"]]||_windows[wid]||_releases[wid])return;
    DWNativeWindow *window=[DWNativeWindow new];
    window->identity=(struct dw2_identity){.pid=[identity[@"pid"]intValue],.wid=wid.unsignedIntValue,.birth_sec=[born[0]unsignedLongLongValue],.birth_usec=[born[1]unsignedLongLongValue]};
    window->bounds=CGRectNull;window->root=wid.unsignedIntValue;window->declined=YES;window->releaseSeq=0;
    _releases[wid]=window;atomic_store(&_releasing,true);_forced=YES;
}
- (BOOL)withholdWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended)return NO;
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=wid?_windows[wid]:nil;
    if(!root||root->root!=wid.unsignedIntValue||![DWNativePlacementIdentity(root->identity)isEqual:identity])return NO;
    if(![_withheld[wid]isEqual:identity]){_withheld[wid]=identity.copy;[self requireFreshPlacementAcknowledgement];}
    return YES;
}
- (BOOL)isWindowWithheld:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended||![_withheld[identity[@"wid"]]isEqual:identity]
        ||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq)return NO;
    const struct dw2_record *records=_sent.bytes;
    NSSet *family=_families[identity[@"wid"]];if(!family.count)return NO;
    for(NSUInteger i=0;i<_sent.length/sizeof(*records);i++)if([family containsObject:@(records[i].id.wid)])return NO;
    return YES;
}
- (void)resumeWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||![_withheld[identity[@"wid"]]isEqual:identity])return;
    [_withheld removeObjectForKey:identity[@"wid"]];[_transitions removeObjectForKey:identity[@"wid"]];[_rebases removeObjectForKey:identity[@"wid"]];[_rebased removeObject:identity[@"wid"]];[self requireFreshPlacementAcknowledgement];
}
- (BOOL)canRebaseWindow:(NSDictionary *)identity {
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=_windows[wid];
    return [self isWindowWithheld:identity]&&root&&root->familyKnown&&root->root==wid.unsignedIntValue
        &&[DWNativePlacementIdentity(root->identity)isEqual:identity]&&_families[wid].count==1&&!_rebases[wid]&&![_rebased containsObject:wid];
}
- (BOOL)rebaseWindow:(NSDictionary *)identity bounds:(CGRect)native {
    if(![self canRebaseWindow:identity]||!DWFiniteRect(native)||fabs(native.origin.x)>1e6||fabs(native.origin.y)>1e6)return NO;
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=_windows[wid];
    if(fabs(root->bounds.size.width-native.size.width)>1||fabs(root->bounds.size.height-native.size.height)>1)return NO;
    struct dw2_record record={.id=root->identity,.m={1,0,0,1,-native.origin.x,-native.origin.y}};
    root->bounds=native;_rebases[wid]=[NSData dataWithBytes:&record length:sizeof(record)];[self requireFreshPlacementAcknowledgement];return YES;
}
- (BOOL)isWindowRebased:(NSDictionary *)identity {
    return NSThread.isMainThread&&[_rebased containsObject:identity[@"wid"]]&&_families[identity[@"wid"]].count==1&&[self isWindowWithheld:identity];
}
- (void)cancelRebaseWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||![_withheld[identity[@"wid"]]isEqual:identity])return;
    [_rebases removeObjectForKey:identity[@"wid"]];[_rebased removeObject:identity[@"wid"]];[self requireFreshPlacementAcknowledgement];
}
- (DWNativeHiddenRoot *)beginTransitionForWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended||!(_info.caps&DW2_CAP_ALPHA))return nil;
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=_windows[wid];
    if(!root||!root->familyKnown||root->root!=wid.unsignedIntValue||_families[wid].count!=1||_withheld[wid]
        ||![DWNativePlacementIdentity(root->identity)isEqual:identity]||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq)return nil;
    DWNativePlacementDescription *found=nil;
    for(DWNativePlacementDescription *description in _acknowledgedPlacements.objectEnumerator)
        if(!description->parked&&description->binding.identity.wid==wid.unsignedIntValue&&[description isEqual:_desiredPlacements[@(description->binding.window)]]&&[self placementDescriptionCurrent:description]){found=description;break;}
    if(!found||found->members.length!=sizeof(DWNativePlacementMember))return nil;
    const DWNativePlacementMember *member=found->members.bytes;
    DWNativeHiddenRoot *transition=[[DWNativeHiddenRoot alloc]initWithSession:_placementSession];transition.identity=identity;transition.nativeBounds=member->native;transition.screenRect=found->binding.screen;transition->record=member->record;
    if(![self withholdWindow:identity])return nil;_transitions[wid]=transition;return transition;
}
- (BOOL)transitionCurrent:(DWNativeHiddenRoot *)transition {
    if(!transition)return NO;
    NSNumber *wid=transition.identity[@"wid"];DWNativeWindow *root=_windows[wid];
    return NSThread.isMainThread&&!self.ended&&transition&&transition->session==_placementSession&&_transitions[wid]==transition
        &&[_withheld[wid]isEqual:transition.identity]&&root&&root->familyKnown&&_families[wid].count==1&&[DWNativePlacementIdentity(root->identity)isEqual:transition.identity];
}
- (BOOL)hideTransition:(DWNativeHiddenRoot *)transition {
    if(![self transitionCurrent:transition]||transition->phase!=0||![self isWindowWithheld:transition.identity])return NO;
    transition->record.flags=(transition->record.flags&~DW2_RECORD_PINNED)|DW2_RECORD_HAS_ALPHA;transition->record.alpha=0;transition->phase=1;
    // Normal frames must explicitly restore alpha after this temporary write.
    _windows[transition.identity[@"wid"]]->alpha=YES;[self requireFreshPlacementAcknowledgement];return YES;
}
- (BOOL)isTransitionHidden:(DWNativeHiddenRoot *)transition {
    return [self transitionCurrent:transition]&&transition->phase==3&&[self isWindowWithheld:transition.identity];
}
- (BOOL)revealTransition:(DWNativeHiddenRoot *)transition screen:(CGRect)screen alpha:(double)alpha {
    if(![self isTransitionHidden:transition]||!DWFiniteRect(screen)||!isfinite(alpha)||alpha<0||alpha>1)return NO;
    DWNativeWindow *root=_windows[transition.identity[@"wid"]];CGRect native=root->bounds;
    if(!DWFiniteRect(native))return NO;
    double mx=native.size.width/screen.size.width,my=native.size.height/screen.size.height;
    struct dw2_record record={.id=root->identity,.flags=DW2_RECORD_HAS_ALPHA,.alpha=(float)alpha,.m={mx,0,0,my,-screen.origin.x*mx,-screen.origin.y*my}};
    for(NSUInteger i=0;i<6;i++)if(!isfinite(record.m[i])||fabs(record.m[i])>1e6)return NO;
    transition->record=record;transition->phase=4;[self requireFreshPlacementAcknowledgement];return YES;
}
- (BOOL)isTransitionRevealed:(DWNativeHiddenRoot *)transition {
    return [self transitionCurrent:transition]&&transition->phase==5&&_acknowledgedSequence&&_acknowledgedSequence==_submittedSeq;
}
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    atomic_store(&_turned,uptime());
    if(self.ended)return;
    if(![snapshot[@"outputs"]isKindOfClass:NSArray.class]||![snapshot[@"outputs"]count]){[self invalidatePlacementReadiness];_desiredPlacements=@{};_described=NO;return;}
    // One placement per window: where it is shown on several outputs, the one that shows most of it. A transform has one target.
    NSMutableDictionary<NSNumber *,NSDictionary *> *placed=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *shown=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSValue *> *viewports=[NSMutableDictionary dictionary];
    BOOL spaceFrames=_desktopWide&&(_info.caps&DW2_CAP_SPACE);
    NSMutableDictionary<NSNumber *,NSNumber *> *outputSpaces=[NSMutableDictionary dictionary],*windowSpaces=[NSMutableDictionary dictionary];
    for(NSDictionary *output in snapshot[@"outputs"]){CGRect viewport=DWNativeJSONRect(output[@"screen_bounds"]);NSNumber *identifier=output[@"id"];
        if([identifier isKindOfClass:NSNumber.class]&&!CGRectIsNull(viewport)){
            viewports[identifier]=[NSValue valueWithRect:NSRectFromCGRect(viewport)];
            if(spaceFrames)outputSpaces[identifier]=@(DWNativePresentationDisplaySpace(viewport));
        }}
    for(NSDictionary *p in snapshot[@"placements"]){
        NSNumber *logical=p[@"window"];NSDictionary *clip=p[@"clip_rect"][@"size"];if(!logical||!identities[logical])continue;
        double area=[clip[@"width"]doubleValue]*[clip[@"height"]doubleValue];if(placed[logical]&&area<=shown[logical].doubleValue)continue;
        placed[logical]=p;shown[logical]=@(area);
    }
    // Beyond every display, by a translation alone: the window keeps its size and is drawn nowhere. 256 points clear of the far
    // corner of the displays' union, so that neither the window nor its shadow reaches one.
    CGRect all=CGRectNull;CGFloat top=NSMaxY(NSScreen.screens.firstObject.frame);
    for(NSScreen *screen in NSScreen.screens)all=CGRectUnion(all,CGRectMake(screen.frame.origin.x,top-NSMaxY(screen.frame),screen.frame.size.width,screen.frame.size.height));
    if(CGRectIsNull(all)){[self invalidatePlacementReadiness];_desiredPlacements=@{};_described=NO;return;}
    double parkX=ceil(CGRectGetMaxX(all))+256,parkY=ceil(CGRectGetMaxY(all))+256;
    NSMutableDictionary<NSNumber *,NSNumber *> *logicals=[NSMutableDictionary dictionary];
    for(NSNumber *logical in identities){NSNumber *wid=identities[logical][@"wid"];DWNativeWindow *root=_windows[wid];if(!root||root->root!=wid.unsignedIntValue)continue;for(NSNumber *member in _families[wid]?:[NSSet setWithObject:wid])if(_windows[member])logicals[member]=logical;}
    [_records setLength:0];NSMutableArray<NSNumber *> *order=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,DWNativePlacementDescription *> *desired=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSMutableData *> *memberData=[NSMutableDictionary dictionary];
    for(NSNumber *logical in placed){
        NSDictionary *p=placed[logical],*source=[p[@"source"]isKindOfClass:NSDictionary.class]?p[@"source"]:nil;
        uint64_t identifier=0,generation=0,output=0;CGRect screen=DWNativeJSONRect(p[@"screen_rect"]),clip=DWNativeJSONRect(p[@"clip_rect"]);
        NSValue *viewport=viewports[p[@"output"]];DWNativeWindow *root=_windows[identities[logical][@"wid"]];
        if(!root||_withheld[@(root->root)]||!root->familyKnown||![DWNativePlacementIdentity(root->identity)isEqual:identities[logical]]||!DWNativePlacementSourceMatches(source[@"identity"],identities[logical])
            ||![source[@"observation_known"]isEqual:@YES]||!DWNativePlacementInteger(logical,&identifier)
            ||!DWNativePlacementInteger(source[@"generation"],&generation)||!DWNativePlacementInteger(p[@"output"],&output)
            ||!viewport||CGRectIsNull(screen)||CGRectIsNull(clip)||screen.size.width<1||screen.size.height<1)continue;
        DWNativePlacementDescription *description=[DWNativePlacementDescription new];
        description->binding=(DWNativePlacementBinding){.identity=root->identity,.window=identifier,.generation=generation,.output=output,
            .revision=_placementRevision,.screen=screen,.clip=clip,.viewport=NSRectToCGRect(viewport.rectValue)};
        desired[logical]=description;memberData[logical]=[NSMutableData data];
    }
    // An omitted placement still has a controller source binding. Retain a
    // separate kind of ACK correspondence for its complete parked family;
    // never manufacture an output/placement receipt for that backing source.
    for(NSDictionary *row in snapshot[@"windows"]){
        if(![row isKindOfClass:NSDictionary.class])continue;
        NSNumber *logical=row[@"window"];NSDictionary *identity=logical?identities[logical]:nil,*source=[row[@"source"]isKindOfClass:NSDictionary.class]?row[@"source"]:nil;
        DWNativeWindow *root=identity?_windows[identity[@"wid"]]:nil;uint64_t identifier=0,generation=0;
        if(!root||placed[logical]||desired[logical]||root->root!=root->identity.wid||!root->familyKnown||_withheld[@(root->root)]
            ||![DWNativePlacementIdentity(root->identity)isEqual:identity]||!DWNativePlacementSourceMatches(source[@"identity"],identity)
            ||![source[@"observation_known"]isEqual:@YES]||!DWFiniteRect(root->bounds)||!CGRectEqualToRect(DWNativeJSONRect(source[@"observed_rect"]),root->bounds)
            ||!DWNativePlacementInteger(logical,&identifier)||!identifier||!DWNativePlacementInteger(source[@"generation"],&generation)||!generation)continue;
        DWNativePlacementDescription *description=[DWNativePlacementDescription new];description->parked=YES;
        description->binding=(DWNativePlacementBinding){.identity=root->identity,.window=identifier,.generation=generation,.revision=_placementRevision};
        desired[logical]=description;memberData[logical]=[NSMutableData data];
    }
    // In the order of the window numbers: the same scene is then the same bytes, and is not sent twice.
    for(NSNumber *wid in [logicals.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        DWNativeWindow *window=_windows[wid];NSDictionary *p=placed[logicals[wid]];CGSize own=window->bounds.size;
        if(_withheld[@(window->root)]){
            DWNativeHiddenRoot *transition=_transitions[wid];
            if(transition&&[self transitionCurrent:transition]&&(transition->phase==1||transition->phase==2||transition->phase==4||transition->phase==5)){
                [_records appendBytes:&transition->record length:sizeof(transition->record)];[order addObject:logicals[wid]];
            }
            NSData *neutral=_rebases[wid];
            if(neutral&&window->root==wid.unsignedIntValue&&window->familyKnown&&_families[wid].count==1){[_records appendData:neutral];[order addObject:logicals[wid]];}
            continue;
        }
        window->logical=logicals[wid];
        struct dw2_record record={.id=window->identity,.m={1,0,0,1,-parkX,-parkY}};
        NSDictionary *origin=p[@"screen_rect"][@"origin"],*size=p[@"screen_rect"][@"size"];
        double sx=[origin[@"x"]doubleValue],sy=[origin[@"y"]doubleValue],sw=[size[@"width"]doubleValue],sh=[size[@"height"]doubleValue];
        DWNativeWindow *root=_windows[@(window->root)];CGSize rootSize=root?root->bounds.size:own;BOOL nativePlaced=NO;
        if(p&&sw>=1&&sh>=1&&own.width>0&&own.height>0&&rootSize.width>0&&rootSize.height>0){
            // Screen to window-local (DWHelperProtocol.h): the window's own width and height are drawn across the placement's.
            uint64_t targetSpace=spaceFrames?[outputSpaces[p[@"output"]]unsignedLongLongValue]:0;
            double mx=rootSize.width/sw,my=rootSize.height/sh;
            double dx=root?window->bounds.origin.x-root->bounds.origin.x:0,dy=root?window->bounds.origin.y-root->bounds.origin.y:0;
            double m[6]={mx,0,0,my,-sx*mx-dx,-sy*my-dy};
            // Space ownership belongs to the complete audited family. Losing that report must not move a root to another Space while its
            // children are restored; it does not hide the root either: a root that is placed stays placed, and only its Space request waits
            // for the family. Parking it hid the window until the next good audit, and an audit fails whenever a frame is read mid-resize,
            // a member has no readable parent or size, or a Chromium window meets a transient child with no parent or size yet
            // (parked, its main window vanished for 4 to 339 ms of each such read: the browser "flashing"). Context menus are no such
            // member: the guest's audits took every level-101 context menu measured as a child of its root (native/desktop/README.md,
            // "Popups and menus of a transformed window").
            BOOL sound=!spaceFrames||(targetSpace!=0&&root),spaceSound=sound&&(!spaceFrames||root->familyKnown);
            // The helper's bounds on a matrix; a placement they cannot express (a window a million points off, a zoom of a thousandth) is parked.
            for(int i=0;i<6;i++)if(!isfinite(m[i])||fabs(m[i])>1e6)sound=NO;
            if(sound){
                memcpy(record.m,m,sizeof(m));nativePlaced=YES;
                if(targetSpace&&spaceSound)windowSpaces[wid]=@(targetSpace);
                NSValue *viewport=viewports[p[@"output"]];DWNativeClipGeometry geometry={0};
                if(viewport&&root&&DWNativeClipPlacement(window->bounds,root->bounds,CGRectMake(sx,sy,sw,sh),NSRectToCGRect(viewport.rectValue),&geometry)&&geometry.required){
                    NSString *key=[NSString stringWithFormat:@"clip:%d:%llu:%llu:%u",window->identity.pid,(unsigned long long)window->identity.birth_sec,(unsigned long long)window->identity.birth_usec,window->identity.wid];
                    if(![_said containsObject:key]){[_said addObject:key];fprintf(stderr,"Infinify: native window %u of process %d needs display clipping; the helper cannot restore original native regions yet, so its transformed content may extend outside the selected output\n",window->identity.wid,window->identity.pid);}
                }
            }
        }
        // INFINIFY_DEBUG: one line when a window starts or stops being parked, and why, so a window that vanishes is explained.
        if(getenv("INFINIFY_DEBUG")){
            static NSMutableSet *parkedWindows;if(!parkedWindows)parkedWindows=[NSMutableSet set];
            BOOL was=[parkedWindows containsObject:wid];
            if(!nativePlaced&&!was){[parkedWindows addObject:wid];fprintf(stderr,"debug: native park begin wid=%u placement=%d screen=%gx%g own=%gx%g root=%gx%g family_known=%d reason=%s\n",window->identity.wid,p!=nil,sw,sh,own.width,own.height,rootSize.width,rootSize.height,root?root->familyKnown:-1,!p?"no_placement":!(sw>=1&&sh>=1)?"screen_extent":!(own.width>0&&own.height>0&&rootSize.width>0&&rootSize.height>0)?"native_extent":"matrix_or_space");}
            else if(nativePlaced&&was){[parkedWindows removeObject:wid];fprintf(stderr,"debug: native park end wid=%u\n",window->identity.wid);}
        }
        // Alpha is sent for a window from the first frame its opacity is not 1, and from then on always, 1 included: a window whose
        // alpha nobody asked to change is never written, and the helper journals no alpha for it. The one exception is a window the
        // helper's arrival veil holds: the helper lifts that alpha itself with the first frame, and puts it back only while it still reads 0.
        double opacity=[p[@"opacity"]isKindOfClass:NSNumber.class]?fmax(0,fmin(1,[p[@"opacity"]doubleValue])):1;
        if(p&&opacity!=1&&(_info.caps&DW2_CAP_ALPHA))window->alpha=YES;
        if(window->alpha){record.flags=DW2_RECORD_HAS_ALPHA;record.alpha=(float)opacity;}
        DWNativePlacementDescription *description=desired[logicals[wid]];
        if(!nativePlaced&&(!description||!description->parked)){[desired removeObjectForKey:logicals[wid]];[memberData removeObjectForKey:logicals[wid]];description=nil;}
        if(description){DWNativePlacementMember member={.record=record,.targetSpace=[windowSpaces[wid]unsignedLongLongValue],.native=window->bounds,.index=(uint32_t)(_records.length/sizeof(record)),.parent=window->parent};[memberData[logicals[wid]]appendBytes:&member length:sizeof(member)];}
        [_records appendBytes:&record length:sizeof(record)];[order addObject:logicals[wid]];
    }
    for(NSNumber *wid in [_releases.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        DWNativeWindow *window=_releases[wid];struct dw2_record record={.id=window->identity,.flags=DW2_RECORD_RESTORE};
        [_records appendBytes:&record length:sizeof(record)];[order addObject:window->logical?:wid];
    }
    NSMutableData *spaceRequests=[NSMutableData dataWithLength:(_records.length/sizeof(struct dw2_record))*sizeof(uint64_t)];
    const struct dw2_record *described=_records.bytes;uint64_t *spaces=spaceRequests.mutableBytes;
    for(NSUInteger i=0;i<_records.length/sizeof(*described);i++)spaces[i]=[windowSpaces[@(described[i].id.wid)]unsignedLongLongValue];
    _recordSpaces=spaceRequests.copy;
    for(NSNumber *logical in desired){
        DWNativePlacementDescription *description=desired[logical];NSMutableData *data=memberData[logical];
        NSDictionary *placement=placed[logical];
        // Apply the pin policy only after every member has a valid placement.
        // Parking, hidden transitions and ordinary frames omit the bit, asking
        // the helper to restore the journalled sublevel without changing focus.
        if(!description->parked&&[placement[@"pinned"]isEqual:@YES]
            &&(![placement[@"opacity"]isKindOfClass:NSNumber.class]||[placement[@"opacity"]doubleValue]>0)){
            DWNativePlacementMember *members=data.mutableBytes;struct dw2_record *records=_records.mutableBytes;
            for(NSUInteger i=0;i<data.length/sizeof(*members);i++){
                members[i].record.flags|=DW2_RECORD_PINNED;
                records[members[i].index].flags|=DW2_RECORD_PINNED;
            }
        }
        description->members=data.copy;
    }
    if(![_desiredPlacements isEqualToDictionary:desired]){
        [self invalidatePlacementReadiness];_forced=YES;for(DWNativePlacementDescription *description in desired.objectEnumerator)description->binding.revision=_placementRevision;
    }
    _desiredPlacements=desired.copy;_order=order;_described=YES;
}
- (void)submit {
    BOOL retry=_releases.count||atomic_load(&_retrying);
    if(self.ended||!_described||(!_forced&&[_records isEqualToData:_sent]&&[_recordSpaces isEqualToData:_sentSpaces]&&(!retry||uptime()-_lastSent<250)))return;
    NSUInteger count=_records.length/sizeof(struct dw2_record);
    // A frame describes every bound window except an explicitly withheld family,
    // which has no placement receipt. Never truncate the remaining frame.
    if(count>_info.max_records){fprintf(stderr,"Infinify: native presentation ended: %lu windows exceed the helper's frame limit of %u; restoring all windows\n",(unsigned long)count,_info.max_records);[self finish];return;}
    if(!(_info.caps&DW2_CAP_PINNED)){
        const struct dw2_record *records=_records.bytes;
        for(NSUInteger i=0;i<count;i++)if(records[i].flags&DW2_RECORD_PINNED){
            fprintf(stderr,"Infinify: native presentation ended: pinned windows require the helper's journalled sublevel capability; restoring all windows\n");
            [self finish];return;
        }
    }
    BOOL spaceFrames=_desktopWide&&(_info.caps&DW2_CAP_SPACE);
    NSMutableData *extended=nil;
    if(spaceFrames){
        if(_recordSpaces.length!=count*sizeof(uint64_t))return;
        extended=[NSMutableData dataWithLength:count*sizeof(struct dw2_space_record)];
        struct dw2_space_record *out=extended.mutableBytes;const struct dw2_record *in=_records.bytes;const uint64_t *spaces=_recordSpaces.bytes;
        for(NSUInteger i=0;i<count;i++)out[i]=(struct dw2_space_record){.record=in[i],.target_space=spaces[i]};
    }
    uint64_t seq=0;os_unfair_lock_lock(&_lock);
    int result=!_client?DW_CLIENT_LOST:spaceFrames?dw_client_submit_space_frame(_client,extended.bytes,(uint32_t)count,&seq):dw_client_submit_frame(_client,_records.bytes,(uint32_t)count,&seq);
    os_unfair_lock_unlock(&_lock);
    if(result!=DW_CLIENT_OK)return;
    if(spaceFrames){
        const struct dw2_space_record *records=extended.bytes;uint64_t now=uptime();
        for(NSUInteger i=0;i<count;i++){
            const struct dw2_space_record *record=&records[i];if(!record->target_space||record->record.flags&DW2_RECORD_RESTORE)continue;
            NSNumber *wid=@(record->record.id.wid);DWNativeWindow *window=_windows[wid];
            if(!window||window->root!=record->record.id.wid)continue;
            DWNativeSpaceReflow *prior=_spaceReflows[wid];
            if(prior&&!memcmp(&prior->identity,&record->record.id,sizeof(prior->identity))&&prior->target==record->target_space)continue;
            DWNativeSpaceReflow *reflow=[DWNativeSpaceReflow new];reflow->identity=record->record.id;
            reflow->original=prior&&prior->changed&&!memcmp(&prior->identity,&record->record.id,sizeof(prior->identity))?prior->original:window->bounds;
            reflow->before=reflow->observed=window->bounds;reflow->target=record->target_space;reflow->submittedAt=reflow->changedAt=now;
            reflow->changed=prior&&prior->changed;_spaceReflows[wid]=reflow;
        }
    }
    _sent=[_records copy];_sentSpaces=[_recordSpaces copy];_sentOrder=_order;_forced=NO;_lastSent=uptime();_submittedSeq=seq;
    _framePlacements[@(seq)]=_desiredPlacements;_acknowledgedPlacements=@{};_acknowledgedSequence=0;
    if(_releases.count)for(DWNativeWindow *window in _releases.objectEnumerator)if(!window->releaseSeq)window->releaseSeq=seq;
    // A frame the next one replaced is never answered: what is kept is bounded by age.
    _frames[@(seq)]=_sent;for(NSNumber *old in _frames.allKeys)if(old.unsignedLongLongValue+64<seq){[_frames removeObjectForKey:old];[_framePlacements removeObjectForKey:old];}
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
- (BOOL)withholdWindow:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]withholdWindow:identity]; }
- (BOOL)isWindowWithheld:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]isWindowWithheld:identity]; }
- (void)resumeWindow:(NSDictionary *)identity { [self.owners[identity[@"pid"]]resumeWindow:identity]; }
- (BOOL)canRebaseWindow:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]canRebaseWindow:identity]; }
- (BOOL)rebaseWindow:(NSDictionary *)identity bounds:(CGRect)native { return !self.ended&&[self.owners[identity[@"pid"]]rebaseWindow:identity bounds:native]; }
- (BOOL)isWindowRebased:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]isWindowRebased:identity]; }
- (void)cancelRebaseWindow:(NSDictionary *)identity { [self.owners[identity[@"pid"]]cancelRebaseWindow:identity]; }
- (DWNativeHiddenRoot *)beginTransitionForWindow:(NSDictionary *)identity { return self.ended?nil:[self.owners[identity[@"pid"]]beginTransitionForWindow:identity]; }
- (BOOL)hideTransition:(DWNativeHiddenRoot *)transition { return !self.ended&&[self.owners[transition.identity[@"pid"]]hideTransition:transition]; }
- (BOOL)isTransitionHidden:(DWNativeHiddenRoot *)transition { return !self.ended&&[self.owners[transition.identity[@"pid"]]isTransitionHidden:transition]; }
- (BOOL)revealTransition:(DWNativeHiddenRoot *)transition screen:(CGRect)screen alpha:(double)alpha { return !self.ended&&[self.owners[transition.identity[@"pid"]]revealTransition:transition screen:screen alpha:alpha]; }
- (BOOL)isTransitionRevealed:(DWNativeHiddenRoot *)transition { return !self.ended&&[self.owners[transition.identity[@"pid"]]isTransitionRevealed:transition]; }
- (void)setTransitionFrameAcknowledged:(void (^)(void))callback {
    [super setTransitionFrameAcknowledged:callback];
    for(DWNativePresenter *session in self.sessions)session.transitionFrameAcknowledged=callback;
}
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    if(self.ended)return;
    for(DWNativePresenter *session in self.sessions){NSMutableDictionary *owned=[NSMutableDictionary dictionary];
        for(NSNumber *logical in identities)if(self.owners[identities[logical][@"pid"]]==session)owned[logical]=identities[logical];
        [session describe:snapshot bound:owned];}
}
- (void)submit { if(self.ended)return;for(DWNativePresenter *session in self.sessions){[session submit];if(self.ended)break;} }
- (void)requireFreshPlacementAcknowledgement {
    if(!NSThread.isMainThread||self.ended)return;
    for(DWNativePresenter *session in self.sessions)[session requireFreshPlacementAcknowledgement];
}
- (DWNativeAppliedPlacement *)acknowledgedPlacementForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation output:(NSNumber *)output {
    if(!NSThread.isMainThread||self.ended)return nil;
    return [self.owners[identity[@"pid"]]acknowledgedPlacementForWindow:window identity:identity generation:generation output:output];
}
- (BOOL)isAcknowledgedPlacementCurrent:(DWNativeAppliedPlacement *)placement {
    return NSThread.isMainThread&&!self.ended&&[placement isKindOfClass:DWNativeAppliedPlacement.class]
        &&[self.owners[placement.identity[@"pid"]]isAcknowledgedPlacementCurrent:placement];
}
- (BOOL)isParkingAcknowledgedForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation {
    return NSThread.isMainThread&&!self.ended&&[self.owners[identity[@"pid"]]isParkingAcknowledgedForWindow:window identity:identity generation:generation];
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
    NSDictionary *reply=@{@"group":@YES,@"ended":@(self.ended),@"sessions":sessions,@"records":records,@"stats":stats,@"probe":complete?probe:(id)NSNull.null};
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugNative":reply}} options:0 error:nil];
}
@end
