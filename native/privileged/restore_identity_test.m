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
#import "payload.m"
#undef CGWindowListCopyWindowInfo
#undef proc_pidinfo
#undef fsync
#undef kill
#undef sysctlbyname
#undef CGGetActiveDisplayList
#undef CGDisplayIsOnline
#undef CGDisplayIsAsleep
#undef CGDisplayMirrorsDisplay

static NSArray *rows;
static unsigned restoreListReads;
static int ownerStatus,connectionStatus,ownerValue=7,processPID=123;
static BOOL processAvailable=YES;
static uint64_t seconds=100,microseconds=20;
static uid_t processUID;
static BOOL replaceOnSync,replaceAfterTransform,replaceAfterTransformRead,ignoreTransformWrites;
static int transformReadStatus;static unsigned transformReadFailures;
static unsigned transformWrites,alphaWrites,transformReads,identityReads;
static CGAffineTransform nativeTransform;
// The native frame of the fixture window. Its default origin (25,35) is the one a plain original [1,0,0,1,-25,-35] belongs to:
// a window server transform carries the window's position, so an original that is consistent with its frame says -origin.
static CGRect nativeBounds={{25,35},{300,200}};
static float nativeAlpha=1;
static BOOL failNextSync,failSyncAfterTransform,requirePendingBeforeTransform,replaceAfterBounds;
static BOOL moveAfterTransformWrite;
static int boundsStatus;
static uint32_t goneWID;
static BOOL oldWriterAlive;
static uint64_t oldWriterBirth=50;
static char bootUUID[37]="48359692-C6EC-4E77-8BD8-B68CF839CB16";
static size_t bootUUIDLength=sizeof(bootUUID);
static int bootUUIDStatus;
static NSString *journalDirectory;
static NSMutableDictionary<NSNumber *,NSArray *> *spaceMembership;
static NSString *const primaryUUID=@"00000000-0000-0000-0000-000000000001",*const rightUUID=@"00000000-0000-0000-0000-000000000002";
static uint64_t primaryCurrent=1,rightCurrent=2;
static uint32_t activeDisplayCount=2;
static unsigned spaceWrites,failSyncCountdown;
// Ordered native writes ("T", "A:<alpha>") while a case wants them, and whether an alpha write must find its owner's record on disk first.
static NSMutableArray<NSString *> *nativeLog;
static BOOL requireJournalBeforeAlpha,ignoreAlphaWrites,requireVeilPlacedBeforeTransform,requireNoVeilAlphaBeforeAlpha;
static float journalAlpha=1; // the original alpha an owner's record must carry
static BOOL ignoreSpaceWrites,replaceAfterSpace,changeTargetOnSync,failSyncAfterSpace,carryChildOnSpace;
static id managedSpaces;
static BOOL replaceAfterSpaceInventory,changeMembershipAfterSpaceInventory;
static CFArrayRef managedSpaceInventory(int cid) {
    assert(cid==1);
    if(replaceAfterSpaceInventory){replaceAfterSpaceInventory=NO;ownerValue++;}
    if(changeMembershipAfterSpaceInventory){changeMembershipAfterSpaceInventory=NO;spaceMembership[@42]=@[@3];}
    return managedSpaces ? CFRetain((__bridge CFArrayRef)managedSpaces) : NULL;
}
static int journalSync(int fd) {
    if(failSyncCountdown&&!--failSyncCountdown){errno=EIO;return -1;}
    if(failNextSync){failNextSync=NO;errno=EIO;return -1;}
    int status=fsync(fd);
    if(!status&&replaceOnSync&&fd==directoryFD){replaceOnSync=NO;ownerValue++;}
    if(!status&&changeTargetOnSync&&fd==directoryFD){changeTargetOnSync=NO;rightCurrent=4;}
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
    if(requireVeilPlacedBeforeTransform){
        // The first frame for a veiled window: its record already says a transform is owed, and holds the transform and bounds as they are now.
        NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
        NSDictionary *row=nil;for(NSDictionary *candidate in saved[@"windows"])if([candidate[@"wid"]unsignedIntValue]==wid)row=candidate;
        NSArray *nowBounds=@[@(nativeBounds.origin.x),@(nativeBounds.origin.y),@(nativeBounds.size.width),@(nativeBounds.size.height)];
        assert(row && !row[@"veil_bare"] && [row[@"transform"]isEqual:matrix(nativeTransform)] && [row[@"bounds"]isEqual:nowBounds]);
    }
    (void)cid;(void)wid;transformWrites++;[nativeLog addObject:@"T"];if(!ignoreTransformWrites)nativeTransform=value;
    if(moveAfterTransformWrite){moveAfterTransformWrite=NO;nativeBounds.origin.x+=7;} // the window moves between the write and the read of its origin
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
    if(requireJournalBeforeAlpha){
        NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
        NSDictionary *row=nil;for(NSDictionary *candidate in saved[@"windows"])if([candidate[@"wid"]unsignedIntValue]==wid)row=candidate;
        assert(row && [row[@"alpha_touched"]boolValue] && [row[@"alpha"]floatValue]==journalAlpha && v2WriterSame(saved,v2WriterIdentity));
    }
    if(requireNoVeilAlphaBeforeAlpha){
        NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
        NSDictionary *row=nil;for(NSDictionary *candidate in saved[@"windows"])if([candidate[@"wid"]unsignedIntValue]==wid)row=candidate;
        assert(row && !row[@"veil_alpha"]);
    }
    (void)cid;alphaWrites++;[nativeLog addObject:[NSString stringWithFormat:@"A:%.2f",value]];if(!ignoreAlphaWrites)nativeAlpha=value;return 0;
}
static CFArrayRef queryWindows(CGWindowListOption option,CGWindowID wid) {
    if(option==kCGWindowListOptionAll){
        assert(wid==kCGNullWindowID);restoreListReads++;
        if(!rows)return NULL;
        NSMutableArray *all=[rows mutableCopy];
        if(goneWID)[all filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id row,NSDictionary *bindings){
            (void)bindings;return ![row isKindOfClass:NSDictionary.class] || [row[(id)kCGWindowNumber]unsignedIntValue]!=goneWID;
        }]];
        return CFRetain((__bridge CFArrayRef)all);
    }
    if(wid==goneWID)return CFRetain((__bridge CFArrayRef)@[]);
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
static int querySysctl(const char *name,void *value,size_t *length,void *replacement,size_t replacementLength) {
    assert(!strcmp(name,"kern.bootsessionuuid") && value && *length==sizeof(bootUUID) && !replacement && !replacementLength);
    if(bootUUIDStatus)return bootUUIDStatus;
    memcpy(value,bootUUID,sizeof(bootUUID));*length=bootUUIDLength;return 0;
}
static int mainCID(void) { return 1; }
static CGError windowOwner(int cid,uint32_t wid,int *owner) {
    (void)cid;identityReads++;*owner=ownerValue;return wid==goneWID ? 1000 : ownerStatus;
}
static CGError ownerPID(int owner,pid_t *pid) {
    (void)owner;*pid=processPID;return connectionStatus;
}
static CGError queryDisplays(uint32_t maximum,CGDirectDisplayID *displays,uint32_t *count) {
    assert(maximum>=2);displays[0]=1;displays[1]=2;*count=activeDisplayCount;return 0;
}
static boolean_t displayOnline(CGDirectDisplayID display) {return display==1||display==2;}
static boolean_t displayAsleep(CGDirectDisplayID display) {(void)display;return false;}
static CGDirectDisplayID displayMirror(CGDirectDisplayID display) {(void)display;return 0;}
static CFUUIDRef displayID(CGDirectDisplayID display) {return CFUUIDCreateFromString(NULL,(__bridge CFStringRef)(display==1?primaryUUID:rightUUID));}
static CFArrayRef windowSpaces(int cid,int selector,CFArrayRef windows) {
    assert(cid==1&&selector==7&&CFArrayGetCount(windows)==1);
    NSArray *value=spaceMembership[(__bridge id)CFArrayGetValueAtIndex(windows,0)];return value?CFRetain((__bridge CFArrayRef)value):NULL;
}
static CFStringRef spaceDisplay(int cid,uint64_t space) {(void)cid;return space==1||space==3?CFRetain((__bridge CFStringRef)primaryUUID):space==2||space==4?CFRetain((__bridge CFStringRef)rightUUID):NULL;}
static uint64_t currentSpace(int cid,CFStringRef display) {(void)cid;return [(__bridge NSString *)display isEqual:primaryUUID]?primaryCurrent:rightCurrent;}
static int spaceKind(int cid,uint64_t space) {(void)cid;return space>=1&&space<=4?0:4;}
static void writeSpace(int cid,CFArrayRef windows,uint64_t space) {
    assert(cid==1&&CFArrayGetCount(windows)==1);NSNumber *wid=(__bridge id)CFArrayGetValueAtIndex(windows,0);
    NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
    NSDictionary *row=nil;for(NSDictionary *candidate in saved[@"windows"])if([candidate[@"wid"]isEqual:wid])row=candidate;
    assert(row[@"original_space"]&&([row[@"original_space"][@"pending_target"]unsignedLongLongValue]==space||[row[@"original_space"][@"id"]unsignedLongLongValue]==space));
    spaceWrites++;if(!ignoreSpaceWrites)spaceMembership[wid]=@[@(space)];
    if(carryChildOnSpace&&wid.unsignedIntValue==42&&!ignoreSpaceWrites)spaceMembership[@43]=@[@(space)];
    if(replaceAfterSpace){replaceAfterSpace=NO;ownerValue++;}
    if(failSyncAfterSpace){failSyncAfterSpace=NO;failNextSync=YES;}
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
// Existing positive Space cases exercise the same asynchronous retries without
// wall-clock sleeps. Dedicated cases below check unaged and invalidated samples.
static void settledRestore(NSString *reason,BOOL retry,struct dw2_restore_reply *summary) {
    v2Restore(reason,retry,nil,summary);
    if(summary->pending){
        uint64_t now=v2Now();assert(now>3000);
        for(DW2Entry *entry in v2Table.objectEnumerator)if(entry->originalSpace&&entry->restoreSpaceSample){
            entry->restoreSpaceStarted=now-2001;entry->restoreSpaceQuiet=now-501;
        }
        v2Restore(reason,YES,nil,summary);
    }
}
// What a restore of this entry writes at the native origin the window has now (v2RestoreTransform).
static CGAffineTransform rebasedFor(DW2Entry *entry) { return v2RestoreTransform(entry->transform,entry->bounds.origin,nativeBounds.origin); }
static void spaceRestoreSettlementCase(struct dw2_identity who) {
    clearTables();ownerValue=7;spaceMembership[@42]=@[@2];nativeBounds.origin=CGPointMake(10,20);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    DW2Entry *entry=[DW2Entry new];entry->who=who;entry->owner=7;entry->bounds=nativeBounds;
    entry->transform=CGAffineTransformMake(1,0,0,1,-10,-20);
    entry->alpha=.8;entry->hasAlpha=entry->alphaTouched=YES;
    entry->originalSpace=1;entry->originalSpaceDisplay=primaryUUID;entry->state=DW2_RESTORING;
    v2Table[@42]=entry;assert(v2Persist());
    struct dw2_restore_reply summary={0};unsigned moves=spaceWrites;
    v2Restore(@"Space inverse starts settling",YES,nil,&summary);
    assert(summary.pending==1&&v2Table[@42]==entry&&spaceWrites==moves+1
        &&[spaceMembership[@42]isEqual:@[@1]]&&v2SameTransform(nativeTransform,entry->transform));
    assert([readJournal()[@"windows"][0][@"state"]isEqual:@"restoring"]);
    // The application changes native bounds and matrix after the first exact
    // readback. An immediate corrective setter must not hide this late change.
    uint64_t now=v2Now();assert(now>3000);entry->restoreSpaceStarted=now-2001;entry->restoreSpaceQuiet=now-501;
    // The corrective write is the original re-based on where the window is now: it follows the reflowed origin (here 45 lower).
    nativeBounds.origin.y+=45;nativeTransform.ty+=45;
    v2Restore(@"late native reflow",YES,nil,&summary);
    assert(summary.pending==1&&v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-10,-65))&&v2SameTransform(nativeTransform,rebasedFor(entry)));
    entry->restoreSpaceQuiet=v2Now()-501;nativeTransform.tx+=12;
    v2Restore(@"late matrix-only reflow",YES,nil,&summary);
    assert(summary.pending==1&&v2SameTransform(nativeTransform,rebasedFor(entry)));
    entry->restoreSpaceQuiet=v2Now()-501;nativeAlpha=.4;
    v2Restore(@"late alpha change",YES,nil,&summary);assert(summary.pending==1&&nativeAlpha==entry->alpha);
    entry->restoreSpaceQuiet=v2Now()-501;boundsStatus=1000;
    v2Restore(@"unknown settle sample",YES,nil,&summary);assert(summary.pending==1);boundsStatus=0;
    v2Restore(@"exact sample after unknown bounds",YES,nil,&summary);assert(summary.pending==1);
    entry->restoreSpaceQuiet=v2Now()-501;rows=nil;
    v2Restore(@"unknown owners during quiet interval",YES,nil,&summary);
    assert(summary.pending==1&&!entry->restoreSpaceQuiet&&!entry->restoreSpaceSample);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    v2Restore(@"exact sample after unknown owners",YES,nil,&summary);assert(summary.pending==1);
    // A crash discards timing evidence, preserving the exact original ledger.
    DW2Entry *decoded=v2DecodeEntry(readJournal()[@"windows"][0],NO);assert(decoded&&!decoded->restoreSpaceStarted&&!decoded->restoreSpaceQuiet);
    v2Table[@42]=decoded;v2Restore(@"settlement after crash",YES,nil,&summary);assert(summary.pending==1);
    decoded->restoreSpaceStarted=v2Now()-2001;decoded->restoreSpaceQuiet=v2Now()-501;
    v2Restore(@"stable original after reflow",YES,nil,&summary);
    assert(!summary.pending&&summary.journal_persisted&&spaceWrites==moves+1&&!v2Table.count
        &&v2SameTransform(nativeTransform,decoded->transform)&&CGRectEqualToRect(v2Released[@42]->bounds,nativeBounds));
    assert(v2SameTransform(decoded->transform,CGAffineTransformMake(1,0,0,1,-10,-65))); // the retained record says what was written, at the bounds it was written for
    nativeBounds.origin=CGPointMake(25,35);
    puts("PASS: Space restore retains journal through late bounds/matrix/alpha changes and crash, then releases only stable original properties");
}
static void removedSpaceCases(struct dw2_identity who) {
    NSArray *complete=@[@{@"Display Identifier":primaryUUID,@"Spaces":@[@{@"id64":@1},@{@"id64":@3}]},
        @{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@2},@{@"id64":@4}]}];
    v2CopyManagedSpaces=managedSpaceInventory;
    // Model the actual crash/recovery row: the temporary target was removed,
    // while the exact recorded window already has its original singleton Space.
    clearTables();ownerValue=7;spaceMembership[@42]=@[@1];managedSpaces=complete;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    DW2Entry *entry=[DW2Entry new];entry->who=who;entry->owner=7;entry->bounds=nativeBounds;entry->transform=nativeTransform;
    entry->originalSpace=1;entry->originalSpaceDisplay=primaryUUID;entry->pendingSpace=128;entry->state=DW2_RESTORING;
    v2Table[@42]=entry;assert(v2Persist());NSDictionary *saved=readJournal()[@"windows"][0];
    struct dw2_restore_reply summary={0};unsigned moves=spaceWrites;
    settledRestore(@"removed target already original",YES,&summary);
    assert(!summary.pending&&summary.journal_persisted&&spaceWrites==moves&&!v2Table.count&&v2Released[@42]->originalSpace==1);
    assert([readJournal()[@"released_windows"][0][@"original_space"][@"pending_target"]isEqual:@0]);
    // Missing, malformed, duplicate, or incomplete inventories cannot prove
    // deletion. Nor can an existing target, even when it is inactive.
    NSArray *bad=@[NSNull.null,@{},@[],@[complete[0]],
        @[complete[0],@{@"Display Identifier":rightUUID,@"Spaces":@[]}],
        @[complete[0],@{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@YES}]}],
        @[complete[0],@{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@2.5}]}],
        @[complete[0],@{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@1}]}],
        @[complete[0],complete[0]],
        @[complete[0],complete[1],@"malformed trailing row"],
        @[complete[0],@{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@2},@{@"id64":@128}]}],
        @[@{@"Display Identifier":primaryUUID,@"Spaces":@[@{@"id64":@3}]},
          @{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@1},@{@"id64":@2}]}]];
    for(id inventory in bad){
        clearTables();entry=v2DecodeEntry(saved,NO);assert(entry);v2Table[@42]=entry;assert(v2Persist());
        managedSpaces=inventory==NSNull.null?nil:inventory;
        v2Restore(@"unknown or existing pending target",YES,nil,&summary);
        assert(summary.pending==1&&entry->pendingSpace==128&&spaceWrites==moves
            &&[readJournal()[@"windows"][0][@"original_space"][@"pending_target"]isEqual:@128]);
    }
    managedSpaces=complete;
    activeDisplayCount=32;v2Restore(@"saturated active display inventory",YES,nil,&summary);
    assert(summary.pending==1&&entry->pendingSpace==128&&spaceWrites==moves);activeDisplayCount=2;
    // Identity and membership must still match after the inventory query.
    replaceAfterSpaceInventory=YES;v2Restore(@"replacement during Space inventory",YES,nil,&summary);
    assert(summary.pending==1&&entry->pendingSpace==128&&spaceWrites==moves);ownerValue=7;
    changeMembershipAfterSpaceInventory=YES;ignoreSpaceWrites=YES;
    v2Restore(@"membership changed during Space inventory",YES,nil,&summary);
    assert(summary.pending==1&&entry->pendingSpace==128);ignoreSpaceWrites=NO;spaceMembership[@42]=@[@1];moves=spaceWrites;
    // Failing to durably clear intent retains the original and pending row; a
    // later successful retry can release it without issuing a Space mutation.
    failNextSync=YES;v2Restore(@"removed target journal failure",YES,nil,&summary);
    assert(summary.pending==1&&entry->pendingSpace==128&&spaceWrites==moves
        &&[readJournal()[@"windows"][0][@"original_space"][@"pending_target"]isEqual:@128]);
    settledRestore(@"removed target journal retry",YES,&summary);
    assert(!summary.pending&&summary.journal_persisted&&spaceWrites==moves&&!v2Table.count);
    managedSpaces=nil;v2CopyManagedSpaces=NULL;
    puts("PASS: deleted pending Space requires complete inventory, exact original membership/identity and durable clearing; substituted calls only");
}
static int nativeSublevel=-7,sublevelReadStatus,sublevelWriteStatus;
static unsigned sublevelWrites;static BOOL ignoreSublevelWrites;
static CGError readLevel(int cid,uint32_t wid,int *value) { (void)cid;(void)wid;*value=0;return sublevelReadStatus; }
static int readSublevel(int cid,uint32_t wid) { (void)cid;(void)wid;return nativeSublevel; }
static CGError writeSublevel(int cid,uint32_t wid,int value) {
    (void)cid;sublevelWrites++;
    BOOL durable=NO;
    for(NSDictionary *row in readJournal()[@"windows"])if([row[@"wid"]unsignedIntValue]==wid&&[row[@"original_sublevel"]isEqual:@(-7)])durable=YES;
    assert(durable); // Even inverse writes retain the exact original on disk.
    if(!ignoreSublevelWrites&&!sublevelWriteStatus)nativeSublevel=value;
    return sublevelWriteStatus;
}
static void sublevelCases(struct dw2_identity who) {
    clearTables();ownerValue=7;connectionStatus=0;rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    nativeSublevel=-7;sublevelWrites=0;
    struct dw2_record frame={.id=who,.m={1,0,0,1,-40,-50},.flags=DW2_RECORD_PINNED};uint8_t status=255;
    struct dw2_restore_reply summary={0};unsigned transforms=transformWrites;
    v2Apply(&frame,1,&status);assert(status==DW2_SUBLEVEL&&!sublevelWrites&&transformWrites==transforms&&!v2Table.count);
    v2GetWindowLevel=readLevel;v2GetWindowSublevel=readSublevel;v2SetWindowSublevel=writeSublevel;
    assert(v2Caps()&DW2_CAP_PINNED);
    frame.flags=0;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED&&!sublevelWrites&&!v2Table[@42]->sublevelTouched);
    frame.flags=DW2_RECORD_PINNED;transforms=transformWrites;
    failNextSync=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_JOURNAL&&!sublevelWrites&&transformWrites==transforms&&!v2Table[@42]->sublevelTouched);
    v2Restore(@"pin journal failure",NO,nil,&summary);assert(!summary.pending&&summary.journal_persisted);
    sublevelReadStatus=1000;v2Apply(&frame,1,&status);assert(status==DW2_SNAPSHOT&&!sublevelWrites&&!v2Table.count);sublevelReadStatus=0;
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED&&sublevelWrites==1&&nativeSublevel==CGWindowLevelForKey(kCGFloatingWindowLevelKey));
    assert(v2Table[@42]->originalSublevel==-7&&[readJournal()[@"windows"][0][@"original_sublevel"]isEqual:@(-7)]);
    DW2Entry *decoded=v2DecodeEntry(readJournal()[@"windows"][0],NO);assert(decoded&&decoded->sublevelTouched&&decoded->originalSublevel==-7);
    for(id bad in @[@YES,@1.5,@((long long)INT_MAX+1),@((long long)INT_MIN-1)]){
        NSMutableDictionary *row=[readJournal()[@"windows"][0]mutableCopy];row[@"original_sublevel"]=bad;assert(!v2DecodeEntry(row,NO));
    }
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED&&sublevelWrites==1);
    frame.flags=0;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED&&nativeSublevel==-7&&sublevelWrites==2);
    frame.flags=DW2_RECORD_PINNED;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED&&sublevelWrites==3&&v2Table[@42]->originalSublevel==-7);
    // Return-success without actual restoration retains durable cleanup debt.
    ignoreSublevelWrites=YES;v2Restore(@"pin inverse refused",NO,nil,&summary);
    assert(summary.pending==1&&v2Table[@42]->sublevelTouched&&[readJournal()[@"windows"][0][@"original_sublevel"]isEqual:@(-7)]);
    ignoreSublevelWrites=NO;v2Restore(@"pin inverse retry",YES,nil,&summary);
    assert(!summary.pending&&summary.journal_persisted&&nativeSublevel==-7&&!v2Table.count);
    DW2Entry *released=v2Released[@42];assert(released->originalSublevel==-7&&v2ReattachCurrent(released));
    nativeSublevel=3;assert(!v2ReattachCurrent(released));nativeSublevel=-7;
    // Journal decode restores a crash-held pin using its saved original.
    clearTables();v2Table[@42]=decoded;nativeSublevel=3;assert(v2Persist());
    v2Restore(@"pin crash recovery",YES,nil,&summary);assert(!summary.pending&&nativeSublevel==-7);
    // The exact owner must survive fsync and earlier property writes.
    clearTables();unsigned levels=sublevelWrites;transforms=transformWrites;replaceOnSync=YES;
    v2Apply(&frame,1,&status);assert(status==DW2_IDENTITY&&sublevelWrites==levels&&transformWrites==transforms);
    ownerValue=7;v2Restore(@"pin prewrite replacement",NO,nil,&summary);assert(!summary.pending);
    clearTables();replaceAfterTransform=YES;v2Apply(&frame,1,&status);assert(status==DW2_IDENTITY&&sublevelWrites==levels);
    ownerValue=7;v2Restore(@"pin interproperty replacement",NO,nil,&summary);assert(!summary.pending);
    clearTables();ignoreSublevelWrites=YES;v2Apply(&frame,1,&status);assert(status==DW2_NOT_APPLIED&&v2Table[@42]->sublevelTouched);
    ignoreSublevelWrites=NO;v2Restore(@"pin refused forward",NO,nil,&summary);assert(!summary.pending&&nativeSublevel==-7);
    clearTables();v2GetWindowLevel=NULL;v2GetWindowSublevel=NULL;v2SetWindowSublevel=NULL;
    puts("PASS: pin sublevel journal, unchanged wire intent, exact inverse/unpin, identity fences, failed write/readback and crash recovery; substituted calls only");
}

