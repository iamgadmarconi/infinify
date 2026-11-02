// SPDX-License-Identifier: GPL-3.0-or-later
// In-memory frame selection only: no native windows or helper are touched.
#define main DWReadinessOriginalMain
#import "DWNativePresenterTests.m"
#undef main

@interface DWNativePresenter (FrameLimitFixture)
- (void)fixtureLimit:(uint32_t)limit;
- (void)fixtureScope:(BOOL)scoped;
- (void)fixtureRelease:(NSNumber *)wid;
- (uint64_t)fixtureReleaseSequence:(NSNumber *)wid;
- (void)fixtureEmptyFamily:(NSNumber *)wid;
- (NSUInteger)fixtureDescriptions;
- (void)fixtureTransition:(DWNativeHiddenRoot *)transition phase:(NSInteger)phase;
@end
@implementation DWNativePresenter (FrameLimitFixture)
- (void)fixtureLimit:(uint32_t)limit { _info.max_records=limit; }
- (void)fixtureScope:(BOOL)scoped { _scope=scoped?@{@123:@[@100,@20]}:nil; }
- (void)fixtureRelease:(NSNumber *)wid { [self releaseWindow:_windows[wid]]; }
- (uint64_t)fixtureReleaseSequence:(NSNumber *)wid { return _releases[wid]->releaseSeq; }
- (void)fixtureEmptyFamily:(NSNumber *)wid { _families[wid]=[NSSet set]; }
- (NSUInteger)fixtureDescriptions { return _desiredPlacements.count; }
- (void)fixtureTransition:(DWNativeHiddenRoot *)transition phase:(NSInteger)phase { transition->phase=phase; }
@end

static NSDictionary *limitPlacement(NSDictionary *root,NSNumber *logical,CGRect screen) {
    NSMutableDictionary *source=[root mutableCopy];source[@"owner"]=NSNull.null;
    return @{@"window":logical,@"output":@1,@"screen_rect":rect(screen),@"clip_rect":rect(screen),
        @"source":@{@"identity":source,@"generation":@1,@"observation_known":@YES}};
}
static void baseline(void) {
    CGRect native=CGRectMake(100,100,320,232);
    NSDictionary *a=identity(123,42),*b=identity(123,52),*c=identity(123,62);
    DWNativePresenter *presenter=[DWNativePresenter fixturePID:@123];
    [presenter bound:a bounds:native family:family(a,native,@[@43])];
    [presenter bound:b bounds:native family:family(b,native,@[@53])];
    [presenter bound:c bounds:native family:family(c,native,@[])];
    [presenter fixtureLimit:3];
    NSMutableDictionary *scene=[snapshot(a,1,1,CGRectMake(20,20,160,116),YES)mutableCopy];
    scene[@"placements"]=@[limitPlacement(a,@7,CGRectMake(20,20,160,116)),
        limitPlacement(b,@8,CGRectMake(2000,20,160,116)),limitPlacement(c,@9,CGRectMake(1400,20,160,116))];
    scene[@"focus"]=@{@"intent":@8};
    NSDictionary *bound=@{@7:a,@8:b,@9:c};
    [presenter describe:scene bound:bound];[presenter submit];
    NSData *frame=presenter.fixtureRecords;const struct dw2_record *records=frame.bytes;
    check(!presenter.ended&&presenter.fixtureSequence&&frame.length==3*sizeof(*records),@"over-limit frame stays active and bounded");
    check(records[0].id.wid==52&&records[1].id.wid==53&&records[2].id.wid==62,@"focused family is whole and remaining capacity selects the nearer family");
    [presenter fixtureAck:@[@0,@0,@0] sequence:presenter.fixtureSequence];
    check([presenter acknowledgedPlacementForWindow:@8 identity:b generation:@1 output:@1]!=nil,@"remapped focused family obtains a complete ACK receipt");
    check([presenter acknowledgedPlacementForWindow:@7 identity:a generation:@1 output:@1]==nil,@"omitted family has no receipt");
    uint64_t sequence=presenter.fixtureSequence;[presenter describe:scene bound:bound];[presenter submit];
    check(presenter.fixtureSequence==sequence,@"unchanged capped frame is not resent");
    [presenter finish];
}

