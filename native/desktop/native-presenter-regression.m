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
#import "native-presenter.m"
#undef NSScreen

struct dw_client { uint64_t sequence; };
static NSUInteger checks,closed;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
int dw_client_open(const char *runtime,const char *nonce,const struct dw_client_callbacks *callbacks,uint32_t timeout,dw_client **client,struct dw_client_info *info) {
    (void)runtime;(void)nonce;(void)callbacks;(void)timeout;(void)client;(void)info;return DW_CLIENT_INVALID;
}
int dw_client_submit_frame(dw_client *client,const struct dw2_record *records,uint32_t count,uint64_t *sequence) {
    check(client&&records&&count<=DW2_MAX_RECORDS,@"in-memory submission has a bounded complete frame");*sequence=++client->sequence;return DW_CLIENT_OK;
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
    [presenter bound:root bounds:native family:family(root,native,@[@43])];describe(presenter,root,1,1,screen);
    check(!receipt(presenter,root,1,1),@"describe is desired state, never an ACK");[presenter submit];
    check(!receipt(presenter,root,1,1),@"queueing a frame is not an ACK");ack(presenter);
    DWNativeAppliedPlacement *first=receipt(presenter,root,1,1);
    check(first&&first.sequence==presenter.fixtureSequence&&[presenter isAcknowledgedPlacementCurrent:first],@"complete current family ACK produces a revocable receipt");
    check(first.members.count==2&&[first.members[0][@"identity"]isEqual:root]&&[first.members[1][@"identity"]isEqual:identity(123,43)],@"receipt includes every sorted bound family member");
    check(CGRectEqualToRect(first.requestedScreenRect,screen)&&[first.members[0][@"requested_transform"]isEqual:@[@2,@0,@0,@2,@(-500),@(-400)]],@"receipt describes requested projection and exact emitted matrix");
    check(!receipt(presenter,identity(124,42),1,1)&&!receipt(presenter,root,2,1)&&!receipt(presenter,root,1,2),@"identity, generation and output are exact");

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
    [presenter bound:root bounds:native family:nil];describe(presenter,root,2,1,moved);[presenter submit];
    [presenter fixtureAck:@[@0] sequence:presenter.fixtureSequence];check(!receipt(presenter,root,2,1),@"unavailable family is never an acknowledged complete family");
    [presenter bound:root bounds:native family:family(root,native,@[@43])];describe(presenter,root,2,1,moved);[presenter submit];ack(presenter);current=receipt(presenter,root,2,1);
    check(current!=nil,@"fresh complete family requires and accepts its new ACK");
    old=presenter.fixtureSequence;[presenter describe:@{@"outputs":@[],@"placements":@[]} bound:@{@7:root}];[presenter submit];ack(presenter);
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

    NSDictionary *otherRoot=identity(124,82);DWNativePresenter *other=[DWNativePresenter fixturePID:@124];
    [other bound:otherRoot bounds:native family:family(otherRoot,native,@[@83])];describe(other,otherRoot,2,1,moved);[other submit];ack(other);
    DWNativeAppliedPlacement *otherReceipt=receipt(other,otherRoot,2,1);
    check(otherReceipt&&! [other isAcknowledgedPlacementCurrent:current]&&![presenter isAcknowledgedPlacementCurrent:otherReceipt],@"different helper sessions cannot reuse receipts or sequence values");
    DWNativePresenterGroup *group=[DWNativePresenterGroup new];group.sessions=@[presenter,other];group.owners=@{@123:presenter,@124:other};
    check([group isAcknowledgedPlacementCurrent:current]&&[group isAcknowledgedPlacementCurrent:otherReceipt]
        &&[group acknowledgedPlacementForWindow:@7 identity:root generation:@2 output:@1]!=nil,@"group delegates readiness to the exact owning session");
    [presenter unbound:root];check(![group isAcknowledgedPlacementCurrent:current],@"unbinding revokes a grouped receipt");
    [other fixtureExpire];check(!receipt(other,otherRoot,2,1)&&![group isAcknowledgedPlacementCurrent:otherReceipt],@"disconnect revokes receipt before main callback delivery");
    [group finish];check(closed==2,@"both in-memory sessions drain and close");
    printf("PASS: %lu presenter readiness checks; no native mutation or input-usability claim\n",(unsigned long)checks);
}return 0;}