// What the window server lists for a window it has just announced: it is not ordered in yet, so its row has no on-screen key.
static NSArray *veilRows(int layer,BOOL onscreen) {
    NSMutableDictionary *a=[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123,(id)kCGWindowLayer:@(layer)}mutableCopy],*b=[@{(id)kCGWindowNumber:@43,(id)kCGWindowOwnerPID:@123,(id)kCGWindowLayer:@(layer)}mutableCopy];
    if(onscreen){a[(id)kCGWindowIsOnscreen]=@YES;b[(id)kCGWindowIsOnscreen]=@YES;}
    return @[a,b];
}
// A veiled window is an ordinary entry. Substituted native calls and a suspended queue (so no 1-second bound fires on its own):
// what the veil may touch, what is on disk first, and how each way out puts the alpha back.
static void veilCases(struct dw2_identity who) {
    // Never resumed, and kept for the life of the process: a suspended queue must not be released.
    static dispatch_queue_t suspended;
    dispatch_queue_t savedQueue=v2q;suspended=dispatch_queue_create("dw.veil.test",DISPATCH_QUEUE_SERIAL);dispatch_suspend(suspended);v2q=suspended;
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;getTransform=readTransform;setTransform=writeTransform;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    fixtureOnly=NO;allowlist=nil;ownerValue=7;connectionStatus=0;processPID=123;processUID=getuid();goneWID=0;boundsStatus=0;transformReadStatus=0;
    nativeLog=[NSMutableArray array];v2VeilRegistered=YES;atomic_store(&v2VeilOn,true);atomic_store(&v2VeilClient,999);
    struct dw2_restore_reply summary={0};uint8_t status=255;
    struct dw2_record frame={.id=who,.m={2,0,0,2,-50,-70}};
    #define VEIL_RESET(alpha) do{ clearTables();nativeLog=[NSMutableArray array];rows=veilRows(0,NO);nativeAlpha=journalAlpha=(alpha);nativeTransform=CGAffineTransformMake(1,0,0,1,-25,-35);\
        nativeBounds=CGRectMake(25,35,300,200);transformWrites=alphaWrites=0;failNextSync=NO;replaceOnSync=NO;ownerValue=7;goneWID=0;processPID=123;processUID=getuid();allowlist=nil;\
        atomic_store(&v2VeilOn,true);atomic_store(&v2VeilClient,999);requireJournalBeforeAlpha=ignoreAlphaWrites=requireVeilPlacedBeforeTransform=requireNoVeilAlphaBeforeAlpha=NO;ignoreTransformWrites=NO;replaceAfterTransform=NO; }while(0)

    // The capability exists only for the explicit same-user helper that can read and write alpha.
    assert(v2Caps()&DW2_CAP_VEIL);
    fixtureOnly=YES;assert(!(v2Caps()&DW2_CAP_VEIL));fixtureOnly=NO;
    allowlist=@[@{@"pid":@123,@"birth_sec":@100,@"birth_usec":@20}];assert(!(v2Caps()&DW2_CAP_VEIL));allowlist=nil;
    v2VeilRegistered=NO;assert(!(v2Caps()&DW2_CAP_VEIL));v2VeilRegistered=YES;
    CGError (*savedSetAlpha)(int,uint32_t,float)=setAlpha;setAlpha=NULL;assert(!(v2Caps()&DW2_CAP_VEIL));setAlpha=savedSetAlpha;

    // An eligible window: journalled with its original alpha and transform first, then held at alpha 0, and nothing else written.
    VEIL_RESET(1);requireJournalBeforeAlpha=YES;uint64_t writesBefore=atomic_load(&v2JournalWrites);
    v2Veil(42);
    DW2Entry *veiled=v2Table[@42];
    assert(veiled && veiled->veiled && veiled->veilBare && veiled->state==DW2_HELD && veiled->alpha==1 && veiled->alphaTouched && veiled->hasAlpha);
    assert(alphaWrites==1 && nativeAlpha==0 && transformWrites==0 && atomic_load(&v2JournalWrites)==writesBefore+1 && atomic_load(&v2Held)==1);
    NSDictionary *saved=readJournal();assert([saved[@"windows"]count]==1 && [saved[@"windows"][0][@"alpha"]floatValue]==1 && [saved[@"windows"][0][@"alpha_touched"]isEqual:@YES]
        && [saved[@"windows"][0][@"transform"]isEqual:matrix(CGAffineTransformMake(1,0,0,1,-25,-35))]);
    // Already known, or already released: no second record, no second write.
    v2Veil(42);assert(alphaWrites==1 && atomic_load(&v2JournalWrites)==writesBefore+1);
    v2VeilExpire(veiled);assert(!v2Table.count && v2Released[@42]);
    v2Veil(42);assert(!v2Table.count && alphaWrites==2 && nativeAlpha==1);
    requireJournalBeforeAlpha=NO;

    // Everything else is left alone: other level, invisible, below the shell's size floor, no veil asked,
    // the client's own process, the helper's own, another user's, outside an allowlist.
    struct { const char *name; void (^arrange)(void); } refusals[]={
        {"other level",^{rows=veilRows(3,NO);}},{"other level, on screen",^{rows=veilRows(-1,YES);}},{"invisible",^{nativeAlpha=0;}},{"fading in (a sheet's own animation)",^{nativeAlpha=.79f;}},
        {"too narrow",^{nativeBounds=CGRectMake(0,0,39,200);}},{"too short",^{nativeBounds=CGRectMake(0,0,300,39);}},
        {"no veil",^{atomic_store(&v2VeilOn,false);}},{"client's own process",^{atomic_store(&v2VeilClient,123);}},
        {"helper's own process",^{processPID=getpid();}},{"another user",^{processUID=getuid()+1;}},
        {"outside the allowlist",^{allowlist=@[@{@"pid":@124,@"birth_sec":@100,@"birth_usec":@20}];}},
        {"owner unresolvable",^{ownerValue=0;}},{"no window server row",^{rows=nil;}},
    };
    for(size_t i=0;i<sizeof(refusals)/sizeof(*refusals);i++){
        VEIL_RESET(1);refusals[i].arrange();writesBefore=atomic_load(&v2JournalWrites);float alphaBefore=nativeAlpha;v2Veil(42);
        if(v2Table.count||alphaWrites||transformWrites||atomic_load(&v2JournalWrites)!=writesBefore||nativeAlpha!=alphaBefore){fprintf(stderr,"veiled when %s\n",refusals[i].name);abort();}
    }
    VEIL_RESET(1);boundsStatus=1000;v2Veil(42);assert(!v2Table.count && !alphaWrites);boundsStatus=0;
    VEIL_RESET(1);transformReadStatus=1000;v2Veil(42);assert(!v2Table.count && !alphaWrites);transformReadStatus=0;
    // The announcement comes before the window is ordered in; a window already on screen is veiled the same way.
    VEIL_RESET(1);rows=veilRows(0,YES);v2Veil(42);assert(v2Table[@42]&&nativeAlpha==0);
    // The exact floor is a window the shell would offer.
    VEIL_RESET(1);nativeBounds=CGRectMake(0,0,40,40);v2Veil(42);assert(v2Table[@42]&&nativeAlpha==0);

    // No record, no veil: a journal that cannot be written changes nothing, and is retried.
    VEIL_RESET(1);failNextSync=YES;v2Veil(42);
    assert(!v2Table.count && !alphaWrites && nativeAlpha==1 && v2JournalStale);
    v2Restore(@"veil journal retry",YES,nil,&summary);assert(summary.journal_persisted && !v2JournalStale);
    // The window replaced between its record and its first write receives nothing.
    VEIL_RESET(1);replaceOnSync=YES;v2Veil(42);
    assert(!alphaWrites && nativeAlpha==1 && !v2Table.count && !transformWrites);
    // A setter that does not take leaves a journalled entry that is released at once.
    VEIL_RESET(1);ignoreAlphaWrites=YES;v2Veil(42);
    assert(!v2Table.count && v2Released[@42] && nativeAlpha==1 && alphaWrites==1); // written, read back unchanged, released at once; it reads 1, so nothing is put back
    ignoreAlphaWrites=NO;

    // The first frame places it: the transform first, then the original alpha when the record carries none.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];writesBefore=atomic_load(&v2JournalWrites);requireVeilPlacedBeforeTransform=YES;
    v2Apply(&frame,1,&status);requireVeilPlacedBeforeTransform=NO;
    assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"T",@"A:1.00"])] && nativeAlpha==1 && !v2Table[@42]->veiled && !v2Table[@42]->veilBare);
    // The one journal write of the first frame, before its transform: it says a transform is owed. Later frames write nothing to disk.
    assert(atomic_load(&v2JournalWrites)==writesBefore+1 && !readJournal()[@"windows"][0][@"veil_bare"] && [readJournal()[@"windows"][0][@"veil_alpha"]isEqual:@YES]);
    [nativeLog removeAllObjects];v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && !nativeLog.count && atomic_load(&v2JournalWrites)==writesBefore+1); // later frames write neither again
    v2VeilExpire(v2Table[@42]);assert(v2Table[@42] && !alphaWrites==NO); // the bound ends nothing that was placed
    // A window that is placed is never veiled again, however often the window server announces it (a Space change, an order out and in):
    // no write, no record, and the shell's own alpha 0 (a hidden or minimized window) is not touched either.
    {uint64_t placedWrites=atomic_load(&v2JournalWrites);unsigned alphaBefore=alphaWrites,transformBefore=transformWrites;[nativeLog removeAllObjects];
        for(int announcements=0;announcements<3;announcements++)v2Veil(42);
        assert(!nativeLog.count && alphaWrites==alphaBefore && transformWrites==transformBefore && atomic_load(&v2JournalWrites)==placedWrites && nativeAlpha==1 && !v2Table[@42]->veiled);}
    // ... nor one the shell released (it stays where the application put it, at the alpha it had).
    VEIL_RESET(1);v2Veil(42);v2VeilExpire(v2Table[@42]);assert(v2Released[@42] && nativeAlpha==1);
    {unsigned alphaBefore=alphaWrites;uint64_t releasedWrites=atomic_load(&v2JournalWrites);for(int announcements=0;announcements<3;announcements++)v2Veil(42);
        assert(alphaWrites==alphaBefore && atomic_load(&v2JournalWrites)==releasedWrites && !v2Table.count && nativeAlpha==1);}
    // ... or the record's own alpha.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];frame.flags=DW2_RECORD_HAS_ALPHA;frame.alpha=.5f;
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"T",@"A:0.50"])] && nativeAlpha==.5f);
    // ... an explicit zero stays zero (the shell may want it hidden).
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];frame.alpha=0;
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"T",@"A:0.00"])] && nativeAlpha==0);
    frame.flags=0;
    // A transform that does not take is not applied, but the window is not left invisible for it.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];ignoreTransformWrites=YES;
    v2Apply(&frame,1,&status);
    assert(status==DW2_NOT_APPLIED && [nativeLog isEqualToArray:(@[@"T",@"A:1.00"])] && nativeAlpha==1 && !v2Table[@42]->veiled && !v2Table[@42]->veilBare);
    ignoreTransformWrites=NO;v2Restore(@"after a refused transform",NO,nil,&summary);assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-25,-35)));
    // Replaced between the transform and the alpha: no alpha for the replacement.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];replaceAfterTransform=YES;
    v2Apply(&frame,1,&status);assert(status==DW2_IDENTITY && [nativeLog isEqualToArray:(@[@"T"])] && nativeAlpha==0);
    ownerValue=7;v2Restore(@"veiled replacement",NO,nil,&summary);assert(!summary.pending && !v2Table.count);

    // The alpha put back is the journalled original, not a constant: an entry holding a fractional original (as a replay or an older helper
    // could) is lifted to it after the transform, and released to it.
    for(int placed=0;placed<2;placed++){
        VEIL_RESET(1);v2Veil(42);veiled=v2Table[@42];veiled->alpha=.8f;assert(v2Persist());journalAlpha=.8f;[nativeLog removeAllObjects];
        if(placed){v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"T",@"A:0.80"])] && nativeAlpha==.8f);}
        else{v2VeilExpire(veiled);assert([nativeLog isEqualToArray:(@[@"A:0.80"])] && nativeAlpha==.8f && !v2Table.count);}
        v2Restore(@"fractional original",NO,nil,&summary);assert(!summary.pending && nativeAlpha==.8f);
    }
    // A decline (the shell's RESTORE record) puts the original alpha back, and nothing else: the application
    // may have moved the window, and the window server's transform follows its position.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];nativeTransform=CGAffineTransformMake(1,0,0,1,-90,-91);
    struct dw2_record release={.id=who,.flags=DW2_RECORD_RESTORE};
    v2Apply(&release,1,&status);
    assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"A:1.00"])] && nativeAlpha==1 && !transformWrites && !v2Table.count);
    assert(v2Released[@42]->transform.tx==-90 && v2Released[@42]->transform.ty==-91 && !v2Released[@42]->veiled);
    assert([readJournal()[@"windows"]count]==0 && [readJournal()[@"released_windows"]count]==1);
    // A decline of a window nothing veiled is a no-op that is acknowledged.
    clearTables();[nativeLog removeAllObjects];v2Apply(&release,1,&status);assert(status==DW2_APPLIED && !nativeLog.count && !v2Table.count);

    // The bound releases it the same way, once; it does nothing to what is gone, replaced, being released or placed.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];veiled=v2Table[@42];v2VeilExpire(veiled);
    assert([nativeLog isEqualToArray:(@[@"A:1.00"])] && nativeAlpha==1 && !v2Table.count && v2Released[@42]);
    v2VeilExpire(veiled);assert(nativeLog.count==1); // no longer in the table
    VEIL_RESET(1);v2Veil(42);veiled=v2Table[@42];veiled->state=DW2_RESTORING;[nativeLog removeAllObjects];v2VeilExpire(veiled);assert(!nativeLog.count && v2Table[@42]==veiled);
    v2Restore(@"finish",YES,nil,&summary);assert(!summary.pending && nativeAlpha==1);
    // A window that closed while veiled is dropped by the identity logic, with no write.
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];goneWID=42;v2VeilExpire(v2Table[@42]);
    assert(!v2Table.count && !v2Released.count && !nativeLog.count && !transformWrites);
    // ... as is one whose number another window took over.
    goneWID=0;VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];ownerValue=8;v2VeilExpire(v2Table[@42]);
    assert(!v2Table.count && !v2Released.count && !nativeLog.count);ownerValue=7;
    // ... and one still there whose alpha cannot be read back stays journalled, to be retried.
    VEIL_RESET(1);v2Veil(42);veiled=v2Table[@42];ignoreTransformWrites=YES;
    nativeTransform.tx=-26;v2VeilExpire(veiled);assert(!v2Table.count); // a bare release reads, never writes, the transform
    ignoreTransformWrites=NO;

    // The first frame re-reads what the announcement read. The application moved and resized the window in between: the record the
    // frame writes first holds the transform and bounds as they are now, so a release, a quit and a replay put back where the window is.
    NSArray *(^boundsRow)(CGRect)=^NSArray *(CGRect r){return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];};
    VEIL_RESET(1);v2Veil(42);
    CGAffineTransform original=nativeTransform,moved=CGAffineTransformMake(1,0,0,1,-90,-91);CGRect movedBounds=CGRectMake(90,91,320,210);
    assert([readJournal()[@"windows"][0][@"veil_bare"]isEqual:@YES] && [readJournal()[@"windows"][0][@"transform"]isEqual:matrix(original)]);
    nativeTransform=moved;nativeBounds=movedBounds;[nativeLog removeAllObjects];requireVeilPlacedBeforeTransform=YES;
    v2Apply(&frame,1,&status);requireVeilPlacedBeforeTransform=NO;
    assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"T",@"A:1.00"])] && v2SameTransform(v2Table[@42]->transform,moved) && CGRectEqualToRect(v2Table[@42]->bounds,movedBounds));
    assert([readJournal()[@"windows"][0][@"transform"]isEqual:matrix(moved)] && [readJournal()[@"windows"][0][@"bounds"]isEqual:boundsRow(movedBounds)]);
    [nativeLog removeAllObjects];v2Restore(@"quit after the window moved",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,moved) && [nativeLog isEqualToArray:(@[@"T"])]); // not the announcement's, and alpha was not owed
    // A first frame whose record cannot be written changes nothing: the window stays veiled, with what it was read as, and is asked again.
    VEIL_RESET(1);v2Veil(42);nativeTransform=moved;nativeBounds=movedBounds;[nativeLog removeAllObjects];failNextSync=YES;
    v2Apply(&frame,1,&status);
    assert(status==DW2_JOURNAL && !nativeLog.count && nativeAlpha==0 && v2JournalStale);
    veiled=v2Table[@42];assert(veiled && veiled->veiled && veiled->veilBare && veiled->veilAlpha && v2SameTransform(veiled->transform,original) && CGRectEqualToRect(veiled->bounds,CGRectMake(25,35,300,200)));
    v2Restore(@"first frame journal retry",YES,nil,&summary);assert(summary.journal_persisted && !v2JournalStale);
    requireVeilPlacedBeforeTransform=YES;v2Apply(&frame,1,&status);requireVeilPlacedBeforeTransform=NO;
    assert(status==DW2_APPLIED && v2SameTransform(v2Table[@42]->transform,moved) && !v2Table[@42]->veilBare);
    // A window the application moved and nobody placed is released by taking its transform as it is, not by writing the stale one.
    VEIL_RESET(1);v2Veil(42);nativeTransform=moved;nativeBounds=movedBounds;[nativeLog removeAllObjects];v2VeilExpire(v2Table[@42]);
    assert([nativeLog isEqualToArray:(@[@"A:1.00"])] && v2SameTransform(nativeTransform,moved) && v2SameTransform(v2Released[@42]->transform,moved) && !transformWrites);

    // Replay of a writer that died with the window only veiled restores alpha and writes no transform (the window may have moved since);
    // after the first frame the journal says a transform is owed, and replay writes that one.
    VEIL_RESET(1);v2Veil(42);nativeTransform=moved;
    NSMutableDictionary *dead=[readJournal()mutableCopy];dead[@"server_pid"]=@456;dead[@"server_birth_sec"]=@50;dead[@"server_birth_usec"]=@0;
    NSDictionary *survivor=v2WriterIdentity;writeJSON(@"v2-journal.json",dead);clearTables();[nativeLog removeAllObjects];
    assert(v2LoadJournal(nil) && !transformWrites && [nativeLog isEqualToArray:(@[@"A:1.00"])] && nativeAlpha==1 && v2SameTransform(nativeTransform,moved) && v2WriterSame(readJournal(),survivor));
    VEIL_RESET(1);v2Veil(42);nativeTransform=moved;nativeBounds=movedBounds;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    nativeTransform=CGAffineTransformMake(2,0,0,2,-50,-70);[nativeLog removeAllObjects];transformWrites=0;
    dead=[readJournal()mutableCopy];dead[@"server_pid"]=@456;dead[@"server_birth_sec"]=@50;dead[@"server_birth_usec"]=@0;writeJSON(@"v2-journal.json",dead);clearTables();
    assert(v2LoadJournal(nil) && transformWrites==1 && v2SameTransform(nativeTransform,moved) && ![nativeLog containsObject:@"A:1.00"]); // a placed window's alpha reads 1: nothing owed
    // The marks are strict in a journal: booleans that are true, an alpha mark with its alpha obligation, never on a released row.
    VEIL_RESET(1);v2Veil(42);NSDictionary *row=readJournal()[@"windows"][0];assert(v2DecodeEntry(row,NO)->veilBare && v2DecodeEntry(row,NO)->veilAlpha);
    for(NSString *key in @[@"veil_bare",@"veil_alpha"])for(id bad in @[@NO,@1,@"yes",NSNull.null]){NSMutableDictionary *r=[row mutableCopy];r[key]=bad;assert(!v2DecodeEntry(r,NO));}
    {NSMutableDictionary *r=[row mutableCopy];r[@"alpha_touched"]=@NO;assert(!v2DecodeEntry(r,NO));
     r=[row mutableCopy];r[@"state"]=@"released";assert(!v2DecodeEntry(r,YES));}

    // The veil's alpha is the veil's: put back only while it still reads 0. An application that took it over, or a window a frame
    // lifted without asking for an alpha, is left alone; an alpha the shell asked for is its own obligation and is put back.
    VEIL_RESET(1);v2Veil(42);nativeAlpha=.5f;[nativeLog removeAllObjects];v2VeilExpire(v2Table[@42]);
    assert(!nativeLog.count && nativeAlpha==.5f && !v2Table.count && !v2Released[@42]->alphaTouched);
    VEIL_RESET(1);v2Veil(42);nativeAlpha=.5f;[nativeLog removeAllObjects];v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && [nativeLog isEqualToArray:(@[@"T"])] && nativeAlpha==.5f && !v2Table[@42]->veiled); // lifting does not overwrite what the application set
    VEIL_RESET(1);v2Veil(42);[nativeLog removeAllObjects];v2Apply(&frame,1,&status);[nativeLog removeAllObjects];
    v2Restore(@"placed without an alpha of its own",NO,nil,&summary);
    assert(!summary.pending && [nativeLog isEqualToArray:(@[@"T"])] && nativeAlpha==1); // never written again
    VEIL_RESET(1);v2Veil(42);frame.flags=DW2_RECORD_HAS_ALPHA;frame.alpha=.5f;requireNoVeilAlphaBeforeAlpha=YES;v2Apply(&frame,1,&status);requireNoVeilAlphaBeforeAlpha=NO;
    assert(status==DW2_APPLIED && nativeAlpha==.5f && !readJournal()[@"windows"][0][@"veil_alpha"]);
    [nativeLog removeAllObjects];v2Restore(@"placed with an alpha of its own",NO,nil,&summary);
    assert(!summary.pending && [nativeLog isEqualToArray:(@[@"T",@"A:1.00"])] && nativeAlpha==1);
    // ... also when the alpha is asked for only by a later frame: the record says so before the alpha is written.
    frame.flags=0;VEIL_RESET(1);v2Veil(42);v2Apply(&frame,1,&status);assert(v2Table[@42]->veilAlpha);
    frame.flags=DW2_RECORD_HAS_ALPHA;frame.alpha=.5f;requireNoVeilAlphaBeforeAlpha=YES;v2Apply(&frame,1,&status);requireNoVeilAlphaBeforeAlpha=NO;
    assert(status==DW2_APPLIED && nativeAlpha==.5f && !v2Table[@42]->veilAlpha && !readJournal()[@"windows"][0][@"veil_alpha"]);
    [nativeLog removeAllObjects];v2Restore(@"alpha asked for by a later frame",NO,nil,&summary);assert([nativeLog isEqualToArray:(@[@"T",@"A:1.00"])] && nativeAlpha==1);
    // A later frame whose record cannot be written does not write the alpha.
    VEIL_RESET(1);v2Veil(42);frame.flags=0;v2Apply(&frame,1,&status);frame.flags=DW2_RECORD_HAS_ALPHA;frame.alpha=.5f;[nativeLog removeAllObjects];failNextSync=YES;
    v2Apply(&frame,1,&status);assert(status==DW2_JOURNAL && !nativeLog.count && v2Table[@42]->veilAlpha);
    frame.flags=0;

    // Ending the veil lets go of what it holds and of nothing placed.
    VEIL_RESET(1);v2Veil(42);nativeAlpha=1;/* one stub alpha serves both windows */v2Veil(43);assert(v2Table.count==2);
    struct dw2_record second=frame;second.id.wid=43;v2Apply(&second,1,&status);assert(status==DW2_APPLIED && !v2Table[@43]->veiled);
    nativeAlpha=0;/* window 42 is the one still held; one stub alpha serves both */[nativeLog removeAllObjects];atomic_store(&v2VeilOn,false);v2VeilRelease();
    assert(!atomic_load(&v2VeilOn) && !v2Table[@42] && v2Released[@42] && v2Table[@43] && v2Table[@43]->state==DW2_HELD && [nativeLog isEqualToArray:(@[@"A:1.00"])]);
    v2Restore(@"end",NO,nil,&summary);assert(!summary.pending && !v2Table.count);

    // Recovery: the journal of a writer that died while it held a veiled window restores the original alpha like any entry.
    VEIL_RESET(1);v2Veil(42);assert(nativeAlpha==0);
    NSMutableDictionary *old=[readJournal()mutableCopy];old[@"server_pid"]=@456;old[@"server_birth_sec"]=@50;old[@"server_birth_usec"]=@0;
    NSDictionary *currentWriter=v2WriterIdentity;writeJSON(@"v2-journal.json",old);clearTables();nativeLog=[NSMutableArray array];
    assert(v2LoadJournal(nil));
    assert(nativeAlpha==1 && !v2Table.count && v2Released[@42] && [nativeLog containsObject:@"A:1.00"] && v2WriterSame(readJournal(),currentWriter));
    // and a connection that is lost with the window still held (the session's end) does the same.
    VEIL_RESET(1);v2Veil(42);assert(nativeAlpha==0);v2Restore(@"disconnect",NO,nil,&summary);assert(!summary.pending && nativeAlpha==1 && !v2Table.count);

    // The request: refused by a helper that cannot, refused without a client process, accepted otherwise, and ended with the session.
    VEIL_RESET(1);
    dispatch_queue_t queue=dispatch_queue_create("dw.veil.request.test",DISPATCH_QUEUE_SERIAL);v2q=queue;
    int sockets[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));const int near=sockets[0],far=sockets[1];
    DW2Connection *c=[DW2Connection new];c->fd=near;pthread_mutex_init(&c->writeLock,NULL);c->role=DW2_ROLE_CONTROL;c->session=v2Session=7;
    __block struct dw2_header header={.length=sizeof(struct dw2_veil),.type=DW2_VEIL,.seq=5};
    __block struct dw2_veil_reply answer;
    void (^ask)(uint32_t,uint32_t,BOOL) = ^(uint32_t mode,uint32_t reserved,BOOL expectedOK) {
        struct dw2_veil request={.mode=mode,.reserved=reserved};
        assert(v2Handle(c,&header,&request)==expectedOK);header.seq++;
        if(!expectedOK)return;
        dispatch_sync(queue,^{});
        struct { struct dw2_header h; struct dw2_veil_reply r; } in;
        assert(read(far,&in,sizeof(in))==sizeof(in) && in.h.type==(DW2_VEIL|DW2_REPLY) && in.h.seq==header.seq-1 && in.h.length==sizeof(in.r));
        answer=in.r;
    };
    atomic_store(&v2VeilOn,false);atomic_store(&v2VeilClient,0);
    ask(1,0,YES);assert(answer.status==DW2_SCOPE && !atomic_load(&v2VeilOn));         // the client's process is unknown
    atomic_store(&v2VeilClient,999);fixtureOnly=YES;
    ask(1,0,YES);assert(answer.status==DW2_SCOPE && !atomic_load(&v2VeilOn));         // not a desktop helper
    fixtureOnly=NO;ask(1,1,NO);ask(2,0,NO);                                           // malformed: a protocol error
    header.length=4;{struct dw2_veil request={.mode=1};assert(!v2Handle(c,&header,&request));}header.length=sizeof(struct dw2_veil);
    ask(1,0,YES);assert(answer.status==DW2_APPLIED && answer.timeout_ms==DW2_VEIL_TIMEOUT_MS && atomic_load(&v2VeilOn));
    // The announcement: only 1325, only with a payload, only the window id, only while asked for.
    uint8_t payload[12]={0};uint32_t announced=42;memcpy(payload+8,&announced,sizeof(announced));
    writesBefore=atomic_load(&v2JournalWrites);
    v2WindowAdded(1326,payload,sizeof(payload),NULL);v2WindowAdded(1325,payload,11,NULL);v2WindowAdded(1325,NULL,12,NULL);dispatch_sync(queue,^{});
    assert(!v2Table.count && atomic_load(&v2JournalWrites)==writesBefore);
    v2WindowAdded(1325,payload,sizeof(payload),NULL);dispatch_sync(queue,^{});
    assert(v2Table[@42]->veiled && nativeAlpha==0);
    ask(0,0,YES);assert(answer.status==DW2_APPLIED && !atomic_load(&v2VeilOn) && !v2Table[@42] && nativeAlpha==1);
    v2WindowAdded(1325,payload,sizeof(payload),NULL);dispatch_sync(queue,^{});assert(!v2Table.count);
    // A new control session starts without a veil, whatever the last one left: the flag is cleared where the session is made.
    {
        secret=[@"" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
        int pairB[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pairB));
        DW2Connection *fresh=[DW2Connection new];fresh->fd=pairB[0];pthread_mutex_init(&fresh->writeLock,NULL);
        struct dw2_hello hello={.magic={'D','W','v','2'},.version=DW2_VERSION,.role=DW2_ROLE_CONTROL};memcpy(hello.nonce,secret.UTF8String,64);
        struct dw2_header hello_header={.length=sizeof(hello),.type=DW2_HELLO};
        v2Session=0;atomic_store(&v2VeilOn,true);atomic_store(&v2VeilClient,0);
        assert(v2Handle(fresh,&hello_header,&hello) && v2Session && !atomic_load(&v2VeilOn) && atomic_load(&v2VeilClient)==getpid());
        struct { struct dw2_header h; struct dw2_hello_reply r; } greeting;assert(read(pairB[1],&greeting,sizeof(greeting))==sizeof(greeting) && !greeting.r.status && (greeting.r.caps&DW2_CAP_VEIL));
        v2Session=0;v2Beats=nil;atomic_store(&v2VeilClient,0);fresh->fd=-1;close(pairB[0]);close(pairB[1]);
        v2Session=8;
    }
    // A request that outlives its session enables nothing.
    v2Session=8;ask(1,0,YES);assert(answer.status==DW2_SCOPE && !atomic_load(&v2VeilOn));v2Session=0;
    c->fd=-1;close(near);close(far);
    v2q=savedQueue;clearTables();atomic_store(&v2VeilOn,false);atomic_store(&v2VeilClient,0);v2VeilRegistered=NO;nativeLog=nil;
    #undef VEIL_RESET
    puts("PASS: arrival veil admits only eligible windows with a journalled original before any write, re-reads and journals the transform before the first frame writes, unveils transform-then-alpha, puts the veil's alpha back only while it reads 0, releases by decline, bound, end and recovery (replay included), and drops closed windows; substituted calls only");
}
static void spaceCases(struct dw2_identity who) {
    copyWindowSpaces=windowSpaces;copySpaceDisplay=spaceDisplay;displayCurrentSpace=currentSpace;
    getSpaceType=spaceKind;moveWindowsToSpace=writeSpace;createDisplayUUID=displayID;
    v2CopyManagedSpaces=managedSpaceInventory;v2ManagedSpacesResolved=YES;
    managedSpaces=@[@{@"Display Identifier":primaryUUID,@"Spaces":@[@{@"id64":@1},@{@"id64":@3}]},
        @{@"Display Identifier":rightUUID,@"Spaces":@[@{@"id64":@2},@{@"id64":@4}]}];
    assert(v2Caps()&DW2_CAP_SPACE);
    clearTables();spaceMembership=[@{@42:@[@1]}mutableCopy];ownerValue=7;connectionStatus=0;primaryCurrent=1;rightCurrent=2;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    struct dw2_record frame={.id=who,.m={1,0,0,1,-40,-50}};uint64_t target=2;uint8_t status=255;
    struct dw2_restore_reply summary={0};unsigned writes=transformWrites;spaceWrites=0;
    failNextSync=YES;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_JOURNAL&&!spaceWrites&&transformWrites==writes&&!v2Table.count);
    v2Restore(@"Space journal retry",YES,nil,&summary);assert(summary.journal_persisted);
    v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_APPLIED&&spaceWrites==1&&[spaceMembership[@42]isEqual:@[@2]]&&v2Table[@42]->originalSpace==1&&!v2Table[@42]->pendingSpace);
    NSDictionary *journal=readJournal();NSDictionary *saved=journal[@"windows"][0];
    assert([saved[@"original_space"][@"id"]isEqual:@1]&&[saved[@"original_space"][@"pending_target"]isEqual:@0]);
    assert(v2DecodeEntry(saved,NO)->originalSpace==1);
    NSMutableDictionary *bad=[saved mutableCopy];bad[@"original_space"]=@{@"id":@1,@"display":primaryUUID,@"pending_target":@2.5};assert(!v2DecodeEntry(bad,NO));
    v2ApplyWithSpaces(&frame,&target,1,&status);assert(status==DW2_APPLIED&&spaceWrites==1);
    // A different inactive Space on the same display cannot gather this window.
    target=4;v2ApplyWithSpaces(&frame,&target,1,&status);assert(status==DW2_SPACE&&spaceWrites==1&&v2Table[@42]->originalSpace==1);
    // Restoration returns to the saved existing Space even after it is inactive.
    primaryCurrent=3;settledRestore(@"original inactive Space",NO,&summary);
    assert(!summary.pending&&summary.journal_persisted&&spaceWrites==2&&[spaceMembership[@42]isEqual:@[@1]]);
    assert(v2Released[@42]->originalSpace==1&&v2DecodeEntry(readJournal()[@"released_windows"][0],YES));primaryCurrent=1;
    // Already-on-target presentation gains no Space obligation or setter.
    clearTables();target=1;writes=spaceWrites;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_APPLIED&&spaceWrites==writes&&!v2Table[@42]->originalSpace&&!readJournal()[@"windows"][0][@"original_space"]);
    v2Restore(@"same Space",NO,nil,&summary);assert(!summary.pending);
    // Guest 2026-10-29, TextEdit: a document closed while the canvas still listed it. WindowServer had destroyed the window
    // (absent from the complete list, alpha 0, transform read refused, every Space-membership selector empty) while the owner
    // cache still answered. The target-bearing record is refused SPACE for those frames with no write and no journal change;
    // the entry admitted earlier stays journalled, and its release then settles as gone. An open window is never refused here.
    clearTables();target=1;v2ApplyWithSpaces(&frame,&target,1,&status);assert(status==DW2_APPLIED&&v2Table[@42]);
    writes=transformWrites;unsigned closingMoves=spaceWrites;NSData *closingJournal=[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]];
    spaceMembership[@42]=@[];transformReadStatus=1000;
    for(unsigned frames=0;frames<3;frames++){
        status=255;v2ApplyWithSpaces(&frame,&target,1,&status);
        assert(status==DW2_SPACE&&transformWrites==writes&&spaceWrites==closingMoves&&v2Table[@42]&&!v2Table[@42]->originalSpace&&!v2Table[@42]->pendingSpace);
    }
    assert([closingJournal isEqualToData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]]]);
    rows=@[@{(id)kCGWindowNumber:@99,(id)kCGWindowOwnerPID:@123}];
    v2Restore(@"closed document",NO,nil,&summary);
    assert(summary.count==1&&!summary.pending&&summary.journal_persisted&&!v2Table.count&&!v2Released.count&&transformWrites==writes&&spaceWrites==closingMoves);
    assert([v2LastRestore[@"results"][0][@"outcome"]isEqual:@"gone"]);
    transformReadStatus=0;rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];spaceMembership[@42]=@[@1];
    clearTables();target=1;v2ApplyWithSpaces(&frame,&target,1,&status);assert(status==DW2_APPLIED);v2Restore(@"open window again",NO,nil,&summary);assert(!summary.pending);
    // Nil, empty, multi-Space and inactive source membership refuse untouched.
    for(id membership in @[(id)NSNull.null,@[],@[@1,@2],@[@3]]){
        clearTables();if(membership==NSNull.null)[spaceMembership removeObjectForKey:@42];else spaceMembership[@42]=membership;
        target=2;writes=transformWrites;unsigned moves=spaceWrites;v2ApplyWithSpaces(&frame,&target,1,&status);
        assert(status==DW2_SPACE&&transformWrites==writes&&spaceWrites==moves&&!v2Table.count);
    }
    spaceMembership[@42]=@[@1];
    // A known skip after commit does not leave a fictitious unconfirmed request.
    clearTables();changeTargetOnSync=YES;target=2;writes=spaceWrites;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_SPACE&&spaceWrites==writes&&!v2Table[@42]->pendingSpace&&!v2Table[@42]->originalSpace);
    assert(!readJournal()[@"windows"][0][@"original_space"]);rightCurrent=2;v2Restore(@"target changed before write",NO,nil,&summary);assert(!summary.pending);
    clearTables();replaceOnSync=YES;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_IDENTITY&&spaceWrites==writes&&!v2Table[@42]->pendingSpace);ownerValue=7;v2Restore(@"identity changed before write",NO,nil,&summary);assert(!summary.pending);
    // Void acceptance without observed membership is not APPLIED or RESTORED.
    clearTables();ignoreSpaceWrites=YES;writes=transformWrites;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_NOT_APPLIED&&transformWrites==writes&&v2Table[@42]->pendingSpace==2);
    unsigned moves=spaceWrites;rightCurrent=4;target=4;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_NOT_APPLIED&&spaceWrites==moves&&v2Table[@42]->pendingSpace==2);rightCurrent=2;
    v2Restore(@"unobserved forward",NO,nil,&summary);assert(summary.pending==1&&spaceWrites==moves&&v2Table[@42]->pendingSpace==2);
    // Crash decode retains uncertain membership, then a later target observation
    // permits the inverse and durable release without replacing the original.
    journal=readJournal();DW2Entry *uncertain=v2DecodeEntry(journal[@"windows"][0],NO);assert(uncertain&&uncertain->pendingSpace==2&&uncertain->originalSpace==1);
    clearTables();v2Table[@42]=uncertain;spaceMembership[@42]=@[@2];ignoreSpaceWrites=NO;
    settledRestore(@"late target after crash",YES,&summary);assert(!summary.pending&&spaceWrites==moves+1&&[spaceMembership[@42]isEqual:@[@1]]);
    // Replacement after the void call cannot receive transform/alpha or an ACK.
    clearTables();target=2;replaceAfterSpace=YES;writes=transformWrites;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_IDENTITY&&transformWrites==writes&&v2Table[@42]->pendingSpace==2);ownerValue=7;
    settledRestore(@"Space replacement boundary",NO,&summary);assert(!summary.pending&&[spaceMembership[@42]isEqual:@[@1]]);
    // Failure to commit observed forward completion still retains its target;
    // cleanup retries that durability fence and then the exact inverse.
    clearTables();failSyncAfterSpace=YES;v2ApplyWithSpaces(&frame,&target,1,&status);
    assert(status==DW2_JOURNAL&&v2Table[@42]->pendingSpace==2&&[spaceMembership[@42]isEqual:@[@2]]);
    settledRestore(@"Space confirmation journal retry",NO,&summary);assert(!summary.pending&&summary.journal_persisted);
    clearTables();ignoreSpaceWrites=YES;v2ApplyWithSpaces(&frame,&target,1,&status);assert(status==DW2_NOT_APPLIED);
    ignoreSpaceWrites=NO;spaceMembership[@42]=@[@2];failNextSync=YES;moves=spaceWrites;
    v2Restore(@"inverse despite failed confirmation journal",NO,nil,&summary);
    assert(summary.pending==1&&spaceWrites==moves+1&&[spaceMembership[@42]isEqual:@[@1]]&&v2Table[@42]->pendingSpaceObserved);
    settledRestore(@"retry observed target durability",YES,&summary);assert(!summary.pending&&summary.journal_persisted&&spaceWrites==moves+1);
    // Confirm prior B before staging A. A failed batch commit must not leave a
    // persisted, never-attempted A target through B's earlier journal write.
    clearTables();spaceMembership[@42]=@[@1];spaceMembership[@43]=@[@2];
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123},@{(id)kCGWindowNumber:@43,(id)kCGWindowOwnerPID:@123}];
    DW2Entry *prior=[DW2Entry new];prior->who=who;prior->who.wid=43;prior->owner=7;prior->bounds=nativeBounds;prior->transform=nativeTransform;
    prior->originalSpace=1;prior->originalSpaceDisplay=primaryUUID;prior->pendingSpace=2;v2Table[@43]=prior;assert(v2Persist());
    struct dw2_record records[2]={frame,frame};records[1].id.wid=43;uint64_t targets[2]={2,2};uint8_t statuses[2]={255,255};
    failSyncCountdown=3;v2ApplyWithSpaces(records,targets,2,statuses);
    assert(statuses[0]==DW2_JOURNAL&&!v2Table[@42]&&!prior->pendingSpace);
    journal=readJournal();assert([journal[@"windows"]count]==1&&[journal[@"windows"][0][@"wid"]isEqual:@43]&&[journal[@"windows"][0][@"original_space"][@"pending_target"]isEqual:@0]);
    settledRestore(@"batch cleanup",NO,&summary);assert(!summary.pending);
    // Root movement can carry the child before its direct record. The child's
    // original remains independent even if the root closes before cleanup.
    clearTables();spaceMembership[@42]=@[@1];spaceMembership[@43]=@[@1];carryChildOnSpace=YES;moves=spaceWrites;
    v2ApplyWithSpaces(records,targets,2,statuses);
    assert(statuses[0]==DW2_APPLIED&&statuses[1]==DW2_APPLIED&&spaceWrites==moves+1
        &&v2Table[@43]->originalSpace==1&&!v2Table[@43]->pendingSpace);
    carryChildOnSpace=NO;goneWID=42;settledRestore(@"root gone carried child",NO,&summary);
    assert(!summary.pending&&spaceWrites==moves+2&&[spaceMembership[@43]isEqual:@[@1]]);goneWID=0;
    spaceRestoreSettlementCase(who);
    removedSpaceCases(who);
    clearTables();spaceMembership=nil;copyWindowSpaces=NULL;copySpaceDisplay=NULL;displayCurrentSpace=NULL;getSpaceType=NULL;moveWindowsToSpace=NULL;createDisplayUUID=NULL;
    puts("PASS: optional Space journal, active cross-display policy, no-op target, commit/identity fences, uncertain forward and exact inverse retries; substituted calls only");
}