static NSString *limitLog(void (^action)(void)) {
    int fds[2];check(pipe(fds)==0,@"capture diagnostic pipe");fflush(stderr);int saved=dup(STDERR_FILENO);
    check(saved>=0&&dup2(fds[1],STDERR_FILENO)>=0,@"capture diagnostics");close(fds[1]);action();fflush(stderr);
    check(dup2(saved,STDERR_FILENO)>=0,@"restore diagnostics");close(saved);
    char bytes[4096];ssize_t length=read(fds[0],bytes,sizeof(bytes));close(fds[0]);
    check(length>=0,@"read diagnostics");return [[NSString alloc]initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}
static DWNativePresenter *limitPair(NSDictionary *a,NSDictionary *b) {
    CGRect native=CGRectMake(100,100,320,232);DWNativePresenter *presenter=[DWNativePresenter fixturePID:@123];
    [presenter bound:a bounds:native family:family(a,native,@[])];[presenter bound:b bounds:native family:family(b,native,@[])];return presenter;
}
static NSMutableDictionary *limitScene(NSDictionary *a,NSDictionary *b) {
    NSMutableDictionary *scene=[snapshot(a,1,1,CGRectMake(1600,20,160,116),YES)mutableCopy];
    scene[@"placements"]=@[limitPlacement(a,@7,CGRectMake(1600,20,160,116)),limitPlacement(b,@8,CGRectMake(20,20,160,116))];return scene;
}
static void distance(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);[presenter fixtureLimit:1];
    [presenter describe:limitScene(a,b) bound:@{@7:a,@8:b}];[presenter submit];
    const struct dw2_record *records=presenter.fixtureRecords.bytes;
    check(presenter.fixtureRecords.length==sizeof(*records)&&records[0].id.wid==52,@"equal-size equal-tier families select the nearer, not the smaller key");[presenter finish];
}
static void restore(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);[presenter fixtureRelease:@52];[presenter fixtureLimit:1];
    NSMutableDictionary *scene=limitScene(a,b);scene[@"placements"]=@[limitPlacement(a,@52,CGRectMake(20,20,160,116))];
    [presenter describe:scene bound:@{@52:a}];[presenter submit];const struct dw2_record *records=presenter.fixtureRecords.bytes;
    check(presenter.fixtureRecords.length==sizeof(*records)&&records[0].id.wid==52&&(records[0].flags&DW2_RECORD_RESTORE),@"restore wins without merging its CGWindowID into an unrelated logical family");
    check([presenter fixtureReleaseSequence:@52]==presenter.fixtureSequence,@"selected restore gets its submitted sequence");[presenter finish];
}
static void omittedRelease(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);[presenter fixtureRelease:@52];[presenter fixtureLimit:1];
    NSMutableDictionary *scene=limitScene(a,b);scene[@"placements"]=@[limitPlacement(a,@7,CGRectMake(20,20,160,116))];scene[@"focus"]=@{@"intent":@7};
    [presenter describe:scene bound:@{@7:a}];[presenter submit];uint64_t seq=presenter.fixtureSequence;
    check(seq&&[presenter fixtureReleaseSequence:@52]==0,@"omitted release retains releaseSeq zero");[presenter fixtureAck:@[@0] sequence:seq];
    for(NSUInteger i=0;i<4;i++){[presenter fixtureRetry];[presenter describe:scene bound:@{@7:a}];[presenter submit];}
    check(presenter.fixtureSequence==seq&&[presenter fixtureReleaseSequence:@52]==0,@"omitted release does not resend an identical frame forever");
    scene[@"focus"]=@{};[presenter describe:scene bound:@{@7:a}];[presenter submit];
    check([presenter fixtureReleaseSequence:@52]>seq,@"release becomes eligible when focus no longer fills the frame");[presenter finish];
}
static void changed(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);NSMutableDictionary *scene=limitScene(a,b);
    [presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];[presenter fixtureLimit:1];
    scene[@"placements"]=@[limitPlacement(a,@7,CGRectMake(1800,20,160,116)),limitPlacement(b,@8,CGRectMake(20,20,160,116))];
    [presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];const struct dw2_record *records=presenter.fixtureRecords.bytes;
    check(presenter.fixtureRecords.length==sizeof(*records)&&records[0].id.wid==42,@"changed family outranks a nearer unchanged family");[presenter finish];
}
static void parking(void) {
    for(NSNumber *invalid in @[@NO,@YES]){
        NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);NSMutableDictionary *scene=limitScene(a,b);
        [presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];
        scene[@"placements"]=invalid.boolValue?@[limitPlacement(a,@7,CGRectMake(1e8,20,160,116)),scene[@"placements"][1]]:@[scene[@"placements"][1]];
        [presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];[presenter fixtureLimit:1];
        [presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];const struct dw2_record *records=presenter.fixtureRecords.bytes;
        check(presenter.fixtureRecords.length==sizeof(*records)&&records[0].id.wid==42&&records[0].m[4]<-1200,@"already parked family stays ahead of unchanged placements, including unrepresentable placed entries");[presenter finish];
    }
}
static void withheld(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);[presenter fixturePinned];NSMutableDictionary *scene=limitScene(a,b);
    [presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];[presenter fixtureAck:@[@0,@0] sequence:presenter.fixtureSequence];
    DWNativeHiddenRoot *transition=[presenter beginTransitionForWindow:a];check(transition!=nil,@"begin in-memory transition");
    for(NSNumber *phase in @[@1,@2,@4,@5]){
        [presenter fixtureTransition:transition phase:phase.integerValue];[presenter fixtureLimit:2];[presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];
        [presenter fixtureLimit:1];[presenter describe:scene bound:@{@7:a,@8:b}];[presenter submit];const struct dw2_record *records=presenter.fixtureRecords.bytes;
        check(presenter.fixtureRecords.length==sizeof(*records)&&records[0].id.wid==42,@"withheld transition phases remain eligible even when their record is unchanged");
    }
    [presenter finish];
}
static void oversized(void) {
    for(NSString *kind in @[@"focus",@"native_resize"]){
        NSDictionary *a=identity(123,42);CGRect native=CGRectMake(100,100,320,232);DWNativePresenter *presenter=[DWNativePresenter fixturePID:@123];
        [presenter bound:a bounds:native family:family(a,native,@[@43])];[presenter fixtureLimit:1];
        NSMutableDictionary *scene=[snapshot(a,1,1,CGRectMake(20,20,160,116),YES)mutableCopy];
        scene[kind]=[kind isEqual:@"focus"]?@{@"intent":@7}:@{@"pending_effect":@{@"window":@7}};
        NSString *log=limitLog(^{[presenter describe:scene bound:@{@7:a}];[presenter submit];});
        check(presenter.ended&&[log containsString:@"ended"]&&[log containsString:@"family"]&&[log containsString:@"limit"],@"oversized focused/enter family ends loudly");
    }
}
static void zero(void) {
    for(NSNumber *empty in @[@NO,@YES]){
        NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);[presenter fixtureLimit:0];
        NSMutableDictionary *scene=limitScene(a,b);if(empty.boolValue)scene[@"placements"]=@[];
        NSString *log=limitLog(^{[presenter describe:scene bound:empty.boolValue?@{}:@{@7:a,@8:b}];[presenter submit];});
        check(presenter.ended&&[log containsString:@"ended"]&&[log containsString:@"zero"],@"zero record limit ends loudly even for an empty frame");
    }
}
static void submitGuard(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);
    [presenter describe:limitScene(a,b) bound:@{@7:a,@8:b}];[presenter fixtureLimit:1];
    NSString *log=limitLog(^{[presenter submit];});check(presenter.ended&&[log containsString:@"ended"]&&[log containsString:@"limit"],@"unexpected submit overflow ends loudly");
}
static void emptyMembers(void) {
    for(NSNumber *limit in @[@1,@2]){
        NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);[presenter fixtureEmptyFamily:@42];[presenter fixtureLimit:limit.unsignedIntValue];
        NSMutableDictionary *scene=limitScene(a,b);NSDictionary *c=identity(123,62);CGRect native=CGRectMake(100,100,320,232);
        [presenter bound:c bounds:native family:family(c,native,@[])];scene[@"placements"]=[scene[@"placements"]arrayByAddingObject:limitPlacement(c,@9,CGRectMake(2000,20,160,116))];
        [presenter describe:scene bound:@{@7:a,@8:b,@9:c}];
        check(presenter.fixtureDescriptions==limit.unsignedIntValue,@"empty member descriptions are removed both with and without capping");[presenter finish];
    }
}
static void debugLimit(void) {
    NSDictionary *a=identity(123,42),*b=identity(123,52);DWNativePresenter *presenter=limitPair(a,b);NSMutableDictionary *scene=limitScene(a,b);
    setenv("INFINIFY_DEBUG_NATIVE_MAX_RECORDS","1",1);
    [presenter describe:scene bound:@{@7:a,@8:b}];check(presenter.fixtureRecords.length==2*sizeof(struct dw2_record),@"debug cap needs INFINIFY_DEBUG");
    setenv("INFINIFY_DEBUG","1",1);[presenter fixtureScope:NO];
    [presenter describe:scene bound:@{@7:a,@8:b}];check(presenter.fixtureRecords.length==2*sizeof(struct dw2_record),@"debug cap needs explicit scope");
    [presenter fixtureScope:YES];NSMutableDictionary *single=[scene mutableCopy];single[@"placements"]=@[scene[@"placements"][0]];
    [presenter describe:single bound:@{@7:a}];
    setenv("INFINIFY_DEBUG_NATIVE_MAX_RECORDS","2",1);[presenter fixtureLimit:1];
    [presenter describe:scene bound:@{@7:a,@8:b}];check(presenter.fixtureRecords.length==sizeof(struct dw2_record),@"debug cap never raises the helper limit");
    [presenter fixtureLimit:4];setenv("INFINIFY_DEBUG_NATIVE_MAX_RECORDS","1",1);
    [presenter describe:scene bound:@{@7:a,@8:b}];check(presenter.fixtureRecords.length==2*sizeof(struct dw2_record),@"debug cap parses once, only when a multi-record frame needs it");
    unsetenv("INFINIFY_DEBUG");unsetenv("INFINIFY_DEBUG_NATIVE_MAX_RECORDS");[presenter finish];
}
int main(void) {@autoreleasepool {
    unsetenv("INFINIFY_DEBUG");unsetenv("INFINIFY_DEBUG_NATIVE_MAX_RECORDS");const char *selected=getenv("INFINIFY_FRAME_LIMIT_CASE");
#define LIMIT_CASE(name) if(!selected||!strcmp(selected,#name))name()
    LIMIT_CASE(baseline);LIMIT_CASE(distance);LIMIT_CASE(restore);LIMIT_CASE(omittedRelease);LIMIT_CASE(changed);LIMIT_CASE(parking);
    LIMIT_CASE(withheld);LIMIT_CASE(oversized);LIMIT_CASE(zero);LIMIT_CASE(submitGuard);LIMIT_CASE(emptyMembers);LIMIT_CASE(debugLimit);
#undef LIMIT_CASE
    fprintf(stderr,"frame limit: %lu checks passed\n",(unsigned long)checks);return 0;
}}
