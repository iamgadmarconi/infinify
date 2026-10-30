// SPDX-License-Identifier: GPL-3.0-or-later
// Actual forward/restore implementation with native substitutes. This checks
// outcomes and native-call counts, never native compositing.
#import <AppKit/AppKit.h>
#import <libproc.h>
#include <assert.h>
static CFArrayRef testWindows(CGWindowListOption option,CGWindowID wid);
static int testProcess(int pid,int flavor,uint64_t argument,void *buffer,int size);
#define CGWindowListCopyWindowInfo testWindows
#define proc_pidinfo testProcess
#import "payload.m"
#undef CGWindowListCopyWindowInfo
#undef proc_pidinfo
static CGAffineTransform transforms[2];
static float alphas[2];
static int owners[2];
static unsigned transformSets,transformGets,alphaSets,alphaGets,identityGets;
static BOOL ignoreTransform,failAlphaRead,replaceOnAlphaRead;
static unsigned indexOf(uint32_t wid){assert(wid==42||wid==43);return wid-42;}
// Native writes in the order they reach the window server: "T<wid>" and "A<wid>:<alpha>".
static NSMutableArray<NSString *> *events;
static int testConnection(void){return 1;}
static CGError testOwner(int cid,uint32_t wid,int *owner){assert(cid==1);identityGets++;*owner=owners[indexOf(wid)];return 0;}
static CGError testOwnerPID(int owner,pid_t *pid){assert(owner==7||owner==8);*pid=123;return 0;}
static int testProcess(int pid,int flavor,uint64_t argument,void *buffer,int size){
    (void)flavor;(void)argument;assert(pid==123&&size==sizeof(struct proc_bsdinfo));
    struct proc_bsdinfo info={.pbi_start_tvsec=100,.pbi_start_tvusec=20,.pbi_uid=getuid()};memcpy(buffer,&info,sizeof(info));return size;
}
static CFArrayRef testWindows(CGWindowListOption option,CGWindowID wid){
    assert(option==kCGWindowListOptionAll||option==kCGWindowListOptionIncludingWindow);(void)wid;
    return CFRetain((__bridge CFArrayRef)@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123,(id)kCGWindowLayer:@0,(id)kCGWindowIsOnscreen:@YES},
        @{(id)kCGWindowNumber:@43,(id)kCGWindowOwnerPID:@123,(id)kCGWindowLayer:@0,(id)kCGWindowIsOnscreen:@YES}]);
}
static CGError testTransformGet(int cid,uint32_t wid,CGAffineTransform *value){assert(cid==1);transformGets++;*value=transforms[indexOf(wid)];return 0;}
static CGError testTransformSet(int cid,uint32_t wid,CGAffineTransform value){assert(cid==1);transformSets++;[events addObject:[NSString stringWithFormat:@"T%u",wid]];if(!ignoreTransform)transforms[indexOf(wid)]=value;return 0;}
static CGError testBounds(int cid,uint32_t wid,CGRect *value){assert(cid==1);indexOf(wid);*value=CGRectMake(25,35,300,200);return 0;}
static CGError testAlphaGet(int cid,uint32_t wid,float *value){
    assert(cid==1);alphaGets++;*value=alphas[indexOf(wid)];if(replaceOnAlphaRead){replaceOnAlphaRead=NO;owners[indexOf(wid)]++;}return failAlphaRead?1000:0;
}
static CGError testAlphaSet(int cid,uint32_t wid,float value){assert(cid==1);alphaSets++;[events addObject:[NSString stringWithFormat:@"A%u:%.2f",wid,value]];alphas[indexOf(wid)]=value;return 0;}
static void resetState(void){
    assert(unlinkat(directoryFD,"v2-journal.json",0)==0||errno==ENOENT);
    v2Table=[NSMutableDictionary dictionary];v2Released=[NSMutableDictionary dictionary];v2JournalStale=NO;
    for(unsigned i=0;i<2;i++){transforms[i]=CGAffineTransformMake(1,0,0,1,-25,-35);alphas[i]=1;owners[i]=7;}
    transformSets=transformGets=alphaSets=alphaGets=identityGets=0;
    ignoreTransform=failAlphaRead=replaceOnAlphaRead=NO;
}
static struct dw2_record recordFor(uint32_t wid){return (struct dw2_record){.id={.pid=123,.wid=wid,.birth_sec=100,.birth_usec=20},.m={2,0,0,2,-50,-70},.flags=DW2_RECORD_HAS_ALPHA,.alpha=.5f};}
static void assertRestored(void){
    struct dw2_restore_reply result={0};v2Restore(@"forward test",NO,nil,&result);assert(!result.pending&&!v2Table.count&&result.journal_persisted);
    for(unsigned i=0;i<2;i++)assert(v2SameTransform(transforms[i],CGAffineTransformMake(1,0,0,1,-25,-35))&&alphas[i]==1);
}
// Two windows an application just opened, veiled by the helper, then placed by one frame whose records carry no alpha: for each,
// its transform reaches the window server before its original alpha does.
static void veilThenPlace(void){
    resetState();events=[NSMutableArray array];
    v2Veil(42);v2Veil(43);
    assert(v2Table.count==2&&alphas[0]==0&&alphas[1]==0&&!transformSets&&v2Table[@42]->veiled&&v2Table[@43]->veiled);
    struct dw2_record plain[2]={recordFor(42),recordFor(43)};uint8_t statuses[2]={255,255};
    for(unsigned i=0;i<2;i++)plain[i].flags=0;
    [events removeAllObjects];uint64_t generation=v2Generation;
    v2Apply(plain,2,statuses);
    // One journal write for the whole frame, before any transform: the first frame says each window now owes its transform.
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&alphas[0]==1&&alphas[1]==1&&v2Generation==generation+1);
    for(NSNumber *wid in @[@42,@43]){
        NSUInteger transform=NSNotFound,alpha=NSNotFound;
        for(NSUInteger i=0;i<events.count;i++){
            NSString *event=events[i];
            if(transform==NSNotFound&&[event isEqual:[NSString stringWithFormat:@"T%@",wid]])transform=i;
            if([event hasPrefix:[NSString stringWithFormat:@"A%@:",wid]])alpha=i;
        }
        if(transform==NSNotFound||alpha==NSNotFound||transform>alpha){fprintf(stderr,"window %u alpha before transform: %s\n",wid.unsignedIntValue,[[events componentsJoinedByString:@" "]UTF8String]);abort();}
    }
    assert(!v2Table[@42]->veiled&&!v2Table[@43]->veiled&&!v2Table[@42]->veilBare&&!v2Table[@43]->veilBare);
    [events removeAllObjects];generation=v2Generation;v2Apply(plain,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&v2Generation==generation&&![events containsObject:@"A42:1.00"]&&![events containsObject:@"A43:1.00"]); // later frames write no alpha and no journal
    assertRestored();
}
int main(void){@autoreleasepool{
    mainConnection=testConnection;getOwner=testOwner;connectionPID=testOwnerPID;getTransform=testTransformGet;setTransform=testTransformSet;
    getBounds=testBounds;getAlpha=testAlphaGet;setAlpha=testAlphaSet;fixtureOnly=NO;
    v2WriterIdentity=@{@"server_pid":@(getpid()),@"server_birth_sec":@1000,@"server_birth_usec":@0,@"server_uid":@(getuid()),@"boot_uuid":@"48359692-C6EC-4E77-8BD8-B68CF839CB16"};
    v2RetryScheduled=YES;
    char directory[]="/tmp/infinify-forward-operations.XXXXXX";assert(mkdtemp(directory));directoryFD=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);assert(directoryFD>=0);
    resetState();struct dw2_record records[2]={recordFor(42),recordFor(43)};uint8_t statuses[2]={255,255};
    v2Apply(records,2,statuses);assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&transformSets==2&&alphaSets==2);
    uint64_t generation=v2Generation;unsigned beforeAlpha=alphaSets,beforeTransform=transformSets;
    for(unsigned i=0;i<10;i++)v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&transformSets==beforeTransform&&v2Generation==generation);
    // Repeated identical frames write no alpha again: each skip needs a fresh native read that already shows the wanted value.
    assert(alphaSets==beforeAlpha);
    printf("{\"repeated_frames\":10,\"windows\":2,\"transform_sets\":%u,\"alpha_sets\":%u,\"alpha_gets\":%u,\"identity_gets\":%u,\"journal_writes_after_admission\":0}\n",transformSets,alphaSets,alphaGets,identityGets);
    // External drift is corrected even when the desired alpha is unchanged.
    alphas[0]=.75f;beforeAlpha=alphaSets;v2Apply(records,2,statuses);assert(statuses[0]==DW2_APPLIED&&alphas[0]==.5f&&alphaSets>beforeAlpha);
    // Failed native alpha readback can never be acknowledged as applied.
    failAlphaRead=YES;v2Apply(records,2,statuses);assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED);failAlphaRead=NO;
    assertRestored();
    // The arrival veil needs a desktop helper's identity and a queue that never runs its 1-second bound on its own.
    {static dispatch_queue_t held;held=dispatch_queue_create("dw.forward.veil",DISPATCH_QUEUE_SERIAL);dispatch_suspend(held);v2q=held;}
    v2VeilRegistered=YES;atomic_store(&v2VeilOn,true);atomic_store(&v2VeilClient,999);
    veilThenPlace();
    // On the skip path, identity loss during alpha readback never authorizes a
    // corrective setter and final identity still prevents APPLIED.
    resetState();v2Apply(records,2,statuses);alphas[0]=.75f;replaceOnAlphaRead=YES;beforeAlpha=alphaSets;
    v2Apply(records,2,statuses);assert(statuses[0]==DW2_IDENTITY&&alphaSets==beforeAlpha);owners[0]=7;
    assertRestored();
    puts("PASS: alpha de-duplication, drift correction, failed readback, identity fences, veil ordering and exact restoration; substituted native calls only");
    resetState();close(directoryFD);directoryFD=-1;assert(!rmdir(directory));
    return 0;
}}
