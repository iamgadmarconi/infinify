// SPDX-License-Identifier: GPL-3.0-or-later
// Actual forward/restore implementation with native substitutes. This checks
// outcomes and native-call counts, never native compositing or transaction ABI.
// DW_FORWARD_PAYLOAD may point at the frozen baseline payload.m for the same test.
#import <AppKit/AppKit.h>
#import <libproc.h>
#include <assert.h>
static CFArrayRef testWindows(CGWindowListOption option,CGWindowID wid);
static int testProcess(int pid,int flavor,uint64_t argument,void *buffer,int size);
static int testSync(int fd);
#define CGWindowListCopyWindowInfo testWindows
#define proc_pidinfo testProcess
#define fsync testSync
// Compile optional paths into this substituted-call test even when the default
// production build excludes them completely.
#ifndef DW_FORWARD_ONLY_SCALAR
#define DW_FORWARD_ONLY_SCALAR 0
#endif
#if !DW_FORWARD_ONLY_SCALAR
#define DW_V2_FORWARD_TEST 1
#endif
#ifndef DW_FORWARD_PAYLOAD
#define DW_FORWARD_PAYLOAD "payload.m"
#endif
#import DW_FORWARD_PAYLOAD
#undef CGWindowListCopyWindowInfo
#undef proc_pidinfo
#undef fsync
#ifndef DW_TEST_FROZEN_BASELINE
#define DW_TEST_FROZEN_BASELINE 0
#endif
static CGAffineTransform transforms[2];
static float alphas[2];
static int owners[2];
static unsigned transformSets,transformGets,alphaSets,alphaGets,identityGets,transactionCreates,transactionStages,transactionCommits,listCalls;
static BOOL ignoreTransform,failAlphaRead,replaceOnAlphaRead,replaceOnStage,failStage,failCommit,ignoreCommit,ignoreList,failList,replaceAfterPersist;
static unsigned indexOf(uint32_t wid){assert(wid==42||wid==43);return wid-42;}
// Native writes in the order they reach the window server: "T<wid>", "A<wid>:<alpha>", and "C"/"L" for a committed batch.
static NSMutableArray<NSString *> *events;
static int testConnection(void){return 1;}
static int testSync(int fd){int status=fsync(fd);if(!status&&fd==directoryFD&&replaceAfterPersist){replaceAfterPersist=NO;owners[0]++;}return status;}
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
#if !DW_TEST_FROZEN_BASELINE && DW_V2_BATCH_COMPILED
static CFTypeRef testTransactionCreate(int cid){assert(cid==1);transactionCreates++;return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);}
static void testTransactionStage(CFTypeRef transaction,uint32_t wid,int first,int second,CGAffineTransform value){
    assert(!first&&!second);indexOf(wid);transactionStages++;
    if(!failStage)((__bridge NSMutableDictionary *)transaction)[@(wid)]=[NSValue valueWithBytes:&value objCType:@encode(CGAffineTransform)];
    if(replaceOnStage){replaceOnStage=NO;owners[0]++;}
}
static void testTransactionCommit(CFTypeRef transaction,int synchronous){
    assert(synchronous==DW_V2_TRANSACTION_SYNC);transactionCommits++;[events addObject:@"C"];
    if(!ignoreCommit&&!failCommit)for(NSNumber *wid in (__bridge NSDictionary *)transaction){CGAffineTransform value;[((__bridge NSDictionary *)transaction)[wid]getValue:&value];transforms[indexOf(wid.unsignedIntValue)]=value;}
}
static CGError testWindowList(int cid,const uint32_t *wids,const CGAffineTransform *values,uint32_t count){
    assert(cid==1&&count>0&&count<=2);listCalls++;[events addObject:@"L"];
    if(!ignoreList)for(uint32_t i=0;i<count;i++)transforms[indexOf(wids[i])]=values[i];
    return failList?1000:0;
}
#endif
static void resetState(void){
    assert(unlinkat(directoryFD,"v2-journal.json",0)==0||errno==ENOENT);
    v2Table=[NSMutableDictionary dictionary];v2Released=[NSMutableDictionary dictionary];v2JournalStale=NO;
    for(unsigned i=0;i<2;i++){transforms[i]=CGAffineTransformMake(1,0,0,1,-25,-35);alphas[i]=1;owners[i]=7;}
    transformSets=transformGets=alphaSets=alphaGets=identityGets=transactionCreates=transactionStages=transactionCommits=listCalls=0;
    ignoreTransform=failAlphaRead=replaceOnAlphaRead=replaceOnStage=failStage=failCommit=ignoreCommit=ignoreList=failList=replaceAfterPersist=NO;
#if !DW_TEST_FROZEN_BASELINE && DW_V2_BATCH_COMPILED
    v2UseTransactionBatch=NO;v2UseWindowListBatch=NO;
#endif
}
static struct dw2_record recordFor(uint32_t wid){return (struct dw2_record){.id={.pid=123,.wid=wid,.birth_sec=100,.birth_usec=20},.m={2,0,0,2,-50,-70},.flags=DW2_RECORD_HAS_ALPHA,.alpha=.5f};}
static void assertRestored(void){
    struct dw2_restore_reply result={0};v2Restore(@"forward comparison",NO,nil,&result);assert(!result.pending&&!v2Table.count&&result.journal_persisted);
    for(unsigned i=0;i<2;i++)assert(v2SameTransform(transforms[i],CGAffineTransformMake(1,0,0,1,-25,-35))&&alphas[i]==1);
}
#if !DW_TEST_FROZEN_BASELINE
// Two windows an application just opened, veiled by the helper, then placed by one frame whose records carry no alpha: for each,
// its transform reaches the window server before its original alpha does, whichever way the transforms are submitted.
static void veilThenPlace(const char *how,BOOL transaction,BOOL list){
    resetState();events=[NSMutableArray array];
#if DW_V2_BATCH_COMPILED
    v2UseTransactionBatch=transaction;v2UseWindowListBatch=list;
#else
    (void)transaction;(void)list;
#endif
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
            if(transform==NSNotFound&&([event isEqual:[NSString stringWithFormat:@"T%@",wid]]||[event isEqual:@"C"]||[event isEqual:@"L"]))transform=i;
            if([event hasPrefix:[NSString stringWithFormat:@"A%@:",wid]])alpha=i;
        }
        if(transform==NSNotFound||alpha==NSNotFound||transform>alpha){fprintf(stderr,"%s: window %u alpha before transform: %s\n",how,wid.unsignedIntValue,[[events componentsJoinedByString:@" "]UTF8String]);abort();}
    }
    assert(!v2Table[@42]->veiled&&!v2Table[@43]->veiled&&!v2Table[@42]->veilBare&&!v2Table[@43]->veilBare);
    [events removeAllObjects];generation=v2Generation;v2Apply(plain,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&v2Generation==generation&&![events containsObject:@"A42:1.00"]&&![events containsObject:@"A43:1.00"]); // later frames write no alpha and no journal
    assertRestored();
}
#endif
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
#if DW_TEST_FROZEN_BASELINE || !DW_V2_ALPHA_DEDUP
    assert(alphaSets==beforeAlpha+20);
