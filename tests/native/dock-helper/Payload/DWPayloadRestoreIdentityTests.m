// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <sys/sysctl.h>
#include <unistd.h>
#include <assert.h>
static CFArrayRef queryWindows(CGWindowListOption option,CGWindowID wid);
static int queryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size);
static int journalSync(int fd);
static int queryKill(pid_t pid,int signal);
static int querySysctl(const char *name,void *value,size_t *length,void *replacement,size_t replacementLength);
static CGError queryDisplays(uint32_t maximum,CGDirectDisplayID *displays,uint32_t *count);
static boolean_t displayOnline(CGDirectDisplayID display),displayAsleep(CGDirectDisplayID display);
static CGDirectDisplayID displayMirror(CGDirectDisplayID display);
#define CGWindowListCopyWindowInfo queryWindows
#define proc_pidinfo queryProcess
#define fsync journalSync
#define kill queryKill
#define sysctlbyname querySysctl
#define CGGetActiveDisplayList queryDisplays
#define CGDisplayIsOnline displayOnline
#define CGDisplayIsAsleep displayAsleep
#define CGDisplayMirrorsDisplay displayMirror
#import "DWPayload.m"
#undef CGWindowListCopyWindowInfo
#undef proc_pidinfo
#undef fsync
#undef kill
#undef sysctlbyname
#undef CGGetActiveDisplayList
#undef CGDisplayIsOnline
#undef CGDisplayIsAsleep
#undef CGDisplayMirrorsDisplay

