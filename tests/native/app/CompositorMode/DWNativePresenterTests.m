// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual presenter with an in-memory transport and declared family
// reports. No connection, native getter/setter, window, event tap, pasteboard or
// application is created. ACK receipts are not native/input usability evidence.
#import <AppKit/AppKit.h>
static BOOL readinessNoScreens;
@interface DWReadinessScreen : NSObject
@property(nonatomic,readonly) NSRect frame;
+ (NSArray<DWReadinessScreen *> *)screens;
@end
@implementation DWReadinessScreen
- (NSRect)frame { return NSMakeRect(0,0,1200,900); }
+ (NSArray<DWReadinessScreen *> *)screens { return readinessNoScreens?@[]:@[[DWReadinessScreen new]]; }
@end
#define NSScreen DWReadinessScreen
#import "DWNativePresenter.m"
#undef NSScreen

struct dw_client { uint64_t sequence; };
static NSUInteger checks,closed;
static uint64_t readinessSpace;
static NSData *lastSpaceFrame;
uint64_t DWNativeDisplaySpace(CGRect viewport) {
    return CGRectEqualToRect(viewport,CGRectMake(0,0,1200,900))?readinessSpace:0;
}
uint64_t DWNativePresentationDisplaySpace(CGRect viewport) { return DWNativeDisplaySpace(viewport); }
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
int dw_client_open(const char *runtime,const char *nonce,const struct dw_client_callbacks *callbacks,uint32_t timeout,dw_client **client,struct dw_client_info *info) {
    (void)runtime;(void)nonce;(void)callbacks;(void)timeout;(void)client;(void)info;return DW_CLIENT_INVALID;
}
int dw_client_submit_frame(dw_client *client,const struct dw2_record *records,uint32_t count,uint64_t *sequence) {
    check(client&&(!count||records)&&count<=DW2_MAX_RECORDS,@"in-memory submission has a bounded complete frame");*sequence=++client->sequence;return DW_CLIENT_OK;
}
int dw_client_submit_space_frame(dw_client *client,const struct dw2_space_record *records,uint32_t count,uint64_t *sequence) {
    check(client&&(!count||records)&&count<=DW2_MAX_RECORDS,@"Space submission has a bounded complete frame");
    lastSpaceFrame=[NSData dataWithBytes:records length:count*sizeof(*records)];*sequence=++client->sequence;return DW_CLIENT_OK;
}
int dw_client_probe(dw_client *client,uint32_t timeout,void *reply,size_t capacity,size_t *length) {
    (void)client;(void)timeout;(void)reply;(void)capacity;(void)length;return DW_CLIENT_LOST;
}
int dw_client_enrollment(dw_client *client,uint32_t timeout,struct dw2_process *processes,uint32_t capacity,uint32_t *count) {
    (void)client;(void)timeout;(void)processes;(void)capacity;(void)count;return DW_CLIENT_LOST;
}
int dw_client_inspect(dw_client *client,uint32_t timeout,const struct dw2_identity *identity,struct dw2_inspect_reply *reply) {
    (void)client;(void)timeout;(void)identity;(void)reply;return DW_CLIENT_LOST;
}
int dw_client_restore_all(dw_client *client,uint32_t timeout,struct dw2_restore_result *results,uint32_t capacity,uint32_t *count,uint32_t *pending,uint32_t *persisted) {
    (void)client;(void)timeout;(void)results;(void)capacity;*count=0;*pending=0;*persisted=1;return DW_CLIENT_OK;
}
int dw_client_veil(dw_client *client,uint32_t timeout,bool enable,uint32_t *held) {
    (void)client;(void)timeout;(void)enable;(void)held;return DW_CLIENT_INVALID;
}
void dw_client_stats(dw_client *client,struct dw_client_stats *stats) { (void)client;memset(stats,0,sizeof(*stats)); }
void dw_client_close(dw_client *client) { if(client){closed++;free(client);} }
NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why) {
    (void)identity;if(why)*why=@"substituted unavailable family";return nil;
}
BOOL DWNativeWindowParent(NSDictionary *identity,uint32_t *parent) { (void)identity;*parent=0;return YES; }
BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *root) { (void)member;(void)root;return YES; }
bool dw_focus_birth(pid_t pid,uint64_t *seconds,uint64_t *microseconds) { (void)pid;*seconds=100;*microseconds=20;return true; }

