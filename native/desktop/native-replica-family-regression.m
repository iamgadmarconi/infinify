// SPDX-License-Identifier: GPL-3.0-or-later
// Actual recovery/lifecycle code with in-memory streams, deterministic clocks
// and substituted identity reads. No capture, window, native getter or input.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#include <libproc.h>
#include <unistd.h>

static NSUInteger checks,notified;
static CFTimeInterval now=100,birthReadAdvance;
static BOOL birthMatches=YES;
static NSMutableArray<dispatch_block_t> *queued;
static NSMutableArray<NSDictionary *> *timers;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static CFTimeInterval recoveryClock(void) { return now; }
static dispatch_time_t recoveryTime(dispatch_time_t when,int64_t delta) {
    check(when==DISPATCH_TIME_NOW&&delta>=0&&delta<=(int64_t)(2*NSEC_PER_SEC),@"watchdog is bounded and includes queue delay");return (dispatch_time_t)delta;
}
static void recoveryAfter(dispatch_time_t delay,dispatch_queue_t queue,dispatch_block_t block) {
    (void)queue;[timers addObject:@{@"at":@(now+(double)delay/NSEC_PER_SEC),@"block":[block copy]}];
}
static void recoveryAsync(dispatch_queue_t queue,dispatch_block_t block) { (void)queue;[queued addObject:[block copy]]; }
static int recoveryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size) {
    check(pid==123&&flavor==PROC_PIDTBSDINFO&&!argument&&size==sizeof(struct proc_bsdinfo),@"only declared identity is read");
    now+=birthReadAdvance;struct proc_bsdinfo *process=buffer;memset(process,0,sizeof(*process));
    process->pbi_uid=getuid();process->pbi_start_tvsec=birthMatches?100:101;process->pbi_start_tvusec=20;return size;
}
static CFArrayRef recoveryWindows(CGWindowListOption options,CGWindowID window) {
    (void)options;(void)window;check(NO,@"headless recovery must not enumerate windows");return NULL;
}
static bool recoveryPermission(void) { check(NO,@"headless recovery must not query permissions");return false; }
#define CACurrentMediaTime recoveryClock
#define dispatch_time recoveryTime
#define dispatch_after recoveryAfter
#define dispatch_async recoveryAsync
#define proc_pidinfo recoveryProcess
#define CGWindowListCopyWindowInfo recoveryWindows
#define CGPreflightScreenCaptureAccess recoveryPermission
#import "native-replica-family.m"
#undef CACurrentMediaTime
#undef dispatch_time
#undef dispatch_after
#undef dispatch_async
#undef proc_pidinfo
#undef CGWindowListCopyWindowInfo
#undef CGPreflightScreenCaptureAccess

NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why) {
    (void)identity;(void)why;check(NO,@"headless recovery must not read native families");return nil;
}
BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *root) {
    (void)member;(void)root;check(NO,@"headless recovery must not read native parentage");return NO;
}
bool DWNativeBounds(uint32_t wid,CGRect *out) { (void)wid;(void)out;check(NO,@"headless recovery must not read native bounds");return false; }

// Only the generic retained image holder is substituted; recovery and stream
// membership, ordering, deadlines and callbacks above are the production code.
@implementation DWCanvasAttachment
@synthesize buffer=_buffer;
- (instancetype)init { if((self=[super init]))_contentRect=CGRectNull;return self; }
- (void)setBuffer:(CVPixelBufferRef)buffer { if(buffer)CVPixelBufferRetain(buffer);if(_buffer)CVPixelBufferRelease(_buffer);_buffer=buffer; }
- (CVPixelBufferRef)buffer { return _buffer; }
- (void)dealloc { if(_buffer)CVPixelBufferRelease(_buffer); }
@end

