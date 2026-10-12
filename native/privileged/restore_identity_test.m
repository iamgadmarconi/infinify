// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
#import <AppKit/AppKit.h>
#import <libproc.h>
#include <unistd.h>
#include <assert.h>
static CFArrayRef queryWindows(CGWindowListOption option,CGWindowID wid);
static int queryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size);
static int journalSync(int fd);
static int queryKill(pid_t pid,int signal);
#define CGWindowListCopyWindowInfo queryWindows
#define proc_pidinfo queryProcess
#define fsync journalSync
#define kill queryKill
#import "payload.m"
#undef CGWindowListCopyWindowInfo
#undef proc_pidinfo
#undef fsync
#undef kill

static NSArray *rows;
static int ownerStatus,connectionStatus,ownerValue=7,processPID=123;
static BOOL processAvailable=YES;
static uint64_t seconds=100,microseconds=20;
static uid_t processUID;
static BOOL replaceOnSync,replaceAfterTransform,replaceAfterTransformRead,ignoreTransformWrites;
static int transformReadStatus;static unsigned transformReadFailures;
static unsigned transformWrites,alphaWrites,transformReads,identityReads;
static CGAffineTransform nativeTransform;
static CGRect nativeBounds={.size={300,200}};
static float nativeAlpha=1;
static BOOL failNextSync,failSyncAfterTransform,requirePendingBeforeTransform,replaceAfterBounds;
static int boundsStatus;
static uint32_t goneWID;
static BOOL oldWriterAlive;
static uint64_t oldWriterBirth=50;
static NSString *journalDirectory;
static int journalSync(int fd) {
    if(failNextSync){failNextSync=NO;errno=EIO;return -1;}
    int status=fsync(fd);
    if(!status&&replaceOnSync&&fd==directoryFD){replaceOnSync=NO;ownerValue++;}
    return status;
}
static CGError readTransform(int cid,uint32_t wid,CGAffineTransform *value) {
    (void)cid;(void)wid;transformReads++;*value=nativeTransform;
    if(replaceAfterTransformRead){replaceAfterTransformRead=NO;ownerValue++;}
    if(transformReadFailures){transformReadFailures--;return 1000;}
    return transformReadStatus;
}
static CGError writeTransform(int cid,uint32_t wid,CGAffineTransform value) {
    if(requirePendingBeforeTransform){
        NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
        assert(v2WriterSame(saved,v2WriterIdentity) && [saved[@"windows"]count]>0 && [saved[@"state"]isEqual:@"restoring"]);
    }
    (void)cid;(void)wid;transformWrites++;if(!ignoreTransformWrites)nativeTransform=value;
    if(failSyncAfterTransform){failSyncAfterTransform=NO;failNextSync=YES;}
    if(replaceAfterTransform){replaceAfterTransform=NO;ownerValue++;}
    return 0;
}
static CGError readBounds(int cid,uint32_t wid,CGRect *value) {
    (void)cid;(void)wid;*value=nativeBounds;if(replaceAfterBounds){replaceAfterBounds=NO;ownerValue++;}return boundsStatus;
}
static CGError readAlpha(int cid,uint32_t wid,float *value) {
    (void)cid;(void)wid;*value=nativeAlpha;return 0;
}
static CGError writeAlpha(int cid,uint32_t wid,float value) {
    (void)cid;(void)wid;alphaWrites++;nativeAlpha=value;return 0;
}
static CFArrayRef queryWindows(CGWindowListOption option,CGWindowID wid) {
    (void)option;if(wid==goneWID)return CFRetain((__bridge CFArrayRef)@[]);
    return rows ? CFRetain((__bridge CFArrayRef)rows) : NULL;
}
static int queryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size) {
    (void)flavor;(void)argument;
    if(pid==456){if(!oldWriterAlive)return 0;
        struct proc_bsdinfo process={.pbi_start_tvsec=oldWriterBirth,.pbi_start_tvusec=0,.pbi_uid=processUID};
        assert(size==sizeof(process));memcpy(buffer,&process,sizeof(process));return size;}
    if(!processAvailable)return 0;
    assert(size==sizeof(struct proc_bsdinfo));
    struct proc_bsdinfo process={.pbi_start_tvsec=seconds,.pbi_start_tvusec=microseconds,.pbi_uid=processUID};
    memcpy(buffer,&process,sizeof(process));return size;
}
static int queryKill(pid_t pid,int signal) { assert(pid==456 && signal==0);if(oldWriterAlive)return 0;errno=ESRCH;return -1; }
static int mainCID(void) { return 1; }
static CGError windowOwner(int cid,uint32_t wid,int *owner) {
    (void)cid;identityReads++;*owner=ownerValue;return wid==goneWID ? 1000 : ownerStatus;
}
static CGError ownerPID(int owner,pid_t *pid) {
    (void)owner;*pid=processPID;return connectionStatus;
}
static void expect(const struct dw2_identity *identity,int outcome) {
    assert(v2RestoreIdentity(identity,7)==outcome);
}
static NSDictionary *readJournal(void) {
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
}
static NSData *writeJSON(NSString *name,NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];assert(data);
    int fd=openat(directoryFD,name.UTF8String,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);assert(fd>=0);
    assert(writeAll(fd,data.bytes,data.length) && !close(fd));return data;
}
static NSDictionary *recoveryConfig(NSData *source,NSDictionary *writer) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(source.bytes,(CC_LONG)source.length,bytes);
    NSMutableString *hash=[NSMutableString string];for(unsigned i=0;i<sizeof(bytes);i++)[hash appendFormat:@"%02x",bytes[i]];
    NSMutableDictionary *config=[@{@"recovery_source_sha256":hash}mutableCopy];
    for(NSString *key in v2WriterKeys())config[[@"recovery_"stringByAppendingString:key]]=writer[key];
    return config;
}
static void clearTables(void) { v2Table=[NSMutableDictionary dictionary];v2Released=[NSMutableDictionary dictionary];v2JournalStale=NO;v2Count(); }
int main(void) { @autoreleasepool {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;
    fixtureOnly=NO;processUID=getuid();
    const struct dw2_identity recorded={.pid=123,.wid=42,.birth_sec=100,.birth_usec=20};
    expect(&recorded,DW2_INSTANCE_CURRENT);
    seconds=101;expect(&recorded,DW2_INSTANCE_GONE);seconds=100;
    processPID=124;expect(&recorded,DW2_INSTANCE_GONE);processPID=123;
    ownerValue=8;expect(&recorded,DW2_INSTANCE_GONE);ownerValue=7;
    processUID=getuid()+1;expect(&recorded,DW2_INSTANCE_UNCERTAIN);processUID=getuid();
    allowlist=@[@{@"pid":@124,@"birth_sec":@100,@"birth_usec":@20}];
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);allowlist=nil;

    ownerStatus=1;
    rows=nil;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[];expect(&recorded,DW2_INSTANCE_GONE);
    rows=@[@{}];expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@124}];
    expect(&recorded,DW2_INSTANCE_GONE);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    processAvailable=NO;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    processAvailable=YES;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    seconds=101;expect(&recorded,DW2_INSTANCE_GONE);seconds=100;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@YES}];
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@1.5}];
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);

    ownerStatus=0;connectionStatus=1;rows=nil;
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    processAvailable=NO;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    processAvailable=YES;expect(&recorded,DW2_INSTANCE_CURRENT);
    ownerValue=0;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    // Exercise the actual restore/table/journal path with unavailable queries.
    // Every native setter remains unset: this path must never call one.
    char directory[]="/tmp/infinify-restore-query.XXXXXX";
    assert(mkdtemp(directory));directoryFD=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    assert(directoryFD>=0);journalDirectory=@(directory);v2q=dispatch_queue_create("dw.restore.query.test",DISPATCH_QUEUE_SERIAL);
    v2RetryScheduled=YES; // This regression drives each retry explicitly on its sole test thread.
    clearTables();v2WriterIdentity=@{@"server_pid":@(getpid()),@"server_birth_sec":@1000,@"server_birth_usec":@0,@"server_uid":@(getuid()),@"boot_sec":@1,@"boot_usec":@0};
    DW2Entry *entry=[DW2Entry new];entry->who=recorded;entry->owner=7;
    entry->transform=CGAffineTransformMake(1,0,0,1,-25,-35);entry->bounds=CGRectMake(0,0,300,200);
    v2Table[@42]=entry;rows=nil;
    struct dw2_restore_reply summary={0};NSMutableData *report=[NSMutableData data];
    v2Restore(@"query regression",NO,report,&summary);
    assert(summary.count==1 && summary.pending==1 && summary.journal_persisted==1);
    assert(v2Table[@42]==entry && entry->state==DW2_RESTORING);
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[@(directory)stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
    assert([journal[@"state"]isEqual:@"restoring"] && [journal[@"windows"]count]==1);
    assert([journal[@"windows"][0][@"transform"]isEqual:matrix(entry->transform)]);
    NSDictionary *diagnostic=journal[@"last_restore"][@"results"][0][@"diagnostic"];
    assert([diagnostic[@"initial_identity"]isEqual:@"uncertain"] && diagnostic[@"transform_set_status"]==NSNull.null
        && diagnostic[@"transform_get_status"]==NSNull.null && diagnostic[@"final_identity"]==NSNull.null);
    assert(v2LastRestoreValid(journal[@"last_restore"]));
    rows=@[];report=[NSMutableData data];v2Restore(@"proven absence",YES,report,&summary);
    assert(summary.count==1 && summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);
    const struct dw2_restore_result *gone=report.bytes;assert(gone->outcome==DW2_GONE);

    // A replacement after durable enrollment must receive neither transform nor
    // alpha. These substitutes exercise v2Apply's actual journal/write ordering.
    ownerValue=7;connectionStatus=0;rows=nil;
    getTransform=readTransform;setTransform=writeTransform;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    nativeTransform=CGAffineTransformMake(1,0,0,1,-25,-35);
    struct dw2_record frame={.id=recorded,.flags=DW2_RECORD_HAS_ALPHA,.m={2,0,0,2,-50,-70},.alpha=.5f};uint8_t status=255;
    replaceOnSync=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==0 && alphaWrites==0 && v2Table.count==1);
    v2Restore(@"replacement after journal",NO,nil,&summary);
    assert(summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);

    // A window replaced during the transform cannot authorize a later alpha
    // write or a successful frame acknowledgement.
    ownerValue=7;replaceAfterTransform=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==1 && alphaWrites==0);
    v2Restore(@"replacement between setters",NO,nil,&summary);
    assert(summary.pending==0 && !v2Table.count);

    // Normal apply still changes and verifies both properties. Restoration has
    // the same boundary between its transform and alpha setters.
    ownerValue=7;v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==2 && alphaWrites==1 && nativeAlpha==.5f);
    replaceAfterTransform=YES;v2Restore(@"replacement during restore",NO,nil,&summary);
    assert(summary.pending==1 && transformWrites==3 && alphaWrites==1 && v2Table.count==1);
    diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert([diagnostic[@"alpha"][@"identity_current"]isEqual:@NO] && diagnostic[@"alpha"][@"set_status"]==NSNull.null
        && diagnostic[@"alpha"][@"get_status"]==NSNull.null && diagnostic[@"final_identity"]==NSNull.null);
    v2Restore(@"confirmed replacement",YES,nil,&summary);
    assert(summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);
    // A transform-only record still needs the final identity fence, even
    // though no intervening alpha write asks for one.
    ownerValue=7;frame.flags=0;replaceAfterTransform=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==4 && alphaWrites==1 && v2Table.count==1);
    v2Restore(@"transform-only replacement",NO,nil,&summary);
    assert(summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);

    // A successful setter is not successful restoration: record the failing
    // getter, mismatch or final identity without adding any native calls.
    ownerValue=7;transformReadStatus=1000;transformReads=identityReads=transformWrites=0;
    entry->state=DW2_HELD;v2Table[@42]=entry;
    v2Restore(@"readback unavailable",NO,nil,&summary);
    diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert(summary.pending==1 && transformWrites==1 && transformReads==1 && identityReads==1);
    assert([diagnostic[@"initial_identity"]isEqual:@"current"] && [diagnostic[@"transform_set_status"]isEqual:@0]
        && [diagnostic[@"transform_get_status"]isEqual:@1000] && diagnostic[@"actual_transform"]==NSNull.null
        && diagnostic[@"transform_matches"]==NSNull.null && diagnostic[@"final_identity"]==NSNull.null);
    assert(v2LastRestoreValid(v2LastRestore));
    // Diagnostic presence and shape cannot gate recovery; authoritative receipt
    // fields remain strict, and receipts without diagnostics remain valid.
    NSMutableDictionary *receipt=[v2LastRestore[@"results"][0]mutableCopy];
    receipt[@"diagnostic"]=@[@"non-authoritative metadata"];
    assert(v2LastRestoreValid(@{@"reason":@"metadata",@"results":@[receipt]}));
    [receipt removeObjectForKey:@"diagnostic"];
    assert(v2LastRestoreValid(@{@"reason":@"metadata absent",@"results":@[receipt]}));
    receipt[@"pid"]=@0;
    assert(!v2LastRestoreValid(@{@"reason":@"invalid identity",@"results":@[receipt]}));

    transformReadStatus=0;ignoreTransformWrites=YES;
    nativeTransform=CGAffineTransformMake(2,0,0,2,-50,-70);transformReads=identityReads=transformWrites=0;
    v2Restore(@"readback differs",YES,nil,&summary);
    diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert(summary.pending==1 && transformWrites==1 && transformReads==1 && identityReads==1);
    assert([diagnostic[@"actual_transform"]isEqual:matrix(nativeTransform)]
        && [diagnostic[@"saved_transform"]isEqual:matrix(entry->transform)]
        && [diagnostic[@"transform_matches"]isEqual:@NO] && diagnostic[@"final_identity"]==NSNull.null);

    ignoreTransformWrites=NO;replaceAfterTransform=YES;transformReads=identityReads=transformWrites=0;
    v2Restore(@"final identity changed",YES,nil,&summary);
    diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert(summary.pending==1 && transformWrites==1 && transformReads==1 && identityReads==2);
    assert([diagnostic[@"transform_matches"]isEqual:@YES] && [diagnostic[@"final_identity"]isEqual:@"gone"]);
    v2Restore(@"confirmed diagnostic replacement",YES,nil,&summary);
    assert(summary.pending==0 && !v2Table.count && transformWrites==1 && transformReads==1 && identityReads==3);

    // Complete frames may contain an unchanged neighbour. First admission must
    // still set it, even when the original getter already equals the request.
    // Only a previously verified apply can avoid a later repeated setter.
    ownerValue=7;frame.flags=0;nativeTransform=CGAffineTransformMake(2,0,0,2,-50,-70);
    transformWrites=transformReads=identityReads=0;v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==1 && transformReads==2);
    uint64_t generation=v2Generation;unsigned writes=transformWrites,reads=transformReads,identities=identityReads;
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==writes && transformReads==reads+1 && identityReads==identities+3 && v2Generation==generation);

    // A changed request retains one set/read pair; there is no speculative
    // pre-read on the ordinary pan/zoom path where every transform changes.
    frame.m[4]-=10;reads=transformReads;v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==writes+1 && transformReads==reads+1);

    // A cached request is not authority over actual geometry: external drift or
    // an unavailable verification read falls back to the guarded set/read pair.
    nativeTransform.tx-=5;writes=transformWrites;reads=transformReads;identities=identityReads;
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==writes+1 && transformReads==reads+2 && identityReads==identities+4);
    transformReadFailures=1;writes=transformWrites;reads=transformReads;v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==writes+1 && transformReads==reads+2);

    // A repeated transform does not suppress independently requested alpha.
    frame.flags=DW2_RECORD_HAS_ALPHA;frame.alpha=.75f;writes=transformWrites;unsigned alphas=alphaWrites;
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==writes && alphaWrites==alphas+1 && nativeAlpha==.75f);

    // Replacement during a successful repeated read cannot receive alpha or a
    // successful ACK. Replacement after a mismatched read cannot receive the
    // corrective transform either.
    replaceAfterTransformRead=YES;alphas=alphaWrites;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==writes && alphaWrites==alphas);
    v2Restore(@"repeated read replacement",NO,nil,&summary);assert(summary.pending==0 && !v2Table.count);
    ownerValue=7;frame.flags=0;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    nativeTransform.tx-=5;replaceAfterTransformRead=YES;writes=transformWrites;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==writes);
    v2Restore(@"corrective write replacement",NO,nil,&summary);assert(summary.pending==0 && !v2Table.count);

    // Successful restore retains the exact original beyond connection lifetime,
    // paired with bounds observed after restoration (a native resize is allowed).
    ownerValue=7;nativeTransform=CGAffineTransformMake(1,0,0,1,-25,-35);nativeAlpha=.8f;
    frame.flags=DW2_RECORD_HAS_ALPHA;frame.alpha=.5f;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    nativeBounds=CGRectMake(0,0,350,250);v2Restore(@"released original",NO,nil,&summary);
    assert(!summary.pending && summary.journal_persisted && !v2Table.count && v2Released.count==1);
    assert(CGRectEqualToRect(v2Released[@42]->bounds,nativeBounds) && v2Released[@42]->alphaTouched && nativeAlpha==.8f);
    journal=readJournal();assert([journal[@"v"]isEqual:@3] && [journal[@"state"]isEqual:@"empty"] && [journal[@"released_windows"]count]==1);
    assert(v2WriterSame(journal,v2WriterIdentity) && !atomic_load(&v2Held) && !atomic_load(&v2Restoring));
    writes=transformWrites;clearTables();assert(v2LoadJournal(nil));
    assert(transformWrites==writes && !v2Table.count && v2Released.count==1); // Same writer never replays released rows.

    // Re-admission snapshots current outside-canvas state; failure to commit that
    // replacement retains the old released original and writes no native state.
    DW2Entry *releasedEntry=v2Released[@42];nativeTransform.tx=-40;nativeTransform.ty=-60;nativeAlpha=.7f;
    failNextSync=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_JOURNAL && !v2Table.count && v2Released[@42]==releasedEntry && transformWrites==writes);
    v2Restore(@"journal retry",YES,nil,&summary);assert(summary.journal_persisted && !v2JournalStale);
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && !v2Released.count && v2Table[@42]->transform.tx==-40);
    v2Restore(@"new original",NO,nil,&summary);assert(!summary.pending && v2Released[@42]->alpha==.7f);
    journal=readJournal();

    // Strict schema and unique collections are authoritative; schema 2 cannot
    // silently lose the released-obligation collection during a migration.
    NSMutableDictionary *bad=[journal mutableCopy];bad[@"v"]=@2;
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:bad options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));
    bad=[journal mutableCopy];bad[@"windows"]=@[[[journal[@"released_windows"][0]mutableCopy]copy]];
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:bad options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));

    // A loader-authorized handoff binds immutable source bytes to the exact old
    // writer/boot/user. Current writer, live old writer, malformed bytes, wrong
    // provenance and failed durability all refuse before the first native write.
    NSMutableDictionary *old=[journal mutableCopy];old[@"server_pid"]=@456;old[@"server_birth_sec"]=@50;old[@"server_birth_usec"]=@0;
    NSData *source=writeJSON(@"recovery-source.json",old);NSDictionary *config=recoveryConfig(source,old);
    assert(v2RecoveryConfigValid(config));assert(!unlinkat(directoryFD,"v2-journal.json",0));clearTables();
    oldWriterAlive=YES;assert(!v2LoadJournal(config) && transformWrites==writes+2);oldWriterAlive=NO;
    NSMutableDictionary *wrong=[config mutableCopy];wrong[@"recovery_source_sha256"]=[@"0"stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
    assert(!v2LoadJournal(wrong));wrong=[config mutableCopy];wrong[@"recovery_boot_sec"]=@2;assert(!v2LoadJournal(wrong));
    NSMutableDictionary *otherBoot=[v2WriterIdentity mutableCopy];otherBoot[@"boot_sec"]=@2;
    NSDictionary *currentWriter=v2WriterIdentity;v2WriterIdentity=otherBoot;assert(!v2LoadJournal(config));v2WriterIdentity=currentWriter;
    failNextSync=YES;writes=transformWrites;assert(!v2LoadJournal(config) && transformWrites==writes);clearTables();

    // An off-canvas geometry change or non-reset transform must remain unresolved.
    // The new journal is already durable even when no reattachment is authorized.
    nativeTransform=CGAffineTransformIdentity;nativeBounds.size.width=351;
    assert(v2LoadJournal(config));assert(v2Table[@42]->reattaching && atomic_load(&v2Restoring)==1 && transformWrites==writes);
    assert([readJournal()[@"windows"][0][@"state"]isEqual:@"reattaching"] && v2WriterSame(readJournal(),currentWriter));
    nativeBounds.size.width=350;nativeTransform=CGAffineTransformMake(1,0,0,1,-99,-88);
    v2Restore(@"divergent matrix",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);
    nativeTransform=CGAffineTransformIdentity;nativeAlpha=.9f;
    v2Restore(@"divergent released alpha",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);
    nativeAlpha=.7f;boundsStatus=1000;
    v2Restore(@"unknown bounds",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);boundsStatus=0;
    transformReadStatus=1000;v2Restore(@"unknown matrix",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);transformReadStatus=0;
    replaceAfterBounds=YES;v2Restore(@"replacement during guard",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);ownerValue=7;

    // Reattachment is persisted before its first setter; a failed final fsync
    // cannot advertise readiness even after successful transform/alpha readback.
    requirePendingBeforeTransform=YES;failSyncAfterTransform=YES;
    v2Restore(@"reattach identity reset",YES,nil,&summary);
    assert(!summary.pending && !summary.journal_persisted && v2JournalStale && !v2Table.count && v2Released.count==1);
    assert(transformWrites==writes+1 && nativeTransform.tx==-40 && nativeTransform.ty==-60 && nativeAlpha==.7f);
    v2Restore(@"finish durable release",YES,nil,&summary);assert(summary.journal_persisted && !v2JournalStale);
    assert([[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"recovery-source.json"]]isEqual:source]);

    // A second crash must use the newer committed original, not historical
    // recovery-source bytes. Here the latest release differs deliberately.
    requirePendingBeforeTransform=NO;nativeTransform.tx=-55;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    v2Restore(@"latest committed original",NO,nil,&summary);assert(!summary.pending && v2Released[@42]->transform.tx==-55);
    NSMutableDictionary *nextWriter=[currentWriter mutableCopy];nextWriter[@"server_pid"]=@789;nextWriter[@"server_birth_sec"]=@2000;
    v2WriterIdentity=nextWriter;nativeTransform=CGAffineTransformIdentity;clearTables();requirePendingBeforeTransform=YES;writes=transformWrites;
    assert(v2LoadJournal(config) && transformWrites==writes+1 && nativeTransform.tx==-55 && !v2Table.count && v2Released.count==1);
    requirePendingBeforeTransform=NO;journal=readJournal();bad=[journal mutableCopy];bad[@"v"]=@2;writeJSON(@"v2-journal.json",bad);clearTables();writes=transformWrites;
    assert(!v2LoadJournal(config) && transformWrites==writes); // Never fall back when committed state is invalid.
    writeJSON(@"v2-journal.json",journal);assert(v2LoadJournal(config) && transformWrites==writes); // Same writer stays dormant.
    assert(!unlinkat(directoryFD,"recovery-source.json",0));

    // The original same-runtime crash recovery also accepts only a retired
    // schema-3 writer of this boot/user, preserving released-row guards.
    old=[readJournal()mutableCopy];old[@"server_pid"]=@456;old[@"server_birth_sec"]=@50;old[@"server_birth_usec"]=@0;
    writeJSON(@"v2-journal.json",old);clearTables();nativeTransform=CGAffineTransformIdentity;requirePendingBeforeTransform=YES;
    assert(v2LoadJournal(nil) && nativeTransform.tx==-55 && !v2Table.count && v2Released.count==1);requirePendingBeforeTransform=NO;

    // Retention is bounded jointly with active entries. Unknown/live originals
    // cannot be evicted; affirmative disappearance permits one new admission.
    clearTables();DW2Entry *template=v2DecodeEntry(readJournal()[@"released_windows"][0],YES);assert(template);
    for(uint32_t wid=1;wid<=DW2_MAX_TABLE;wid++){
        DW2Entry *retained=[DW2Entry new];retained->who=recorded;retained->who.wid=wid;retained->owner=7;retained->transform=template->transform;retained->bounds=nativeBounds;
        v2Released[@(wid)]=retained;
    }
    frame.id.wid=5000;frame.flags=0;writes=transformWrites;v2Apply(&frame,1,&status);
    assert(status==DW2_TABLE_FULL && transformWrites==writes && v2Released.count==DW2_MAX_TABLE && !v2Table.count);
    goneWID=1;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && !v2Released[@1] && v2Released.count+v2Table.count==DW2_MAX_TABLE);
    goneWID=0;clearTables();
    // Malformed private paths are refused without waiting for a FIFO writer.
    assert(!mkfifoat(directoryFD,"recovery-source.json",0600));BOOL absent=YES;
    assert(!v2ReadJournal("recovery-source.json",&absent) && !absent);assert(!unlinkat(directoryFD,"recovery-source.json",0));
    assert(!unlinkat(directoryFD,"v2-journal.json",0));close(directoryFD);directoryFD=-1;assert(!rmdir(directory));
    puts("PASS: identity, repeated-frame, strict schema3 retained originals, guarded durable handoff/retry/crash-chain and bounded admission; no native window mutation");
} }