#else
    assert(alphaSets==beforeAlpha);
#endif
    printf("{\"mode\":\"%s\",\"repeated_frames\":10,\"windows\":2,\"transform_sets\":%u,\"alpha_sets\":%u,\"alpha_gets\":%u,\"identity_gets\":%u,\"journal_writes_after_admission\":0}\n",DW_TEST_FROZEN_BASELINE?"frozen-baseline":"candidate-scalar",transformSets,alphaSets,alphaGets,identityGets);
    // External drift is corrected even when the desired alpha is unchanged.
    alphas[0]=.75f;beforeAlpha=alphaSets;v2Apply(records,2,statuses);assert(statuses[0]==DW2_APPLIED&&alphas[0]==.5f&&alphaSets>beforeAlpha);
    // Failed native alpha readback can never be acknowledged as applied.
    failAlphaRead=YES;v2Apply(records,2,statuses);assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED);failAlphaRead=NO;
    assertRestored();
#if !DW_TEST_FROZEN_BASELINE
    // The arrival veil needs a desktop helper's identity and a queue that never runs its 1-second bound on its own.
    {static dispatch_queue_t held;held=dispatch_queue_create("dw.forward.veil",DISPATCH_QUEUE_SERIAL);dispatch_suspend(held);v2q=held;}
    v2VeilRegistered=YES;atomic_store(&v2VeilOn,true);atomic_store(&v2VeilClient,999);
    veilThenPlace("scalar",NO,NO);