// The native frame of a window moves during a session: the application re-lays itself out, or WindowServer's own title drag moves it
// before the shell takes the drag over. A window server transform carries the window's position, so the original captured at the
// first touch (which says the old origin) written back as it was draws the window at its old place while its native frame, hit
// testing and the next session's original are elsewhere (measured in the guest: Ghostty drawn at (601,417), native frame at
// (494,399), after a takeover drag at zoom 1). Restoration re-bases the original on the origin read when it writes.
static DW2Entry *heldOriginal(struct dw2_identity who,CGAffineTransform transform,CGRect bounds) {
    DW2Entry *entry=[DW2Entry new];entry->who=who;entry->owner=7;entry->state=DW2_HELD;entry->transform=transform;entry->bounds=bounds;
    v2Table[@(who.wid)]=entry;assert(v2Persist());return entry;
}
static void rebaseCases(struct dw2_identity who) {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;getTransform=readTransform;setTransform=writeTransform;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    fixtureOnly=NO;allowlist=nil;ownerValue=7;connectionStatus=0;processPID=123;processUID=getuid();goneWID=0;boundsStatus=0;transformReadStatus=0;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    CGRect savedBounds=nativeBounds;CGAffineTransform savedTransform=nativeTransform;
    struct dw2_restore_reply summary={0};CGAffineTransform canvas=CGAffineTransformMake(2,0,0,2,-300,-200);

    // Unmoved: exactly the original, as before.
    clearTables();nativeBounds=CGRectMake(25,35,300,200);nativeTransform=canvas;
    DW2Entry *entry=heldOriginal(who,CGAffineTransformMake(1,0,0,1,-25,-35),nativeBounds);transformWrites=0;
    v2Restore(@"unmoved",NO,nil,&summary);
    assert(!summary.pending && transformWrites==1 && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-25,-35)) && v2Released[@42]==entry);

    // Moved: the native frame is where the application or WindowServer left it, and that is where the window is put back. The retained
    // record, and the journal it was written to, hold what is now on the window and the bounds it was written for.
    clearTables();nativeBounds=CGRectMake(25,35,300,200);nativeTransform=canvas;
    entry=heldOriginal(who,CGAffineTransformMake(1,0,0,1,-25,-35),nativeBounds);
    nativeBounds=CGRectMake(80,20,300,200);transformWrites=0;
    v2Restore(@"native frame moved during the session",NO,nil,&summary);
    assert(!summary.pending && summary.journal_persisted && transformWrites==1 && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-80,-20)));
    assert(v2SameTransform(entry->transform,nativeTransform) && CGRectEqualToRect(entry->bounds,nativeBounds) && v2Released[@42]==entry);
    assert([readJournal()[@"released_windows"][0][@"transform"]isEqual:matrix(CGAffineTransformMake(1,0,0,1,-80,-20))]
        && [readJournal()[@"released_windows"][0][@"bounds"]isEqual:(@[@80,@20,@300,@200])]);

    // An original captured already displaced (an earlier session's stale restore: drawn at (601,417), frame at (494,399)) is a plain
    // transform, native by definition, and is put right rather than carried into the next session.
    clearTables();nativeBounds=CGRectMake(494,399,1319,692);nativeTransform=canvas;
    heldOriginal(who,CGAffineTransformMake(1,0,0,1,-601,-417),nativeBounds);
    v2Restore(@"stale original",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-494,-399)));

    // Any other original keeps its linear part and its place relative to the frame: t' = t - M*(origin - captured origin).
    clearTables();nativeBounds=CGRectMake(50,35,300,200);nativeTransform=canvas;
    heldOriginal(who,CGAffineTransformMake(2,0,0,2,-100,-70),nativeBounds);nativeBounds=CGRectMake(80,45,300,200);
    v2Restore(@"scaled original",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(2,0,0,2,-160,-90)));
    clearTables();nativeBounds=CGRectMake(10,10,300,200);nativeTransform=canvas;
    heldOriginal(who,CGAffineTransformMake(0,1,-1,0,5,7),nativeBounds);nativeBounds=CGRectMake(13,14,300,200);
    v2Restore(@"rotated original",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(0,1,-1,0,9,4)));
    // Moved back, a non-plain original is exactly itself again.
    clearTables();nativeBounds=CGRectMake(50,35,300,200);nativeTransform=canvas;
    heldOriginal(who,CGAffineTransformMake(2,0,0,2,-100,-70),nativeBounds);
    v2Restore(@"scaled original, unmoved",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(2,0,0,2,-100,-70)));

    // No origin, no re-based write: the captured original is the best that can be written, the window stays pending with its original
    // and the bounds it was captured at on disk, and the next pass writes the re-based one.
    clearTables();nativeBounds=CGRectMake(25,35,300,200);nativeTransform=canvas;
    entry=heldOriginal(who,CGAffineTransformMake(1,0,0,1,-25,-35),nativeBounds);nativeBounds=CGRectMake(80,20,300,200);boundsStatus=1000;
    v2Restore(@"origin unreadable",NO,nil,&summary);
    assert(summary.pending==1 && v2Table[@42]==entry && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-25,-35)));
    NSDictionary *diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert([diagnostic[@"origin_status"]isEqual:@1000] && diagnostic[@"native_origin"]==NSNull.null && diagnostic[@"target_transform"]==NSNull.null
        && [diagnostic[@"captured_origin"]isEqual:(@[@25,@35])] && v2LastRestoreValid(v2LastRestore));
    assert([readJournal()[@"windows"][0][@"transform"]isEqual:matrix(CGAffineTransformMake(1,0,0,1,-25,-35))] && [readJournal()[@"windows"][0][@"bounds"]isEqual:(@[@25,@35,@300,@200])]);
    boundsStatus=0;v2Restore(@"origin readable again",YES,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-80,-20)) && CGRectEqualToRect(v2Released[@42]->bounds,nativeBounds));

    // A window that moves between the write and the read of its origin is not restored by that write: pending, the original still on disk,
    // and the next pass re-bases on where it is now.
    clearTables();nativeBounds=CGRectMake(25,35,300,200);nativeTransform=canvas;
    entry=heldOriginal(who,CGAffineTransformMake(1,0,0,1,-25,-35),nativeBounds);moveAfterTransformWrite=YES;
    v2Restore(@"moved between write and read",NO,nil,&summary);
    assert(summary.pending==1 && v2Table[@42]==entry && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-25,-35)) && nativeBounds.origin.x==32);
    diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];assert([diagnostic[@"native_origin"]isEqual:(@[@25,@35])]);
    assert([readJournal()[@"windows"][0][@"state"]isEqual:@"restoring"] && [readJournal()[@"windows"][0][@"transform"]isEqual:matrix(CGAffineTransformMake(1,0,0,1,-25,-35))]);
    v2Restore(@"moved window, second pass",YES,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-32,-35)) && v2SameTransform(v2Released[@42]->transform,nativeTransform));

    // A crash between the move and the release: the journal holds the original and its origin, the next helper re-bases it.
    clearTables();nativeBounds=CGRectMake(25,35,300,200);nativeTransform=canvas;
    heldOriginal(who,CGAffineTransformMake(1,0,0,1,-25,-35),nativeBounds);
    DW2Entry *decoded=v2DecodeEntry(readJournal()[@"windows"][0],NO);assert(decoded);
    clearTables();v2Table[@42]=decoded;nativeBounds=CGRectMake(120,90,300,200);assert(v2Persist());
    v2Restore(@"startup recovery after a move",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-120,-90)));

    // A retained original whose window moved is still re-based when it is taken up again after the Dock was replaced (the reset
    // identity transform it finds is the reattachment guard's to accept; the geometry guard stays as strict as it was).
    clearTables();nativeBounds=CGRectMake(25,35,300,200);nativeTransform=canvas;
    heldOriginal(who,CGAffineTransformMake(1,0,0,1,-25,-35),nativeBounds);nativeBounds=CGRectMake(80,20,300,200);
    v2Restore(@"to be retained",NO,nil,&summary);assert(!summary.pending);
    DW2Entry *retained=v2Released[@42];[v2Released removeAllObjects];retained->reattaching=YES;retained->state=DW2_RESTORING;v2Table[@42]=retained;
    nativeTransform=CGAffineTransformIdentity;transformWrites=0;
    v2Restore(@"reattach after a Dock reset",YES,nil,&summary);
    assert(!summary.pending && transformWrites==1 && v2SameTransform(nativeTransform,CGAffineTransformMake(1,0,0,1,-80,-20)));
    nativeBounds.origin=CGPointMake(90,20); // moved again: the guard that exists to refuse a changed window still refuses
    clearTables();retained->reattaching=YES;retained->state=DW2_RESTORING;v2Table[@42]=retained;nativeTransform=CGAffineTransformIdentity;transformWrites=0;
    v2Restore(@"reattach of a moved window",YES,nil,&summary);assert(summary.pending==1 && !transformWrites);

    clearTables();nativeBounds=savedBounds;nativeTransform=savedTransform;
    puts("PASS: restoration re-bases the original on the native origin read at the write (plain originals are native, others keep their linear part), refuses a re-based write without an origin or with one that moved, and the journal keeps the captured pair until release; substituted calls only");
}
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
    assert(!v2BootUUIDValid(nil) && !v2BootUUIDValid(@1) && !v2BootUUIDValid(@"48359692C6EC-4E77-8BD8-B68CF839CB16")
        && !v2BootUUIDValid(@"48359692-C6EC-4E77-8BD8-B68CF839CB1G"));
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
    entry->transform=CGAffineTransformMake(1,0,0,1,-25,-35);entry->bounds=CGRectMake(25,35,300,200);
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
    ownerValue=7;connectionStatus=0;rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
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
    nativeBounds=CGRectMake(25,35,350,250);v2Restore(@"released original",NO,nil,&summary);
    assert(!summary.pending && summary.journal_persisted && !v2Table.count && v2Released.count==1);
    assert(CGRectEqualToRect(v2Released[@42]->bounds,nativeBounds) && v2Released[@42]->alphaTouched && nativeAlpha==.8f);
    journal=readJournal();assert([journal[@"v"]isEqual:@3] && [journal[@"state"]isEqual:@"empty"] && [journal[@"released_windows"]count]==1);
    assert(v2WriterSame(journal,v2WriterIdentity) && !atomic_load(&v2Held) && !atomic_load(&v2Restoring));
    writes=transformWrites;clearTables();assert(v2LoadJournal(nil));
    assert(transformWrites==writes && !v2Table.count && v2Released.count==1); // Same writer never replays released rows.

    // Re-admission snapshots current outside-canvas state; failure to commit that
    // replacement retains the old released original and writes no native state.
    DW2Entry *releasedEntry=v2Released[@42];nativeTransform.tx=-40;nativeTransform.ty=-60;nativeBounds.origin=CGPointMake(40,60);nativeAlpha=.7f;
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
    requirePendingBeforeTransform=NO;nativeTransform.tx=-55;nativeBounds.origin.x=55;v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
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
        popup->transform=CGAffineTransformMake(1,0,0,1,-430,-367);popup->bounds=CGRectMake(430,367,75,46);v2Table[@(wid)]=popup;
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
    rebaseCases(recorded);
    // Malformed private paths are refused without waiting for a FIFO writer.
    assert(!mkfifoat(directoryFD,"recovery-source.json",0600));BOOL absent=YES;
    assert(!v2ReadJournal("recovery-source.json",&absent) && !absent);assert(!unlinkat(directoryFD,"recovery-source.json",0));
    assert(!unlinkat(directoryFD,"v2-journal.json",0));close(directoryFD);directoryFD=-1;assert(!rmdir(directory));
    puts("PASS: identity, repeated-frame, strict schema3 retained originals, guarded durable handoff/retry/crash-chain and bounded admission; no native window mutation");
} }