@interface RecoveryStream : NSObject
@property(copy) void (^completion)(NSError *);
@property NSUInteger stopped,removed;
@end
@implementation RecoveryStream
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion { self.completion=completion; }
- (BOOL)removeStreamOutput:(id<SCStreamOutput>)output type:(SCStreamOutputType)type error:(NSError *__autoreleasing *)error {
    (void)error;check(output&&type==SCStreamOutputTypeScreen,@"retire removes this exact screen output");self.removed++;return YES;
}
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion { self.stopped++;completion(nil); }
@end
static void drain(void) {
    while(queued.count){dispatch_block_t block=queued.firstObject;[queued removeObjectAtIndex:0];block();}
}
static void advance(CFTimeInterval target) {
    check(target>=now,@"fixture clock is monotonic");now=target;
    for(NSDictionary *timer in timers.copy)if([timer[@"at"]doubleValue]<=now){[timers removeObject:timer];dispatch_block_t block=timer[@"block"];block();}
    drain();
}
static NSDictionary *identity(uint32_t wid) { return @{@"pid":@123,@"birth_sec":@100,@"birth_usec":@20,@"wid":@(wid)}; }
static NSDictionary *rect(CGRect bounds) { return @{@"origin":@{@"x":@(bounds.origin.x),@"y":@(bounds.origin.y)},@"size":@{@"width":@(bounds.size.width),@"height":@(bounds.size.height)}}; }
static NSDictionary *root(void) { return @{@"window":@7,@"identity":identity(42),@"generation":@3,@"native_bounds":rect(CGRectMake(100,100,320,232)),@"density":@2,@"capture":@YES}; }
static CGRect childBounds(void) { return CGRectMake(106,106,66,20); }
static NSDictionary *plan(uint32_t wid) { return @{@"identity":identity(wid),@"native_bounds":rect(childBounds())}; }
static DWNativeReplicaFamilies *provider(void) {
    DWNativeReplicaFamilies *owner=[[DWNativeReplicaFamilies alloc]initWithChanged:^(NSNumber *window){check([window isEqual:@7],@"callback names its logical root");notified++;}];
    owner.roots=@{@7:root()};return owner;
}
static DWReplicaMember *attempt(DWNativeReplicaFamilies *owner,uint32_t wid,NSUInteger *recovering) {
    DWReplicaRecovery *record=[owner admitRecovery:identity(wid) root:owner.roots[@7] bounds:childBounds() recovering:recovering];if(!record)return nil;
    DWReplicaMember *member=[DWReplicaMember new];member.owner=owner;member.root=owner.roots[@7];member.identity=identity(wid);
    member.bounds=childBounds();member.rootBounds=familyRect(member.root[@"native_bounds"]);member.image=[DWCanvasAttachment new];member.image.key=[@(wid)stringValue];
    member.stream=(SCStream *)[RecoveryStream new];record.attempt=member;
    owner.members[@7]=[(owner.members[@7]?:@[]) arrayByAddingObject:member];return member;
}
static void started(DWReplicaMember *member) { RecoveryStream *stream=(RecoveryStream *)member.stream;[member start];stream.completion(nil);drain();check(member.started,@"current start completion marks only its attempt"); }
static void validImage(DWReplicaMember *member) {
    CVPixelBufferRef pixels=NULL;check(CVPixelBufferCreate(kCFAllocatorDefault,2,2,kCVPixelFormatType_32BGRA,NULL,&pixels)==kCVReturnSuccess,@"allocate an in-memory image");
    member.image.buffer=pixels;CVPixelBufferRelease(pixels);[member.owner memberBecameDrawable:member];
}
int main(void) {@autoreleasepool {
    check(NSThread.isMainThread,@"lifecycle owner is main-thread only");queued=[NSMutableArray array];timers=[NSMutableArray array];
    DWNativeReplicaFamilies *owner=provider();NSUInteger recovering=0;
    DWReplicaMember *first=attempt(owner,43,&recovering);check(first&&recovering==0,@"a new binding is an initial attempt");RecoveryStream *stream=(RecoveryStream *)first.stream;
    [first start];check(first.startDeadline==102&&!first.firstFrameDeadline,@"start deadline precedes the separate first-image deadline");advance(101.999);
    check(atomic_load(&first->alive),@"no premature start timeout");advance(102);
    DWReplicaRecovery *record=owner.recoveries[@7][@43];
    check(!atomic_load(&first->alive)&&[first.failure containsString:@"start timed out"]&&stream.stopped==1&&stream.removed==1,@"missing start completion retires exactly once");
    check(record.failures==1&&record.notBefore>102.5&&record.notBefore<=102.75,@"first failure installs bounded jittered backoff");
    NSUInteger epoch=owner.epoch;stream.completion(nil);drain();
    check(!first.started&&owner.epoch==epoch,@"late successful start cannot resurrect a failed attempt");
    check(!attempt(owner,43,&recovering),@"recovery waits for its exact backoff deadline");
    NSMutableDictionary *density=[root()mutableCopy];density[@"density"]=@1;owner.roots=@{@7:density};
    check(!attempt(owner,43,&recovering)&&owner.recoveries[@7][@43]==record,@"capture density changes preserve failed history");

    advance(record.notBefore);DWReplicaMember *second=attempt(owner,43,&recovering);check(second&&recovering==1,@"due retry consumes one turn allowance");
    started(second);advance(second.firstFrameDeadline);
    check(!atomic_load(&second->alive)&&[second.failure containsString:@"no valid image"]&&record.failures==2,@"successful start without a callback also expires");
    check(record.notBefore>now+1&&record.notBefore<=now+1.25,@"consecutive first-frame failure increases backoff");
    advance(record.notBefore);recovering=0;DWReplicaMember *third=attempt(owner,43,&recovering);started(third);
    CMSampleBufferRef sample=NULL;check(CMSampleBufferCreate(kCFAllocatorDefault,NULL,true,NULL,NULL,NULL,0,0,NULL,0,NULL,&sample)==noErr,@"construct callback without image data");
    [third stream:third.stream didOutputSampleBuffer:sample ofType:SCStreamOutputTypeScreen];CFRelease(sample);
    check(atomic_load(&third->received)&&!third.image.buffer,@"an unusable callback is distinguished from no callback");advance(third.firstFrameDeadline);
    check(!atomic_load(&third->alive)&&record.failures==3,@"unusable callbacks do not satisfy the valid-image deadline");

    advance(record.notBefore);recovering=0;DWReplicaMember *healthy=attempt(owner,43,&recovering);started(healthy);validImage(healthy);
    check(record.failures==0&&!record.notBefore,@"first validated image resets consecutive failure history");
    advance(healthy.firstFrameDeadline);check(atomic_load(&healthy->alive)&&healthy.image.buffer,@"valid current image survives its first-frame watchdog");
    epoch=owner.epoch;[owner memberFailed:third];[third expireFirstFrame];
    check(owner.epoch==epoch&&!record.failures&&record.attempt==healthy,@"old exact-WID attempts cannot alter replacement state");
    [owner attachments:@7];[healthy fail:@"fixture configuration failure" code:"configuration_failed" error:0];
    check(!healthy.image.buffer&&![owner attachments:@7].count&&![owner hit:@7 key:@"43" local:CGPointMake(8,8)],@"failure withdraws pixels, cached attachments and child hits");
    check(record.failures==1,@"a later failure starts again at the first backoff");

    DWNativeReplicaFamilies *slowOwner=provider();NSUInteger slowRetries=0;DWReplicaMember *slow=attempt(slowOwner,43,&slowRetries);RecoveryStream *slowStream=(RecoveryStream *)slow.stream;
    [slow start];CFTimeInterval began=now;advance(began+1.99);slowStream.completion(nil);drain();
    check(slow.started&&slow.firstFrameDeadline==now+2,@"late successful start receives a full separate first-image budget");
    advance(began+2.01);check(atomic_load(&slow->alive),@"expired start watchdog does not shorten the image deadline");
    advance(slow.firstFrameDeadline);check(!atomic_load(&slow->alive),@"late successful start still has a bounded image wait");
    [slowOwner reset];slowOwner=provider();slowRetries=0;slow=attempt(slowOwner,43,&slowRetries);slowStream=(RecoveryStream *)slow.stream;
    [slow start];began=now;slowStream.completion(nil);now+=.4;drain();
    check(slow.firstFrameDeadline==began+2,@"first-image deadline includes start completion's main-queue wait");
    validImage(slow);advance(slow.firstFrameDeadline);check(atomic_load(&slow->alive),@"valid first image cancels timeout effect after queued completion");[slowOwner reset];

    [owner reset];owner=provider();recovering=0;DWReplicaMember *one=attempt(owner,43,&recovering),*two=attempt(owner,44,&recovering),*three=attempt(owner,45,&recovering);
    for(DWReplicaMember *member in @[one,two,three])[member fail:@"fixture failure" code:"start_failed" error:0];advance(now+1);recovering=0;
    check([owner admitRecovery:identity(43) root:root() bounds:childBounds() recovering:&recovering]!=nil,@"first due retry admitted");
    check([owner admitRecovery:identity(44) root:root() bounds:childBounds() recovering:&recovering]!=nil,@"second due retry admitted");
    check(![owner admitRecovery:identity(45) root:root() bounds:childBounds() recovering:&recovering]&&recovering==2,@"third retry waits for another completed observation");
    check([owner admitRecovery:identity(46) root:root() bounds:childBounds() recovering:&recovering]!=nil&&recovering==2,@"new distinct binding does not consume a recovery allowance");
    check(familyRecoveryDelay(identity(43),1)!=familyRecoveryDelay(identity(44),1),@"different bindings are staggered");
    for(NSUInteger failures=1;failures<=20;failures++){CFTimeInterval delay=familyRecoveryDelay(identity(43),failures);check(delay>.5&&delay<=30,@"retry delay remains bounded");}
    check(familyRecoveryDelay(identity(43),7)!=familyRecoveryDelay(identity(44),7),@"jitter survives the retry ceiling");

    record=owner.recoveries[@7][@43];NSUInteger count=owner.recoveries[@7].count;
    [owner acceptRecoveryCohort:@[] root:root() sampledAt:nil];[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now-.101)];[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now+1)];
    check(owner.recoveries[@7].count==count&&record.failures==1,@"missing, stale or future membership cannot forget failed history");
    birthMatches=NO;[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now)];birthMatches=YES;
    check(owner.recoveries[@7].count==count,@"reused process birth cannot prune history");
    birthReadAdvance=.101;[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now)];birthReadAdvance=0;
    check(owner.recoveries[@7].count==count,@"freshness includes the main-thread birth read");
    [owner acceptRecoveryCohort:@[plan(43)] root:root() sampledAt:@(now-.01)];
    check(owner.recoveries[@7].count==1&&owner.recoveries[@7][@43]==record&&record.failures==1,@"fresh complete cohort prunes absent members and preserves matching history");
    [owner invalidatePID:0 discardRecovery:NO];check(owner.recoveries[@7][@43]==record,@"stalled observation retires streams but retains backoff");
    [owner invalidatePID:123];check(!owner.recoveries.count,@"explicit process/session invalidation discards history");

    owner=provider();recovering=0;one=attempt(owner,43,&recovering);[one fail:@"fixture failure" code:"start_failed" error:0];record=owner.recoveries[@7][@43];
    CGRect changed=childBounds();changed.size.width++;
    check([owner admitRecovery:identity(43) root:root() bounds:changed recovering:&recovering]!=record,@"freshly validated native size replacement resets old binding history");
    record=owner.recoveries[@7][@43];NSMutableDictionary *reused=[identity(43)mutableCopy];reused[@"birth_usec"]=@21;
    check([owner admitRecovery:reused root:root() bounds:changed recovering:&recovering]!=record,@"same WID in another process birth is a distinct binding");
    owner.requestPending=YES;NSMutableDictionary *generation=[root()mutableCopy];generation[@"generation"]=@4;[owner describe:@[generation] rate:120];
    check(!owner.recoveries.count,@"root generation change retires old negative history");
    check([owner admitRecovery:identity(43) root:generation bounds:changed recovering:&recovering]!=nil,@"new generation is eligible independently");
    NSMutableDictionary *hidden=[generation mutableCopy];hidden[@"capture"]=@NO;[owner describe:@[hidden] rate:120];
    check(!owner.recoveries.count,@"capture admission loss retires history");

    owner=provider();recovering=0;
    for(uint32_t wid=100;wid<164;wid++)check([owner admitRecovery:identity(wid) root:root() bounds:childBounds() recovering:&recovering]!=nil,@"bounded family record admitted");
    check(![owner admitRecovery:identity(164) root:root() bounds:childBounds() recovering:&recovering]&&owner.recoveries[@7].count==64,@"stale unpruned families cannot grow negative history indefinitely");
    [owner acceptRecoveryCohort:@[plan(163)] root:root() sampledAt:@(now)];
    check(owner.recoveries[@7].count==1&&[owner admitRecovery:identity(164) root:root() bounds:childBounds() recovering:&recovering]!=nil,@"fresh absence frees bounded history slots");

    owner=provider();recovering=0;__weak DWReplicaMember *released;
    @autoreleasepool {DWReplicaMember *retired=attempt(owner,43,&recovering);released=retired;[retired start];[retired retire];[owner.members removeAllObjects];}
    check(!released,@"watchdog and start completion do not retain a retired attempt");
    DWReplicaMember *replacement=attempt(owner,43,&recovering);started(replacement);validImage(replacement);advance(now+2);
    check(atomic_load(&replacement->alive)&&replacement.image.buffer,@"old weak watchdog cannot retire same-binding replacement");
    [owner reset];check(!owner.recoveries.count&&!owner.roots.count&&!owner.members.count,@"reset withdraws all capture/recovery state");
    check(notified>0&&!queued.count,@"mutations notified and all queued completions drained");
    printf("PASS: %lu family capture recovery checks (headless substituted lifecycle only)\n",(unsigned long)checks);return 0;
}}