// The substitutes and the cases, textually and in this order: each may use what an earlier one defines; main below runs them.
#import "DWPayloadTestSubstitutes.h"
#import "DWPayloadSpaceTests.m"
#import "DWPayloadSublevelTests.m"
#import "DWPayloadVeilTests.m"
#import "DWPayloadArrivalTests.m"
#import "DWPayloadPlacementTests.m"
#import "DWPayloadLayerTests.m"
#import "DWPayloadMoveTests.m"
int main(void) { @autoreleasepool {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;
    fixtureOnly=NO;processUID=getuid();
    // The kernel boot-session string is a fixed canonical UUID, never a mutable
    // wall-clock timestamp. Malformed/truncated system replies refuse startup.
    NSDictionary *observedWriter=v2CurrentWriterIdentity();
    assert(v2WriterValid(observedWriter) && [observedWriter[@"boot_uuid"]isEqual:@(bootUUID)]);
    bootUUIDLength=36;assert(!v2CurrentWriterIdentity());bootUUIDLength=37;
    bootUUID[36]='!';assert(!v2CurrentWriterIdentity());bootUUID[36]='\0';
    bootUUID[9]='c';assert(!v2CurrentWriterIdentity());bootUUID[9]='C';
    bootUUIDStatus=-1;assert(!v2CurrentWriterIdentity());bootUUIDStatus=0;
    assert(!dw_boot_uuid_valid(nil) && !dw_boot_uuid_valid(@1) && !dw_boot_uuid_valid(@"48359692C6EC-4E77-8BD8-B68CF839CB16")
        && !dw_boot_uuid_valid(@"48359692-C6EC-4E77-8BD8-B68CF839CB1G"));
    const struct dw2_identity recorded={.pid=123,.wid=42,.birth_sec=100,.birth_usec=20};
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    expect(&recorded,DW2_INSTANCE_CURRENT);
    // A real closed popup left a successful cached owner lookup while its
    // transform getter failed. Complete CG absence must override that cache.
    rows=@[];expect(&recorded,DW2_INSTANCE_GONE);
    rows=nil;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@124}];expect(&recorded,DW2_INSTANCE_GONE);
    // Presence means hidden windows remain obligations. A valid matching row
    // does not excuse malformed later metadata or duplicate window numbers.
    NSDictionary *hidden=@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123,(id)kCGWindowIsOnscreen:@NO};
    rows=@[hidden];expect(&recorded,DW2_INSTANCE_CURRENT);
    rows=@[hidden,@{}];expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[hidden,hidden];expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[hidden,@{(id)kCGWindowNumber:@43,(id)kCGWindowOwnerPID:@YES}];expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
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
    clearTables();v2WriterIdentity=@{@"server_pid":@(getpid()),@"server_birth_sec":@1000,@"server_birth_usec":@0,@"server_uid":@(getuid()),@"boot_uuid":@(bootUUID)};
    DW2Entry *entry=[DW2Entry new];entry->who=recorded;entry->owner=7;
    entry->layer=CGAffineTransformMake(1,0,0,1,-25,-35);entry->bounds=CGRectMake(25,35,300,200);
    v2Table[@42]=entry;rows=nil;
    struct dw2_restore_reply summary={0};NSMutableData *report=[NSMutableData data];
    v2Restore(@"query regression",NO,report,&summary);
    assert(summary.count==1 && summary.pending==1 && summary.journal_persisted==1);
    assert(v2Table[@42]==entry && entry->state==DW2_RESTORING);
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[@(directory)stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
    assert([journal[@"state"]isEqual:@"restoring"] && [journal[@"windows"]count]==1);
    assert([journal[@"windows"][0][@"layer"]isEqual:matrix(entry->layer)]);
    NSDictionary *diagnostic=journal[@"last_restore"][@"results"][0][@"diagnostic"];
    assert([diagnostic[@"initial_identity"]isEqual:@"uncertain"] && diagnostic[@"layer_set_status"]==NSNull.null
        && diagnostic[@"layer_get_status"]==NSNull.null && diagnostic[@"final_identity"]==NSNull.null);
    assert(v2LastRestoreValid(journal[@"last_restore"]));
    rows=@[];report=[NSMutableData data];v2Restore(@"proven absence",YES,report,&summary);
    assert(summary.count==1 && summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);
    const struct dw2_restore_result *gone=report.bytes;assert(gone->outcome==DW2_GONE);

    // A replacement after durable enrollment must receive neither transform nor
    // alpha. These substitutes exercise v2Apply's actual journal/write ordering.
    ownerValue=7;connectionStatus=0;rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    getTransform=readTransform;setTransform=writeTransform;getLayer=readTransform;setLayer=writeTransform;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
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
    assert([diagnostic[@"initial_identity"]isEqual:@"current"] && [diagnostic[@"layer_set_status"]isEqual:@0]
        && [diagnostic[@"layer_get_status"]isEqual:@1000] && diagnostic[@"actual_layer"]==NSNull.null
        && diagnostic[@"layer_matches"]==NSNull.null && diagnostic[@"final_identity"]==NSNull.null);
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
    assert([diagnostic[@"actual_layer"]isEqual:matrix(nativeTransform)]
        && [diagnostic[@"saved_layer"]isEqual:matrix(entry->layer)]
        && [diagnostic[@"layer_matches"]isEqual:@NO] && diagnostic[@"final_identity"]==NSNull.null);

    ignoreTransformWrites=NO;replaceAfterTransform=YES;transformReads=identityReads=transformWrites=0;
    v2Restore(@"final identity changed",YES,nil,&summary);
    diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert(summary.pending==1 && transformWrites==1 && transformReads==1 && identityReads==2);
    assert([diagnostic[@"layer_matches"]isEqual:@YES] && [diagnostic[@"final_identity"]isEqual:@"gone"]);
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
    nativeBounds=CGRectMake(25,35,350,250);v2Restore(@"released original",NO,nil,&summary);
    assert(!summary.pending && summary.journal_persisted && !v2Table.count && v2Released.count==1);
    assert(CGRectEqualToRect(v2Released[@42]->bounds,nativeBounds) && v2Released[@42]->alphaTouched && nativeAlpha==.8f);
    journal=readJournal();assert([journal[@"v"]isEqual:@4] && [journal[@"state"]isEqual:@"empty"] && [journal[@"released_windows"]count]==1);
    assert(v2WriterSame(journal,v2WriterIdentity) && !atomic_load(&v2Held) && !atomic_load(&v2Restoring));
    writes=transformWrites;clearTables();assert(v2LoadJournal(nil));
    assert(transformWrites==writes && !v2Table.count && v2Released.count==1); // Same writer never replays released rows.

    // Re-admission snapshots current outside-canvas state; failure to commit that
    // replacement retains the old released original and writes no native state.
    DW2Entry *releasedEntry=v2Released[@42];nativeTransform.tx=-40;nativeTransform.ty=-60;nativeBounds.origin=CGPointMake(40,60);nativeAlpha=.7f;
    failNextSync=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_JOURNAL && !v2Table.count && v2Released[@42]==releasedEntry && transformWrites==writes);
    v2Restore(@"journal retry",YES,nil,&summary);assert(summary.journal_persisted && !v2JournalStale);
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && !v2Released.count && v2Table[@42]->layer.tx==-40);
    v2Restore(@"new original",NO,nil,&summary);assert(!summary.pending && v2Released[@42]->alpha==.7f);
    journal=readJournal();

    // Strict schema and unique collections are authoritative: only schema 4 is
    // accepted, so a journal that lacks the released-obligation collection is refused.
    NSMutableDictionary *bad=[journal mutableCopy];bad[@"v"]=@2;
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:bad options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));
    bad=[journal mutableCopy];[bad removeObjectForKey:@"boot_uuid"];bad[@"boot_sec"]=@1;bad[@"boot_usec"]=@0;
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:bad options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));
    bad=[journal mutableCopy];bad[@"boot_uuid"]=[bad[@"boot_uuid"]lowercaseString];
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
    assert(!v2LoadJournal(wrong));wrong=[config mutableCopy];wrong[@"recovery_boot_uuid"]=@"58359692-C6EC-4E77-8BD8-B68CF839CB16";assert(!v2LoadJournal(wrong));
    wrong=[config mutableCopy];wrong[@"recovery_boot_sec"]=@1;assert(!v2RecoveryConfigValid(wrong));
    NSMutableDictionary *otherBoot=[v2WriterIdentity mutableCopy];otherBoot[@"boot_uuid"]=@"58359692-C6EC-4E77-8BD8-B68CF839CB16";
    NSDictionary *currentWriter=v2WriterIdentity;v2WriterIdentity=otherBoot;assert(!v2LoadJournal(config));v2WriterIdentity=currentWriter;
    failNextSync=YES;writes=transformWrites;assert(!v2LoadJournal(config) && transformWrites==writes);clearTables();

    // A layer that is neither the original nor the identity must remain unresolved, and a resized window is no obstacle to
    // converging once the layer is fine (the layer does not depend on the frame).
    // The new journal is already durable even when no reattachment is authorized.
    nativeTransform=CGAffineTransformMake(1,0,0,1,-99,-88);
    assert(v2LoadJournal(config));assert(v2Table[@42]->reattaching && atomic_load(&v2Restoring)==1 && transformWrites==writes);
    assert([readJournal()[@"windows"][0][@"state"]isEqual:@"reattaching"] && v2WriterSame(readJournal(),currentWriter));
    nativeBounds.size.width=351;
    v2Restore(@"divergent matrix",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);
    nativeTransform=CGAffineTransformIdentity;nativeAlpha=.9f;
    v2Restore(@"divergent released alpha",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);
    nativeAlpha=.7f;boundsStatus=1000;
    // The frame is not part of the guard any more, so the layer (the original, idempotent) is written; unreadable bounds still leave the
    // release uncertified and pending.
    v2Restore(@"unknown bounds",YES,nil,&summary);assert(summary.pending==1);boundsStatus=0;nativeTransform=CGAffineTransformIdentity;writes=transformWrites;
    transformReadStatus=1000;v2Restore(@"unknown matrix",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);transformReadStatus=0;
    replaceAfterTransformRead=YES;v2Restore(@"replacement during guard",YES,nil,&summary);assert(summary.pending==1 && transformWrites==writes);ownerValue=7;

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
    requirePendingBeforeTransform=NO;nativeTransform.tx=-55;nativeBounds.origin.x=55;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    v2Restore(@"latest committed original",NO,nil,&summary);assert(!summary.pending && v2Released[@42]->layer.tx==-55);
    NSMutableDictionary *nextWriter=[currentWriter mutableCopy];nextWriter[@"server_pid"]=@789;nextWriter[@"server_birth_sec"]=@2000;
    v2WriterIdentity=nextWriter;nativeTransform=CGAffineTransformIdentity;clearTables();requirePendingBeforeTransform=YES;writes=transformWrites;
    assert(v2LoadJournal(config) && transformWrites==writes+1 && nativeTransform.tx==-55 && !v2Table.count && v2Released.count==1);
    requirePendingBeforeTransform=NO;journal=readJournal();bad=[journal mutableCopy];bad[@"v"]=@2;writeJSON(@"v2-journal.json",bad);clearTables();writes=transformWrites;
    assert(!v2LoadJournal(config) && transformWrites==writes); // Never fall back when committed state is invalid.
    writeJSON(@"v2-journal.json",journal);assert(v2LoadJournal(config) && transformWrites==writes); // Same writer stays dormant.
    assert(!unlinkat(directoryFD,"recovery-source.json",0));

    // The original same-runtime crash recovery also accepts only a retired
    // schema-4 writer of this boot/user, preserving released-row guards.
    old=[readJournal()mutableCopy];old[@"server_pid"]=@456;old[@"server_birth_sec"]=@50;old[@"server_birth_usec"]=@0;
    writeJSON(@"v2-journal.json",old);clearTables();nativeTransform=CGAffineTransformIdentity;requirePendingBeforeTransform=YES;
    assert(v2LoadJournal(nil) && nativeTransform.tx==-55 && !v2Table.count && v2Released.count==1);requirePendingBeforeTransform=NO;

    // Retention is bounded jointly with active entries. Unknown/live originals
    // cannot be evicted; affirmative disappearance permits one new admission.
    clearTables();DW2Entry *template=v2DecodeEntry(readJournal()[@"released_windows"][0],YES);assert(template);
    for(uint32_t wid=1;wid<=DW2_MAX_TABLE;wid++){
        DW2Entry *retained=[DW2Entry new];retained->who=recorded;retained->who.wid=wid;retained->owner=7;retained->layer=template->layer;retained->bounds=nativeBounds;
        v2Released[@(wid)]=retained;
    }
    NSMutableArray *retainedRows=[NSMutableArray array];for(uint32_t wid=1;wid<=DW2_MAX_TABLE;wid++)
        [retainedRows addObject:@{(id)kCGWindowNumber:@(wid),(id)kCGWindowOwnerPID:@123}];
    rows=retainedRows;
    frame.id.wid=5000;frame.flags=0;writes=transformWrites;v2Apply(&frame,1,&status);
    assert(status==DW2_TABLE_FULL && transformWrites==writes && v2Released.count==DW2_MAX_TABLE && !v2Table.count);
    goneWID=1;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && !v2Released[@1] && v2Released.count+v2Table.count==DW2_MAX_TABLE);
    goneWID=0;clearTables();
    // The actual popup failure: the private owner cache succeeds, transform
    // readback would fail, but a complete all-window list proves both absent.
    // One shared list handles the pass; no setter is issued for either ghost.
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];ownerValue=7;transformReadStatus=1000;
    for(uint32_t wid=642;wid<=643;wid++){
        DW2Entry *popup=[DW2Entry new];popup->who=recorded;popup->who.wid=wid;popup->owner=7;
        popup->layer=CGAffineTransformMake(1,0,0,1,-430,-367);popup->bounds=CGRectMake(430,367,75,46);v2Table[@(wid)]=popup;
    }
    writes=transformWrites;restoreListReads=0;v2Restore(@"closed popup owner cache",NO,nil,&summary);
    assert(summary.count==2 && !summary.pending && summary.journal_persisted && !v2Table.count && !v2Released.count
        && transformWrites==writes && restoreListReads==1);
    assert([v2LastRestore[@"results"][0][@"outcome"]isEqual:@"gone"] && [v2LastRestore[@"results"][1][@"outcome"]isEqual:@"gone"]);
    entry->who=recorded;entry->owner=7;entry->state=DW2_HELD;v2Table[@42]=entry;
    rows=nil;v2Restore(@"owner cache with unavailable complete list",NO,nil,&summary);
    assert(summary.pending==1 && v2Table[@42]==entry && transformWrites==writes && summary.journal_persisted);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123},@{}];
    v2Restore(@"owner cache with malformed complete list",YES,nil,&summary);
    assert(summary.pending==1 && v2Table[@42]==entry && transformWrites==writes && summary.journal_persisted);
    clearTables();transformReadStatus=0;
    spaceCases(recorded);
    sublevelCases(recorded);
    veilCases(recorded);
    placementCases(recorded);
    layerCases(recorded);
    moveCases(recorded);
    arrivalCases(recorded);
    // Malformed private paths are refused without waiting for a FIFO writer.
    assert(!mkfifoat(directoryFD,"recovery-source.json",0600));BOOL absent=YES;
    assert(!v2ReadJournal("recovery-source.json",&absent) && !absent);assert(!unlinkat(directoryFD,"recovery-source.json",0));
    assert(!unlinkat(directoryFD,"v2-journal.json",0));close(directoryFD);directoryFD=-1;assert(!rmdir(directory));
    puts("PASS: identity, repeated-frame, strict schema4 retained originals, guarded durable handoff/retry/crash-chain and bounded admission; no native window mutation");
} }