@interface DWNativePresenter (ReadinessFixture)
+ (instancetype)fixturePID:(NSNumber *)pid;
- (uint64_t)fixtureSequence;
- (NSData *)fixtureRecords;
- (void)fixtureAck:(NSArray<NSNumber *> *)statuses sequence:(uint64_t)sequence;
- (void)fixtureCallback:(NSArray<NSNumber *> *)statuses sequence:(uint64_t)sequence;
- (void)fixtureExpire;
- (void)fixtureRetry;
- (void)fixtureCorruptFrame;
- (void)fixtureCooperative;
- (void)fixtureSpaceFrames;
- (void)fixturePinned;
- (void)fixtureVeiling;
- (NSUInteger)fixtureReleases;
- (DWNativeSpaceReflow *)fixtureSpaceReflow:(NSNumber *)wid;
- (void)fixtureBound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family;
- (NSUInteger)fixtureRetainedFrames;
- (NSUInteger)fixtureRetainedPlacements;
@end
@implementation DWNativePresenter (ReadinessFixture)
+ (instancetype)fixturePID:(NSNumber *)pid {
    DWNativePresenter *presenter=[self new];presenter->_scope=@{pid:@[@100,@20]};
    presenter->_info=(struct dw_client_info){.max_records=DW2_MAX_RECORDS,.scope=DW2_SCOPE_ALLOWLIST};
    presenter->_client=calloc(1,sizeof(dw_client));check(presenter->_client!=NULL,@"create in-memory transport");return presenter;
}
- (uint64_t)fixtureSequence { return _submittedSeq; }
- (NSData *)fixtureRecords { return _records.copy; }
- (void)fixtureAck:(NSArray<NSNumber *> *)statuses sequence:(uint64_t)sequence {
    NSMutableData *data=[NSMutableData data];for(NSNumber *status in statuses){uint8_t value=status.unsignedCharValue;[data appendBytes:&value length:1];}[self refused:data frame:sequence];
}
- (void)fixtureCallback:(NSArray<NSNumber *> *)statuses sequence:(uint64_t)sequence {
    NSMutableData *data=[NSMutableData data];for(NSNumber *status in statuses){uint8_t value=status.unsignedCharValue;[data appendBytes:&value length:1];}
    frameResult((__bridge void *)self,sequence,data.bytes,(uint32_t)data.length);
}
- (void)fixtureExpire { atomic_store(&_ended,true); }
- (void)fixtureRetry { _lastSent=0; }
- (void)fixtureCorruptFrame {
    NSMutableData *frame=[_frames[@(_submittedSeq)]mutableCopy];struct dw2_record *records=frame.mutableBytes;records[0].id.wid++;_frames[@(_submittedSeq)]=frame.copy;
}
- (void)fixtureCooperative { _info.scope=DW2_SCOPE_COOPERATIVE; }
- (void)fixtureSpaceFrames { _desktopWide=YES;_info.caps|=DW2_CAP_SPACE; }
- (void)fixturePinned { _info.caps|=DW2_CAP_PINNED|DW2_CAP_ALPHA; }
- (void)fixtureVeiling { _veiling=YES; }
// The root's family was last audited longer ago than the grace a failed read is given.
- (void)fixtureAgeFamily:(NSNumber *)root { _windows[root]->familyAt=0; }
- (NSUInteger)fixtureReleases { return _releases.count; }
- (DWNativeSpaceReflow *)fixtureSpaceReflow:(NSNumber *)wid { return _spaceReflows[wid]; }
- (void)fixtureBound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family {
    BOOL desktop=_desktopWide;_desktopWide=NO;[self bound:identity bounds:native family:family];_desktopWide=desktop;
}
- (NSUInteger)fixtureRetainedFrames { return _frames.count; }
- (NSUInteger)fixtureRetainedPlacements { return _framePlacements.count; }
@end
static NSDictionary *identity(int pid,uint32_t wid) { return @{@"pid":@(pid),@"wid":@(wid),@"birth_sec":@100,@"birth_usec":@20}; }
static NSDictionary *rect(CGRect value) { return @{@"origin":@{@"x":@(value.origin.x),@"y":@(value.origin.y)},@"size":@{@"width":@(value.size.width),@"height":@(value.size.height)}}; }
static NSDictionary *family(NSDictionary *root,CGRect native,NSArray<NSNumber *> *children) {
    NSMutableArray *members=[NSMutableArray arrayWithObject:@{@"identity":root,@"native_bounds":rect(native),@"parent":@0}];
    for(NSNumber *wid in children)[members addObject:@{@"identity":identity([root[@"pid"]intValue],wid.unsignedIntValue),@"native_bounds":rect(CGRectMake(150,125,90,60)),@"parent":root[@"wid"]}];
    return @{@"root":root[@"wid"],@"identity":root,@"members":members.copy};
}
static NSDictionary *snapshot(NSDictionary *root,uint64_t generation,uint64_t output,CGRect screen,BOOL known) {
    NSDictionary *bounds=rect(CGRectMake(0,0,1200,900));
    NSMutableDictionary *sourceIdentity=[root mutableCopy];sourceIdentity[@"owner"]=NSNull.null;
    return @{@"outputs":@[@{@"id":@1,@"screen_bounds":bounds},@{@"id":@2,@"screen_bounds":bounds}],
        @"placements":@[@{@"window":@7,@"output":@(output),@"screen_rect":rect(screen),@"clip_rect":rect(screen),
            @"source":@{@"identity":sourceIdentity.copy,@"generation":@(generation),@"observation_known":@(known)}}]};
}
static DWNativeAppliedPlacement *receipt(DWNativePresenter *presenter,NSDictionary *root,uint64_t generation,uint64_t output) {
    return [presenter acknowledgedPlacementForWindow:@7 identity:root generation:@(generation) output:@(output)];
}
static void describe(DWNativePresenter *presenter,NSDictionary *root,uint64_t generation,uint64_t output,CGRect screen) {
    [presenter describe:snapshot(root,generation,output,screen,YES) bound:@{@7:root}];
}
static void ack(DWNativePresenter *presenter) { [presenter fixtureAck:@[@(DW2_APPLIED),@(DW2_APPLIED)] sequence:presenter.fixtureSequence]; }
int main(void) {@autoreleasepool {
    check(NSThread.isMainThread,@"run fixture on the main thread");NSDictionary *root=identity(123,42);
    CGRect native=CGRectMake(100,100,320,232),screen=CGRectMake(250,200,160,116);
    DWNativePresenter *presenter=[DWNativePresenter fixturePID:@123];
    __block NSUInteger transitionWakeups=0;
    __weak DWNativePresenter *notifiedPresenter=presenter;
    presenter.transitionFrameAcknowledged=^{
        check(NSThread.isMainThread&&[notifiedPresenter fixtureRetainedFrames]==0,@"transition wakeup follows completed main-thread ACK bookkeeping");
        transitionWakeups++;
    };
    [presenter bound:root bounds:native family:family(root,native,@[@43])];describe(presenter,root,1,1,screen);
    check(!receipt(presenter,root,1,1),@"describe is desired state, never an ACK");[presenter submit];
    check(!receipt(presenter,root,1,1),@"queueing a frame is not an ACK");ack(presenter);
    DWNativeAppliedPlacement *first=receipt(presenter,root,1,1);
    check(transitionWakeups==1,@"a complete current ACK wakes the active handoff immediately");
    ack(presenter);[presenter fixtureAck:@[@0,@0] sequence:presenter.fixtureSequence+50];
    check(transitionWakeups==1,@"duplicate and unknown ACKs do not wake a handoff");
    check(first&&first.sequence==presenter.fixtureSequence&&[presenter isAcknowledgedPlacementCurrent:first],@"complete current family ACK produces a revocable receipt");
    check(first.members.count==2&&[first.members[0][@"identity"]isEqual:root]&&[first.members[1][@"identity"]isEqual:identity(123,43)],@"receipt includes every sorted bound family member");
    check([first.members[0][@"parent"]isEqual:@0]&&[first.members[1][@"parent"]isEqual:@42],@"receipt preserves the audited root and child parent IDs");
    check(CGRectEqualToRect(first.requestedScreenRect,screen)&&[first.members[0][@"requested_transform"]isEqual:@[@2,@0,@0,@2,@(-500),@(-400)]],@"receipt describes requested projection and exact emitted matrix");
    check(!receipt(presenter,identity(124,42),1,1)&&!receipt(presenter,root,2,1)&&!receipt(presenter,root,1,2),@"identity, generation and output are exact");

    uint64_t beforeFill=presenter.fixtureSequence;
    check(![presenter withholdWindow:identity(124,42)],@"Fill cannot withhold a recycled or foreign identity");
    check([presenter withholdWindow:root],@"Fill withholds the exact native root");
    [presenter submit];check(presenter.fixtureSequence==beforeFill&&!receipt(presenter,root,1,1),@"withholding revokes prior input without resending an old frame");
    check(![presenter isWindowWithheld:root],@"withholding is not ready before a new helper ACK");
    describe(presenter,root,1,1,screen);[presenter submit];
    check(presenter.fixtureRecords.length==0,@"Fill omits both root and child rather than releasing or parking either");
    [presenter fixtureAck:@[@0,@0] sequence:beforeFill];check(![presenter isWindowWithheld:root],@"an old placement ACK cannot start Fill");
    [presenter fixtureAck:@[@0] sequence:presenter.fixtureSequence];
    check(transitionWakeups==1,@"old and incomplete omission ACKs cannot wake a handoff");
    [presenter fixtureAck:@[] sequence:presenter.fixtureSequence];
    check(transitionWakeups==2,@"an exact empty omission ACK wakes the same handoff");
    check([presenter isWindowWithheld:root]&&!receipt(presenter,root,1,1),@"omission ACK drains prior placement but grants no input receipt");
    [presenter resumeWindow:identity(124,42)];check([presenter isWindowWithheld:root],@"foreign resume cannot release the handoff");
    [presenter resumeWindow:root];check(![presenter isWindowWithheld:root]&&!receipt(presenter,root,1,1),@"resume requires a new placement ACK");
    describe(presenter,root,1,1,screen);[presenter submit];check(presenter.fixtureRecords.length==2*sizeof(struct dw2_record),@"resume reinstates the complete family");
    ack(presenter);first=receipt(presenter,root,1,1);check(first!=nil,@"fresh family ACK alone restores placement eligibility");
    check(transitionWakeups==3,@"resumed placement ACK wakes final handoff cleanup");
    presenter.transitionFrameAcknowledged=nil;

    // A separate root-only family exercises the real temporary neutral wire
    // record, its exact ACK, and the second omission barrier without native calls.
    DWNativePresenter *rebasing=[DWNativePresenter fixturePID:@123];CGRect rebasedFrame=CGRectMake(816,382,320,232);
    [rebasing bound:root bounds:native family:family(root,native,@[])];describe(rebasing,root,1,1,native);[rebasing submit];
    [rebasing fixtureAck:@[@(DW2_APPLIED)] sequence:rebasing.fixtureSequence];[rebasing withholdWindow:root];
    describe(rebasing,root,1,1,native);[rebasing submit];[rebasing fixtureAck:@[] sequence:rebasing.fixtureSequence];
    check([rebasing canRebaseWindow:root],@"only a drained known root-only family can rebase");
    [presenter withholdWindow:root];describe(presenter,root,1,1,screen);[presenter submit];[presenter fixtureAck:@[] sequence:presenter.fixtureSequence];
    check(![presenter canRebaseWindow:root],@"attached children keep translated rebase unsupported");
    [presenter resumeWindow:root];describe(presenter,root,1,1,screen);[presenter submit];ack(presenter);first=receipt(presenter,root,1,1);
    check([rebasing rebaseWindow:root bounds:rebasedFrame],@"observed same-size native frame queues neutral placement");
    describe(rebasing,root,1,1,native);[rebasing submit];uint64_t neutral=rebasing.fixtureSequence;
    const struct dw2_record *neutralRecord=rebasing.fixtureRecords.bytes;
    check(rebasing.fixtureRecords.length==sizeof(*neutralRecord)&&neutralRecord->m[0]==1&&neutralRecord->m[3]==1&&neutralRecord->m[4]==-816&&neutralRecord->m[5]==-382&&!(neutralRecord->flags&DW2_RECORD_RESTORE),@"neutral wire placement preserves original journal and uses observed origin");
    [rebasing fixtureAck:@[@(DW2_NOT_APPLIED)] sequence:neutral];check(![rebasing isWindowRebased:root],@"refused neutral record never starts Fill");
    [rebasing fixtureRetry];[rebasing submit];neutral=rebasing.fixtureSequence;[rebasing fixtureAck:@[@(DW2_APPLIED)] sequence:neutral];check(![rebasing isWindowRebased:root]&&!receipt(rebasing,root,1,1),@"neutral ACK alone neither starts Fill nor grants input");
    describe(rebasing,root,1,1,native);[rebasing submit];check(rebasing.fixtureRecords.length==0,@"neutral ACK queues omission to prevent animation transform replay");
    [rebasing fixtureAck:@[@(DW2_APPLIED)] sequence:neutral];check(![rebasing isWindowRebased:root],@"old neutral ACK cannot satisfy newer omission");
    [rebasing fixtureAck:@[] sequence:rebasing.fixtureSequence];check([rebasing isWindowRebased:root]&&!receipt(rebasing,root,1,1),@"only drained neutral plus omission ACK permits native animation");
    [rebasing cancelRebaseWindow:identity(124,42)];check([rebasing isWindowRebased:root],@"foreign cancellation cannot alter rebase");
    [rebasing cancelRebaseWindow:root];check(![rebasing isWindowRebased:root],@"cancellation revokes rebase without granting input");

    uint64_t superseded=presenter.fixtureSequence;NSData *sameRecords=presenter.fixtureRecords;
    [presenter requireFreshPlacementAcknowledgement];[presenter submit];
    check(![presenter isAcknowledgedPlacementCurrent:first]&&presenter.fixtureSequence==superseded,@"new transfer revision revokes receipts without sending stale previously described records");
    [presenter fixtureAck:@[@0,@0] sequence:superseded];check(!receipt(presenter,root,1,1),@"previous ACK cannot settle a superseding same-geometry transfer");
    describe(presenter,root,1,1,screen);[presenter submit];
    check(presenter.fixtureSequence>superseded&&[presenter.fixtureRecords isEqual:sameRecords],@"superseding identical geometry requires a fresh submitted sequence");
    check(!receipt(presenter,root,1,1),@"fresh same-geometry frame remains pending until its own ACK");ack(presenter);first=receipt(presenter,root,1,1);
    check(first!=nil&&first.sequence>superseded,@"only a new complete ACK settles the same-geometry transfer");

    uint64_t old=presenter.fixtureSequence;CGRect moved=screen;moved.origin.x+=20;describe(presenter,root,1,1,moved);
    check(![presenter isAcknowledgedPlacementCurrent:first],@"desired geometry change revokes before submission");[presenter submit];
    [presenter fixtureAck:@[@0,@0] sequence:old];[presenter fixtureAck:@[@0,@0] sequence:presenter.fixtureSequence+50];
    check(!receipt(presenter,root,1,1),@"stale and future ACK sequences cannot acknowledge a current frame");ack(presenter);
    DWNativeAppliedPlacement *current=receipt(presenter,root,1,1);check(current!=nil,@"current matching ACK settles moved geometry");

    NSData *unchanged=presenter.fixtureRecords;old=presenter.fixtureSequence;describe(presenter,root,2,1,moved);
    check(![presenter isAcknowledgedPlacementCurrent:current],@"generation change revokes even with identical native records");[presenter submit];
    check(presenter.fixtureSequence>old&&[presenter.fixtureRecords isEqual:unchanged],@"generation-only change requests a new exact ACK");ack(presenter);current=receipt(presenter,root,2,1);
    check(current!=nil&&!receipt(presenter,root,1,1),@"new generation is the sole acknowledged binding");
    old=presenter.fixtureSequence;describe(presenter,root,2,2,moved);describe(presenter,root,2,1,moved);
    [presenter fixtureAck:@[@0,@0] sequence:old];check(!receipt(presenter,root,2,1),@"output change away and back cannot resurrect an old ACK");[presenter submit];ack(presenter);

    old=presenter.fixtureSequence;CGRect larger=native;larger.size.width+=4;
    [presenter bound:root bounds:larger family:family(root,larger,@[@43])];[presenter bound:root bounds:native family:family(root,native,@[@43])];
    [presenter fixtureAck:@[@0,@0] sequence:old];check(!receipt(presenter,root,2,1),@"native basis change away and back revokes a pending ACK");describe(presenter,root,2,1,moved);[presenter submit];ack(presenter);
    old=presenter.fixtureSequence;[presenter bound:root bounds:native family:family(root,native,@[@43,@44])];[presenter bound:root bounds:native family:family(root,native,@[@43])];
    [presenter fixtureAck:@[@0,@0] sequence:old];check(!receipt(presenter,root,2,1),@"family change away and back revokes old correspondence");describe(presenter,root,2,1,moved);[presenter submit];
    // The removed child has a restore record, separate from this family's ACK.
    [presenter fixtureAck:@[@0,@(DW2_NOT_APPLIED),@0] sequence:presenter.fixtureSequence];
    check(!receipt(presenter,root,2,1),@"one failed family member prevents root readiness");[presenter fixtureRetry];describe(presenter,root,2,1,moved);[presenter submit];
    [presenter fixtureAck:@[@0] sequence:presenter.fixtureSequence];check(!receipt(presenter,root,2,1),@"short substituted ACK cannot certify a complete frame");
    [presenter fixtureAck:@[@0,@0] sequence:presenter.fixtureSequence];current=receipt(presenter,root,2,1);check(current!=nil,@"successful retried complete family settles");

    moved.origin.y+=10;describe(presenter,root,2,1,moved);[presenter submit];[presenter fixtureCorruptFrame];ack(presenter);
    check(!receipt(presenter,root,2,1),@"exact record identity and matrix correspondence is required");
    // Unreadable for longer than the grace a failed read is given (below): the audited family is let go.
    [presenter fixtureAgeFamily:@42];[presenter bound:root bounds:native family:nil];describe(presenter,root,2,1,moved);[presenter submit];
    [presenter fixtureAck:@[@0] sequence:presenter.fixtureSequence];check(!receipt(presenter,root,2,1),@"unavailable family is never an acknowledged complete family");
    [presenter bound:root bounds:native family:family(root,native,@[@43])];describe(presenter,root,2,1,moved);[presenter submit];ack(presenter);current=receipt(presenter,root,2,1);
    check(current!=nil,@"fresh complete family requires and accepts its new ACK");
    old=presenter.fixtureSequence;[presenter requireFreshPlacementAcknowledgement];[presenter describe:@{@"outputs":@[],@"placements":@[]} bound:@{@7:root}];[presenter submit];ack(presenter);
    check(![presenter isAcknowledgedPlacementCurrent:current]&&!receipt(presenter,root,2,1),@"output disappearance revokes receipts and pending ACKs");
    check(presenter.fixtureSequence==old,@"invalid output description never resubmits a stale placement");
    describe(presenter,root,2,1,moved);[presenter submit];ack(presenter);
    old=presenter.fixtureSequence;readinessNoScreens=YES;describe(presenter,root,2,1,moved);[presenter submit];ack(presenter);readinessNoScreens=NO;
    check(presenter.fixtureSequence==old&&!receipt(presenter,root,2,1),@"missing displays revoke readiness without resubmitting stale records");
    describe(presenter,root,2,1,moved);[presenter submit];ack(presenter);
    [presenter describe:snapshot(root,2,1,moved,NO) bound:@{@7:root}];[presenter submit];ack(presenter);
    check(!receipt(presenter,root,2,1),@"unknown current observation excludes readiness");
    NSMutableDictionary *owned=[snapshot(root,2,1,moved,YES)mutableCopy];NSMutableDictionary *placement=[owned[@"placements"][0]mutableCopy];
    NSMutableDictionary *source=[placement[@"source"]mutableCopy],*ownedIdentity=[source[@"identity"]mutableCopy];ownedIdentity[@"owner"]=@777;
    source[@"identity"]=ownedIdentity.copy;placement[@"source"]=source.copy;owned[@"placements"]=@[placement.copy];
    [presenter describe:owned bound:@{@7:root}];[presenter submit];ack(presenter);
    check(!receipt(presenter,root,2,1),@"populated controller owner is refused rather than dropped");
    CGRect unreachable=moved;unreachable.origin.x=1e7;describe(presenter,root,2,1,unreachable);[presenter submit];ack(presenter);
    check(!receipt(presenter,root,2,1),@"acknowledged parking is never acknowledged placement at an unrepresentable site");
    describe(presenter,root,2,1,moved);[presenter submit];
    [presenter fixtureCallback:@[@0,@0] sequence:presenter.fixtureSequence];
    check(!receipt(presenter,root,2,1),@"reader callback publishes on a later main turn");
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:.2];
    while(!receipt(presenter,root,2,1)&&deadline.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    current=receipt(presenter,root,2,1);check(current!=nil,@"ordinary all-success callback reaches readiness state");

    for(NSUInteger i=0;i<100;i++){
        moved.origin.x+=1;describe(presenter,root,2,1,moved);[presenter submit];
        check(presenter.fixtureRetainedFrames==1&&presenter.fixtureRetainedPlacements==1,@"a complete-frame history retains only the unresolved frame");ack(presenter);
        check(presenter.fixtureRetainedFrames==0&&presenter.fixtureRetainedPlacements==0&&receipt(presenter,root,2,1)!=nil,
            @"a final ACK releases immutable history while its current receipt remains valid");
    }
    moved.origin.y+=1;describe(presenter,root,2,1,moved);[presenter submit];uint64_t coalesced=presenter.fixtureSequence;
    moved.origin.y+=1;describe(presenter,root,2,1,moved);[presenter submit];uint64_t resolved=presenter.fixtureSequence;
    moved.origin.y+=1;describe(presenter,root,2,1,moved);[presenter submit];uint64_t outstanding=presenter.fixtureSequence;
    check(presenter.fixtureRetainedFrames==3&&presenter.fixtureRetainedPlacements==3,@"newer outstanding descriptions remain until a result accounts for them");
    [presenter fixtureAck:@[@0] sequence:resolved];[presenter fixtureAck:@[@0,@0] sequence:outstanding+50];
    check(presenter.fixtureRetainedFrames==3&&presenter.fixtureRetainedPlacements==3&&!receipt(presenter,root,2,1),@"short and unknown replies cannot retire pending correspondence");
    [presenter fixtureAck:@[@0,@0] sequence:resolved];
    check(presenter.fixtureRetainedFrames==1&&presenter.fixtureRetainedPlacements==1&&!receipt(presenter,root,2,1),@"a complete older reply retires its accounted prefix while preserving the newest pending frame");
    [presenter fixtureAck:@[@0,@0] sequence:coalesced];
    check(presenter.fixtureRetainedFrames==1&&!receipt(presenter,root,2,1),@"a retired superseded result cannot settle newer placement readiness");ack(presenter);current=receipt(presenter,root,2,1);
    check(current&&presenter.fixtureRetainedFrames==0&&presenter.fixtureRetainedPlacements==0,@"the newest complete ACK retains its receipt without frame history");
    [presenter fixtureAck:@[@(DW2_NOT_APPLIED),@(DW2_NOT_APPLIED)] sequence:outstanding];
    check([presenter isAcknowledgedPlacementCurrent:current],@"a repeated retired result cannot revoke an already settled receipt");

    NSDictionary *twoChildren=family(root,native,@[@43,@44]);[presenter bound:root bounds:native family:twoChildren];describe(presenter,root,2,1,moved);[presenter submit];
    [presenter fixtureAck:@[@0,@0,@0] sequence:presenter.fixtureSequence];current=receipt(presenter,root,2,1);
    check(current.members.count==3,@"three-member audited topology produces a complete receipt");
    NSMutableDictionary *reparented=[twoChildren mutableCopy];NSMutableArray *report=[twoChildren[@"members"]mutableCopy];NSMutableDictionary *reparentedChild=[report[1]mutableCopy];
    reparentedChild[@"parent"]=@44;report[1]=reparentedChild;reparented[@"members"]=report;
    old=presenter.fixtureSequence;sameRecords=presenter.fixtureRecords;[presenter bound:root bounds:native family:reparented];
    check(![presenter isAcknowledgedPlacementCurrent:current],@"same-root reparenting revokes a receipt even with unchanged membership and bounds");describe(presenter,root,2,1,moved);[presenter submit];
    check(presenter.fixtureSequence>old&&[presenter.fixtureRecords isEqual:sameRecords],@"parent-only topology change requires a new sequence despite identical helper records");
    [presenter fixtureAck:@[@0,@0,@0] sequence:old];check(!receipt(presenter,root,2,1),@"old topology ACK cannot settle the reparented family");
    [presenter fixtureAck:@[@0,@0,@0] sequence:presenter.fixtureSequence];current=receipt(presenter,root,2,1);
    check([current.members[1][@"parent"]isEqual:@44],@"new receipt freezes the actual reported intermediate parent");
    report=[twoChildren[@"members"]mutableCopy];reparentedChild=[report[1]mutableCopy];[reparentedChild removeObjectForKey:@"parent"];report[1]=reparentedChild;
    [presenter bound:root bounds:native family:@{@"root":@42,@"identity":root,@"members":report}];
    check(![presenter isAcknowledgedPlacementCurrent:current],@"missing parent metadata is refused rather than guessed");
    [presenter bound:root bounds:native family:family(root,native,@[@43])];describe(presenter,root,2,1,moved);[presenter submit];
    // The invalid report released both children; rebinding 43 cancels its release.
    [presenter fixtureAck:@[@0,@0,@0] sequence:presenter.fixtureSequence];current=receipt(presenter,root,2,1);
    check(current!=nil,@"fresh exact topology can recover after a refused report");

    NSDictionary *cooperativeRoot=identity(126,92);DWNativePresenter *cooperative=[DWNativePresenter fixturePID:@126];[cooperative fixtureCooperative];
    [cooperative bound:cooperativeRoot bounds:native family:nil];describe(cooperative,cooperativeRoot,2,1,moved);[cooperative submit];
    [cooperative fixtureAck:@[@0] sequence:cooperative.fixtureSequence];
    check(!receipt(cooperative,cooperativeRoot,2,1),@"cooperative scope without an audited report never guesses a root-only receipt");
    [cooperative bound:cooperativeRoot bounds:native family:family(cooperativeRoot,native,@[])];describe(cooperative,cooperativeRoot,2,1,moved);[cooperative submit];
    [cooperative fixtureAck:@[@0] sequence:cooperative.fixtureSequence];
    check(receipt(cooperative,cooperativeRoot,2,1)!=nil,@"explicit audited root-only cooperative report can become acknowledged");[cooperative finish];

    // A Space change alone must supersede a transform receipt, even when all
    // legacy wire bytes and camera geometry are identical. This exercises the
    // actual description/submission/ACK path with the read-only lookup replaced.
    DWNativePresenter *migrating=[DWNativePresenter fixturePID:@123];
    [migrating bound:root bounds:native family:family(root,native,@[@43])];[migrating fixtureSpaceFrames];
    readinessSpace=10;describe(migrating,root,1,1,screen);[migrating submit];
    const struct dw2_space_record *spaceFrame=lastSpaceFrame.bytes;
    check(lastSpaceFrame.length==2*sizeof(*spaceFrame)&&spaceFrame[0].target_space==10&&spaceFrame[1].target_space==10,@"root and audited child share the exact output Space request");
    const double placedMatrix[6]={spaceFrame[0].record.m[0],spaceFrame[0].record.m[1],spaceFrame[0].record.m[2],spaceFrame[0].record.m[3],spaceFrame[0].record.m[4],spaceFrame[0].record.m[5]};
    ack(migrating);DWNativeAppliedPlacement *oldSpace=receipt(migrating,root,1,1);uint64_t oldSpaceSeq=migrating.fixtureSequence;
    NSData *legacySpaceBytes=migrating.fixtureRecords;
    check(oldSpace&&[oldSpace.members[0][@"requested_space"]isEqual:@10],@"acknowledged membership is frozen alongside the transform correspondence");
    readinessSpace=20;describe(migrating,root,1,1,screen);
    check(![migrating isAcknowledgedPlacementCurrent:oldSpace],@"membership-only change revokes prior receipt before submission");
    [migrating submit];check(migrating.fixtureSequence>oldSpaceSeq&&[legacySpaceBytes isEqual:migrating.fixtureRecords],@"identical transforms still submit a changed Space request");
    [migrating fixtureAck:@[@0,@0] sequence:oldSpaceSeq];check(!receipt(migrating,root,1,1),@"old Space ACK cannot acknowledge new membership");
    [migrating fixtureAck:@[@0,@(DW2_NOT_APPLIED)] sequence:migrating.fixtureSequence];check(!receipt(migrating,root,1,1),@"one pending family Space move withholds the whole placement receipt");
    [migrating fixtureRetry];[migrating submit];
    [migrating fixtureAck:@[@0,@(DW2_SPACE)] sequence:migrating.fixtureSequence];
    uint64_t refusedSpaceSeq=migrating.fixtureSequence;
    [migrating fixtureRetry];[migrating submit];
    check(migrating.fixtureSequence>refusedSpaceSeq&&!receipt(migrating,root,1,1),@"temporarily ineligible Space retries without granting readiness");ack(migrating);
    check([receipt(migrating,root,1,1).members[0][@"requested_space"]isEqual:@20],@"complete new frame ACK records current target Space");
    readinessSpace=0;describe(migrating,root,1,1,screen);[migrating submit];ack(migrating);
    spaceFrame=lastSpaceFrame.bytes;
    check(spaceFrame[0].target_space==0&&!receipt(migrating,root,1,1),@"unresolved display correspondence parks without inventing a Space or granting readiness");
    readinessSpace=20;[migrating forgetChildrenOf:@42 reason:@"family audit lost before display handoff"];
    describe(migrating,root,1,1,screen);[migrating submit];spaceFrame=lastSpaceFrame.bytes;
    check(lastSpaceFrame.length==2*sizeof(*spaceFrame)&&spaceFrame[0].target_space==0&&spaceFrame[1].target_space==0
        &&spaceFrame[1].record.flags==DW2_RECORD_RESTORE,@"unknown family requests no Space for its root while the prior child restores");
    check(memcmp(spaceFrame[0].record.m,placedMatrix,sizeof placedMatrix)==0,@"unknown family still draws its root where the canvas puts it, not parked");
    // The root is not parked: parked it vanished for as long as a read of a Chromium window's family failed on a transient child (4 to 100 ms,
    // the browser's main window "flashing" in the guest; also a frame read mid-resize or a refused popup). Placed at 2x with the placement's origin, as before the report was lost.
    check(spaceFrame[0].record.m[0]==2&&spaceFrame[0].record.m[3]==2&&spaceFrame[0].record.m[4]==-500&&spaceFrame[0].record.m[5]==-400,
        @"unknown family leaves its placed root placed, not parked off every display");
    ack(migrating);check(!receipt(migrating,root,1,1),@"unknown family cannot acquire a Space placement receipt");
    [migrating finish];

    // A family report that cannot be read is not a report of a changed family. The root's last audited family is kept, with its children placed
    // and its receipt current, for a bounded time; past it the family is let go as it always was, the child restored and the root still placed.
    DWNativePresenter *lossy=[DWNativePresenter fixturePID:@123];
    [lossy bound:root bounds:native family:family(root,native,@[@43])];describe(lossy,root,1,1,screen);[lossy submit];ack(lossy);
    DWNativeAppliedPlacement *audited=receipt(lossy,root,1,1);uint64_t auditedSeq=lossy.fixtureSequence;NSData *auditedBytes=lossy.fixtureRecords;
    const struct dw2_record *auditedRecords=auditedBytes.bytes;
    check(audited&&auditedBytes.length==2*sizeof(*auditedRecords)&&auditedRecords[0].m[0]==2&&auditedRecords[1].flags!=DW2_RECORD_RESTORE,@"an audited root and its child are placed and acknowledged");
    [lossy bound:root bounds:native family:@{}];describe(lossy,root,1,1,screen);[lossy submit];
    check([lossy isAcknowledgedPlacementCurrent:audited]&&lossy.fixtureSequence==auditedSeq&&[lossy.fixtureRecords isEqual:auditedBytes],
        @"a requested family audit that failed once keeps the audited family, its receipt and its frame");
    [lossy bound:root bounds:native family:@{}];[lossy bound:root bounds:native family:@{}];
    check([lossy isAcknowledgedPlacementCurrent:audited],@"repeated failed reads inside the grace change nothing");
    [lossy bound:root bounds:native family:family(root,native,@[@43])];describe(lossy,root,1,1,screen);[lossy submit];
    check([lossy isAcknowledgedPlacementCurrent:audited]&&lossy.fixtureSequence==auditedSeq,@"a successful read renews the family without a new frame when nothing changed");
    [lossy fixtureAgeFamily:@42];
    [lossy bound:root bounds:native family:@{}];describe(lossy,root,1,1,screen);[lossy submit];
    const struct dw2_record *lostRecords=lossy.fixtureRecords.bytes;
    check(![lossy isAcknowledgedPlacementCurrent:audited]&&lossy.fixtureRecords.length==2*sizeof(*lostRecords)&&lostRecords[0].m[0]==2&&lostRecords[1].flags==DW2_RECORD_RESTORE,
        @"a family that stays unreadable past the grace is let go: the child restored, the receipt revoked, the root still placed");
    // A report that is readable but names another window, or is unsound, is not a failed read: it is let go at once.
    DWNativePresenter *changed=[DWNativePresenter fixturePID:@123];
    [changed bound:root bounds:native family:family(root,native,@[@43])];describe(changed,root,1,1,screen);[changed submit];ack(changed);
    [changed bound:root bounds:native family:family(identity(123,99),native,@[@43])];describe(changed,root,1,1,screen);[changed submit];
    const struct dw2_record *changedRecords=changed.fixtureRecords.bytes;
    check(changed.fixtureRecords.length==2*sizeof(*changedRecords)&&changedRecords[1].flags==DW2_RECORD_RESTORE,@"a report for another window is a changed family, not a failed read");
    [lossy finish];[changed finish];

    // Pin-only changes use the existing exact record/whole-family ACK path.
    // This checks policy and transport correspondence, not WindowServer stacking.
    DWNativePresenter *pinning=[DWNativePresenter fixturePID:@123];[pinning fixturePinned];
    [pinning bound:root bounds:native family:family(root,native,@[@43])];
    describe(pinning,root,1,1,screen);[pinning submit];ack(pinning);
    DWNativeAppliedPlacement *normalPinReceipt=receipt(pinning,root,1,1);uint64_t normalPinSeq=pinning.fixtureSequence;
    NSMutableDictionary *pinSnapshot=[snapshot(root,1,1,screen,YES)mutableCopy];
    NSMutableDictionary *pinPlacement=[pinSnapshot[@"placements"][0]mutableCopy];pinPlacement[@"pinned"]=@YES;pinPlacement[@"opacity"]=@0.75;
    pinSnapshot[@"placements"]=@[pinPlacement];
    [pinning describe:pinSnapshot bound:@{@7:root}];
    check(![pinning isAcknowledgedPlacementCurrent:normalPinReceipt],@"pin-only desired change revokes the ordinary receipt");
    [pinning submit];const struct dw2_record *pinRecords=pinning.fixtureRecords.bytes;
    check(pinning.fixtureSequence>normalPinSeq&&pinning.fixtureRecords.length==2*sizeof(*pinRecords)
        &&pinRecords[0].flags==(DW2_RECORD_PINNED|DW2_RECORD_HAS_ALPHA)&&pinRecords[1].flags==pinRecords[0].flags,
        @"visible pin requests floating sublevel for every audited family member alongside alpha");
    [pinning fixtureAck:@[@0,@(DW2_SUBLEVEL)] sequence:pinning.fixtureSequence];
    check(!receipt(pinning,root,1,1),@"one sublevel refusal cannot acknowledge a pinned family");
    [pinning requireFreshPlacementAcknowledgement];[pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];ack(pinning);
    DWNativeAppliedPlacement *pinReceipt=receipt(pinning,root,1,1);uint64_t pinnedSeq=pinning.fixtureSequence;
    check(pinReceipt&&[pinReceipt.members[0][@"flags"]unsignedIntValue]&DW2_RECORD_PINNED,@"receipt retains exact requested pin policy");
    [pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];
    check(pinning.fixtureSequence==pinnedSeq,@"unchanged complete pin does not submit another frame");
    pinPlacement[@"pinned"]=@NO;[pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];pinRecords=pinning.fixtureRecords.bytes;
    check(pinning.fixtureSequence>pinnedSeq&&!([pinning isAcknowledgedPlacementCurrent:pinReceipt])
        &&!(pinRecords[0].flags&DW2_RECORD_PINNED)&&!(pinRecords[1].flags&DW2_RECORD_PINNED),@"unpin-only change explicitly requests original sublevel and fresh ACK");
    ack(pinning);pinPlacement[@"pinned"]=@YES;[pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];ack(pinning);
    NSMutableDictionary *hiddenPin=[pinSnapshot mutableCopy];hiddenPin[@"placements"]=@[];
    [pinning describe:hiddenPin bound:@{@7:root}];[pinning submit];pinRecords=pinning.fixtureRecords.bytes;
    check(!(pinRecords[0].flags&DW2_RECORD_PINNED)&&!(pinRecords[1].flags&DW2_RECORD_PINNED),@"omitted fullscreen-hidden family parks with original sublevels");
    [pinning forgetChildrenOf:@42 reason:@"pin family audit lost"];
    [pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];pinRecords=pinning.fixtureRecords.bytes;
    check(!(pinRecords[0].flags&DW2_RECORD_PINNED)&&pinRecords[1].flags==DW2_RECORD_RESTORE&&!receipt(pinning,root,1,1),@"unknown family cannot keep pin authority while its old child restores");
    ack(pinning);[pinning bound:root bounds:native family:family(root,native,@[])];
    [pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];[pinning fixtureAck:@[@0] sequence:pinning.fixtureSequence];
    DWNativeHiddenRoot *pinnedTransition=[pinning beginTransitionForWindow:root];
    [pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];[pinning fixtureAck:@[] sequence:pinning.fixtureSequence];
    check(pinnedTransition&&[pinning hideTransition:pinnedTransition],@"acknowledged pinned root can begin the existing snapshot handoff");
    [pinning describe:pinSnapshot bound:@{@7:root}];[pinning submit];pinRecords=pinning.fixtureRecords.bytes;
    check(pinning.fixtureRecords.length==sizeof(*pinRecords)&&pinRecords[0].flags==DW2_RECORD_HAS_ALPHA&&pinRecords[0].alpha==0,
        @"hidden snapshot transition restores original sublevel instead of retaining pin intent");
    [pinning finish];
    DWNativePresenter *legacyPin=[DWNativePresenter fixturePID:@123];
    [legacyPin bound:root bounds:native family:family(root,native,@[])];describe(legacyPin,root,1,1,screen);[legacyPin submit];
    check(!legacyPin.ended&&legacyPin.fixtureSequence>0,@"legacy helper still accepts ordinary unpinned traffic");
    [legacyPin describe:pinSnapshot bound:@{@7:root}];[legacyPin submit];
    check(legacyPin.ended&&!receipt(legacyPin,root,1,1),@"missing pin capability restores and ends instead of falsely acknowledging pinning");

    // A helper membership ACK can precede an asynchronous application reflow.
    // Its updated native basis must not become an unrelated canvas resize.
    DWNativePresenter *reflowing=[DWNativePresenter fixturePID:@123];
    [reflowing bound:root bounds:native family:family(root,native,@[])];[reflowing fixtureSpaceFrames];
    readinessSpace=10;describe(reflowing,root,1,1,screen);[reflowing submit];
    DWNativeSpaceReflow *guard=[reflowing fixtureSpaceReflow:@42];
    check(guard&&CGRectEqualToRect(guard->before,native)&&guard->target==10,@"submitted Space target retains its exact cached native baseline");
    CGRect reflowed=CGRectMake(140,110,280,190);
    check([reflowing observeSpaceReflow:root bounds:reflowed nativeInput:NO]&&!guard->settled,@"pending Space request classifies changed native geometry as presentation only");
    [reflowing fixtureBound:root bounds:reflowed family:family(root,reflowed,@[])];describe(reflowing,root,1,1,screen);[reflowing submit];
    [reflowing fixtureAck:@[@0] sequence:reflowing.fixtureSequence];
    guard->submittedAt=uptime()-2001;guard->changedAt=uptime()-251;
    check([reflowing observeSpaceReflow:root bounds:reflowed nativeInput:NO]&&guard->settled,@"fresh matching target ACK and quiet native frame settle with one final basis-only observation");
    check(![reflowing observeSpaceReflow:root bounds:reflowed nativeInput:NO],@"settled migration does not suppress subsequent genuine application resize observations");
    readinessSpace=20;describe(reflowing,root,1,1,screen);[reflowing submit];guard=[reflowing fixtureSpaceReflow:@42];
    check(guard&&!guard->settled&&CGRectEqualToRect(guard->original,native)&&CGRectEqualToRect(guard->before,reflowed),@"new target retains prior reflow diagnostic and freezes its current baseline");
    check(![reflowing observeSpaceReflow:identity(124,42) bounds:reflowed nativeInput:NO],@"replacement identity cannot consume migration qualification");
    check(![reflowing observeSpaceReflow:root bounds:reflowed nativeInput:YES]&&guard->settled&&guard->nativeInput,@"explicit native input ends incidental-reflow suppression");
    [reflowing unbound:root];check(![reflowing fixtureSpaceReflow:@42],@"unbinding retires migration observation authority");[reflowing finish];

    // A bound window without a placement is parked at unit scale; its complete ACK is parking readiness, never a native placement receipt.
    DWNativePresenter *backing=[DWNativePresenter fixturePID:@123];
    [backing bound:root bounds:native family:family(root,native,@[@43])];[backing fixtureSpaceFrames];
    NSDictionary *parkedSnapshot=@{@"outputs":@[@{@"id":@1,@"screen_bounds":rect(CGRectMake(0,0,1200,900))}],@"placements":@[],
        @"windows":@[@{@"window":@7,@"source":@{@"identity":root,@"generation":@1,@"observation_known":@YES,@"observed_rect":rect(native)}}]};
    [backing describe:parkedSnapshot bound:@{@7:root}];[backing submit];
    BOOL (^parkedCurrent)(void)=^BOOL{return [backing isParkingAcknowledgedForWindow:@7 identity:root generation:@1];};
    check(!parkedCurrent(),@"parking submission alone is not parking readiness");
    [backing fixtureAck:@[@0,@(DW2_NOT_APPLIED)] sequence:backing.fixtureSequence];
    check(!parkedCurrent(),@"one refused parked child withholds complete-family readiness");
    uint64_t refused=backing.fixtureSequence;[backing fixtureRetry];[backing submit];
    [backing fixtureAck:@[@0,@0] sequence:refused];check(!parkedCurrent(),@"old parking ACK cannot settle a newer submission");ack(backing);
    check(parkedCurrent()&&![backing isParkingAcknowledgedForWindow:@7 identity:root generation:@2]
        &&![backing isParkingAcknowledgedForWindow:@7 identity:identity(123,99) generation:@1],@"parking ACK retains exact generation and native identity");
    check(!receipt(backing,root,1,1)&&!receipt(backing,root,1,2)&&![backing beginTransitionForWindow:root],@"parking readiness cannot become an output placement or a snapshot transition");
    [backing withholdWindow:root];check(!parkedCurrent(),@"withheld family revokes parking readiness");[backing resumeWindow:root];
    [backing describe:parkedSnapshot bound:@{@7:root}];[backing submit];ack(backing);
    CGRect shifted=native;shifted.origin.x++;[backing fixtureBound:root bounds:shifted family:family(root,shifted,@[@43])];
    check(!parkedCurrent(),@"changed native basis revokes parking readiness");[backing finish];

    NSDictionary *otherRoot=identity(124,82);DWNativePresenter *other=[DWNativePresenter fixturePID:@124];
    [other bound:otherRoot bounds:native family:family(otherRoot,native,@[@83])];describe(other,otherRoot,2,1,moved);[other submit];ack(other);
    DWNativeAppliedPlacement *otherReceipt=receipt(other,otherRoot,2,1);
    check(otherReceipt&&! [other isAcknowledgedPlacementCurrent:current]&&![presenter isAcknowledgedPlacementCurrent:otherReceipt],@"different helper sessions cannot reuse receipts or sequence values");
    DWNativePresenterGroup *group=[DWNativePresenterGroup new];group.sessions=@[presenter,other];group.owners=@{@123:presenter,@124:other};
    __block NSUInteger groupedWakeups=0;group.transitionFrameAcknowledged=^{groupedWakeups++;};
    check([group isAcknowledgedPlacementCurrent:current]&&[group isAcknowledgedPlacementCurrent:otherReceipt]
        &&[group acknowledgedPlacementForWindow:@7 identity:root generation:@2 output:@1]!=nil,@"group delegates readiness to the exact owning session");
    uint64_t groupOld=presenter.fixtureSequence,otherOld=other.fixtureSequence;[group requireFreshPlacementAcknowledgement];[group submit];
    check(![group isAcknowledgedPlacementCurrent:current]&&![group isAcknowledgedPlacementCurrent:otherReceipt]
        &&presenter.fixtureSequence==groupOld&&other.fixtureSequence==otherOld,@"group supersession revokes both sessions without stale submission");
    describe(presenter,root,2,1,moved);describe(other,otherRoot,2,1,moved);[group submit];
    check(presenter.fixtureSequence>groupOld&&other.fixtureSequence>otherOld&&!receipt(presenter,root,2,1)&&!receipt(other,otherRoot,2,1),@"group sessions require their own fresh sequence and ACK");
    ack(presenter);ack(other);current=receipt(presenter,root,2,1);otherReceipt=receipt(other,otherRoot,2,1);
    check(groupedWakeups==2,@"group handoff wakeup follows each current member-session ACK");
    group.transitionFrameAcknowledged=nil;
    check(!presenter.transitionFrameAcknowledged&&!other.transitionFrameAcknowledged,@"clearing a grouped handoff unsubscribes every session");
    check([group isAcknowledgedPlacementCurrent:current]&&[group isAcknowledgedPlacementCurrent:otherReceipt],@"new complete session ACKs settle the grouped supersession");
    [presenter unbound:root];check(![group isAcknowledgedPlacementCurrent:current],@"unbinding revokes a grouped receipt");
    [other fixtureExpire];check(!receipt(other,otherRoot,2,1)&&![group isAcknowledgedPlacementCurrent:otherReceipt],@"disconnect revokes receipt before main callback delivery");
    [group finish];check(closed==10,@"all in-memory sessions drain and close");
    // What an answer to the veil request says about the helper: acceptance, and no or unreadable answer (the helper may have applied it),
    // leave it possibly veiling, so an unmanaged window is released explicitly; a refusal, a lost helper and a bad request do not.
    check(DWNativeVeilMayBeOn(DW_CLIENT_OK)&&DWNativeVeilMayBeOn(DW_CLIENT_TIMEOUT)&&DWNativeVeilMayBeOn(DW_CLIENT_INVALID)
        &&!DWNativeVeilMayBeOn(DW_CLIENT_REFUSED)&&!DWNativeVeilMayBeOn(DW_CLIENT_LOST),@"a veil request that may have been applied is assumed on");
    // A window the shell declines, which the helper's arrival veil may hold: one RESTORE record, retired by whatever the reply, and never
    // for a bound window, a helper without the veil, or a process instance that is not the one named.
    {
        NSDictionary *screens=@{@"outputs":@[@{@"id":@1,@"screen_bounds":rect(CGRectMake(0,0,1200,900))}],@"placements":@[],@"windows":@[]};
        DWNativePresenter *plain=[DWNativePresenter fixturePID:@123];[plain declineWindow:identity(123,99)];
        check(![plain fixtureReleases],@"a helper without the arrival veil is never asked to release a window it holds nothing of");
        DWNativePresenter *declining=[DWNativePresenter fixturePID:@123];[declining fixtureVeiling];
        NSMutableDictionary *reused=[identity(123,99) mutableCopy];reused[@"birth_usec"]=@21;[declining declineWindow:reused];
        check(![declining fixtureReleases],@"a decline names the process instance it was read from");
        NSDictionary *held=identity(123,42);[declining bound:held bounds:native family:family(held,native,@[])];
        [declining declineWindow:held];check(![declining fixtureReleases],@"a bound window is placed or released by its own records, never declined");
        [declining declineWindow:identity(123,99)];[declining declineWindow:identity(123,99)];
        check([declining fixtureReleases]==1,@"a decline is queued once");
        [declining describe:screens bound:@{}];[declining submit];
        const struct dw2_record *sent=declining.fixtureRecords.bytes;
        check(declining.fixtureRecords.length==sizeof(*sent)+0&&sent[0].id.wid==99&&sent[0].flags==DW2_RECORD_RESTORE&&sent[0].id.pid==123&&sent[0].id.birth_sec==100&&sent[0].id.birth_usec==20,
            @"a decline is one release record for that exact window instance");
        uint64_t first=declining.fixtureSequence;[declining submit];check(declining.fixtureSequence==first,@"an unchanged pending release is not resent at once");
        [declining fixtureAck:@[@(DW2_IDENTITY)] sequence:first];
        check(![declining fixtureReleases],@"a decline is a hint: any reply retires it, none is retried");
        [declining describe:screens bound:@{}];check(!declining.fixtureRecords.length,@"the next frame no longer carries it");
        [declining declineWindow:identity(123,99)];[declining describe:screens bound:@{}];[declining submit];
        [declining fixtureAck:@[@(DW2_APPLIED)] sequence:declining.fixtureSequence];
        check(![declining fixtureReleases],@"an acknowledged decline is retired");
        [declining declineWindow:identity(123,100)];[declining fixtureExpire];
        check([declining fixtureReleases]==1,@"queued before the session ended");
        [plain finish];[declining finish];
    }
    printf("PASS: %lu presenter readiness checks; no native mutation or input-usability claim\n",(unsigned long)checks);
}return 0;}
