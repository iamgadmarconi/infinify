// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Shared substitute state, native call substitutes and journal helpers. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.
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
// Arrival placement cases: a root and its child window, each with its own transform and bounds, and the window server's parent of each.
static BOOL perWindowNatives,requireArrivalPlacedBeforeTransform;
static NSMutableDictionary<NSNumber *,NSValue *> *perTransform,*perBounds;
static NSMutableDictionary<NSNumber *,NSNumber *> *parentOfWindow;
static CGAffineTransform perWindowTransform(uint32_t wid) {CGAffineTransform t=CGAffineTransformIdentity;[perTransform[@(wid)]getValue:&t];return t;}
static CGRect perWindowBounds(uint32_t wid) {CGRect r=CGRectZero;[perBounds[@(wid)]getValue:&r];return r;}
static BOOL fakeParentOf(uint32_t wid,uint32_t *parent) {NSNumber *value=parentOfWindow[@(wid)];if(!value)return NO;*parent=value.unsignedIntValue;return YES;}
static CGError readTransform(int cid,uint32_t wid,CGAffineTransform *value) {
    (void)cid;(void)wid;transformReads++;*value=perWindowNatives&&perTransform[@(wid)]?perWindowTransform(wid):nativeTransform;
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
        assert(row && !row[@"veil_bare"] && [row[@"layer"]isEqual:matrix(nativeTransform)] && [row[@"bounds"]isEqual:nowBounds]);
    }
    if(requireArrivalPlacedBeforeTransform&&perTransform[@(wid)]){
        // An arrival placement: the window's original transform, bounds and alpha are on disk first, and nothing but the transform is owed.
        NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
        NSDictionary *row=nil;for(NSDictionary *candidate in saved[@"windows"])if([candidate[@"wid"]unsignedIntValue]==wid)row=candidate;
        CGRect nowBounds=perWindowBounds(wid);
        NSArray *nowBoundsRow=@[@(nowBounds.origin.x),@(nowBounds.origin.y),@(nowBounds.size.width),@(nowBounds.size.height)];
        assert(row && !row[@"veil_bare"] && !row[@"veil_alpha"] && ![row[@"alpha_touched"]boolValue] && [row[@"layer"]isEqual:matrix(perWindowTransform(wid))]
            && [row[@"bounds"]isEqual:nowBoundsRow] && [row[@"state"]isEqual:@"held"]);
    }
    (void)cid;(void)wid;transformWrites++;[nativeLog addObject:@"T"];
    if(perWindowNatives&&perTransform[@(wid)]){if(!ignoreTransformWrites)perTransform[@(wid)]=[NSValue valueWithBytes:&value objCType:@encode(CGAffineTransform)];}
    else if(!ignoreTransformWrites)nativeTransform=value;
    if(moveAfterTransformWrite){moveAfterTransformWrite=NO;nativeBounds.origin.x+=7;} // the window moves between the write and the read of its origin
    if(failSyncAfterTransform){failSyncAfterTransform=NO;failNextSync=YES;}
    if(replaceAfterTransform){replaceAfterTransform=NO;ownerValue++;}
    return 0;
}
static CGError readBounds(int cid,uint32_t wid,CGRect *value) {
    if(perWindowNatives&&perBounds[@(wid)]){*value=perWindowBounds(wid);return boundsStatus;}
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