#if DW_V2_ALPHA_DEDUP
    // On the skip path, identity loss during alpha readback never authorizes a
    // corrective setter and final identity still prevents APPLIED.
    resetState();v2Apply(records,2,statuses);alphas[0]=.75f;replaceOnAlphaRead=YES;beforeAlpha=alphaSets;
    v2Apply(records,2,statuses);assert(statuses[0]==DW2_IDENTITY&&alphaSets==beforeAlpha);owners[0]=7;
    assertRestored();
#endif
#if DW_V2_BATCH_COMPILED
    v2TransactionCreate=testTransactionCreate;v2TransactionCommit=testTransactionCommit;v2TransactionSetTransform=testTransactionStage;
    resetState();v2UseTransactionBatch=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&transactionCreates==1&&transactionStages==2&&transactionCommits==1&&!transformSets);
    assertRestored();
    veilThenPlace("transaction",YES,NO);
    // Neither staging nor commit status zero establishes a transform readback.
    resetState();v2UseTransactionBatch=YES;ignoreCommit=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED);assertRestored();
    resetState();v2UseTransactionBatch=YES;failCommit=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED);assertRestored();
    // A no-op stage is detected by readback. Changed identity aborts the batch;
    // these substitutes test the caller, not the native release/abort contract.
    resetState();v2UseTransactionBatch=YES;failStage=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED&&transactionCommits==1);assertRestored();
    resetState();v2UseTransactionBatch=YES;replaceOnStage=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_IDENTITY&&statuses[1]==DW2_NOT_APPLIED&&!transactionCommits&&!alphaSets);owners[0]=7;assertRestored();
    // Incomplete runtime ABI explicitly takes the scalar path.
    resetState();v2UseTransactionBatch=YES;v2TransactionCommit=NULL;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&!transactionCreates&&transformSets==2);assertRestored();
    v2SetWindowTransforms=testWindowList;
    resetState();v2UseWindowListBatch=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&listCalls==1&&!transformSets&&!transactionCreates);assertRestored();
    veilThenPlace("window list",NO,YES);
    resetState();v2UseWindowListBatch=YES;ignoreList=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED&&listCalls==1);assertRestored();
    resetState();v2UseWindowListBatch=YES;failList=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_NOT_APPLIED&&statuses[1]==DW2_NOT_APPLIED&&listCalls==1);assertRestored();
    resetState();v2UseWindowListBatch=YES;replaceAfterPersist=YES;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_IDENTITY&&statuses[1]==DW2_NOT_APPLIED&&!listCalls&&!alphaSets);owners[0]=7;assertRestored();
    resetState();v2UseWindowListBatch=YES;v2SetWindowTransforms=NULL;v2Apply(records,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&!listCalls&&transformSets==2);assertRestored();
    puts("PASS: alpha correction/identity/readback, transaction/list batching/no-op/identity/fallback and exact restoration; substituted native calls only");
#else
    puts("PASS: production scalar-only alpha correction, failed readback, identity fences and exact restoration; substituted native calls only");
#endif
#else
    puts("PASS: same repeated-frame/drift/readback/restoration scenario on frozen baseline; substituted native calls only");
#endif
    resetState();close(directoryFD);directoryFD=-1;assert(!rmdir(directory));
    return 0;
}}
