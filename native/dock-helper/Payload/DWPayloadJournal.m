// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation. Private ABI declarations cross-checked against
// yabai (MIT), https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/osax/payload.m; its notice is native/app/Resources/YABAI-NOTICE.txt.
// The arrival veil (v2Veil below) adapts an idea and a technique of Sunlight,
// https://github.com/spacefarm-digital/sunlight commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm): that a window an
// application opens must not be seen at its native place before the canvas has placed it
// (LiveWindows/README.md:129 and LiveWindows/osax/sunbeam.h:40-51, which keep the canvas and its
// windows one window level up), and the window server's own announcement of it, SkyLight
// connection notification 1325 with the Space id (u64) then the window id (u32) as payload,
// registered with SLSRegisterConnectionNotifyProc (Sources/Canvas/RealWindows/WindowServerEvents.swift:4-15,
// 36-55 and 73-85). The level lift is not taken: here the window is held at alpha 0 instead.
// Private ABI declarations below are cross-checked against yabai (MIT),
// https://github.com/asmvik/yabai commit dd845723416f5fe92af49fad5ebab00369e07edd; its notice is native/app/Resources/YABAI-NOTICE.txt.
// The journal: every original is written durably (no-follow staging, fsync, rename) before anything is changed, and a journal an
// earlier helper left is validated, decoded and recovered, with writer handoff, before the listener accepts a client.
// Moved verbatim from native/privileged/payload.m (37b27b1), lines 487-522, 643, 1439-1638. #imported by DWPayload.m in a fixed order; never compiled alone.
// Edited since the move: schema 4, the original is the field layer instead of the absolute transform.

// Durable no-follow staging and rename; original values survive every frame.
static NSDictionary *v2JournalEntry(DW2Entry *e,NSString *state) {
    NSMutableDictionary *row=[@{@"pid":@(e->who.pid),@"birth_sec":@(e->who.birth_sec),@"birth_usec":@(e->who.birth_usec),@"wid":@(e->who.wid),@"owner":@(e->owner),
        @"layer":matrix(e->layer),@"alpha":e->hasAlpha ? @(e->alpha) : (id)NSNull.null,@"alpha_touched":@(e->alphaTouched),
        @"bounds":@[@(e->bounds.origin.x),@(e->bounds.origin.y),@(e->bounds.size.width),@(e->bounds.size.height)],@"state":state}mutableCopy];
    if(e->sublevelTouched)row[@"original_sublevel"]=@(e->originalSublevel);
    if(e->veilBare)row[@"veil_bare"]=@YES;
    if(e->veilAlpha)row[@"veil_alpha"]=@YES;
    if(e->originalSpace)row[@"original_space"]=@{@"id":@(e->originalSpace),@"display":e->originalSpaceDisplay,@"pending_target":@(e->pendingSpace)};
    return row;
}
static BOOL v2Persist(void) {
    if(!v2WriterIdentity || v2Table.count+v2Released.count>DW2_MAX_TABLE)return NO;
    NSMutableArray *windows=[NSMutableArray array],*released=[NSMutableArray array];
    BOOL restoring=NO;
    for(NSNumber *wid in [v2Table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DW2Entry *e=v2Table[wid];
        if(e->state==DW2_RESTORING)restoring=YES;
        [windows addObject:v2JournalEntry(e,e->reattaching ? @"reattaching" : e->state==DW2_HELD ? @"held" : @"restoring")];
    }
    for(NSNumber *wid in [v2Released.allKeys sortedArrayUsingSelector:@selector(compare:)])[released addObject:v2JournalEntry(v2Released[wid],@"released")];
    NSMutableDictionary *journal=[v2WriterIdentity mutableCopy];
    [journal addEntriesFromDictionary:@{@"v":@4,@"generation":@(v2Generation+1),@"state":!windows.count ? @"empty" : restoring ? @"restoring" : @"holding",
        @"windows":windows,@"released_windows":released,@"last_restore":v2LastRestore ?: (id)NSNull.null}];
    NSData *data=[NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingPrettyPrinted error:NULL];
    if(!data)return NO;
    int fd=openat(directoryFD,"v2-journal.next",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return NO;
    BOOL ok=writeAll(fd,data.bytes,data.length) && fsync(fd)==0;
    if(close(fd))ok=NO;
    if(ok)ok=renameat(directoryFD,"v2-journal.next",directoryFD,"v2-journal.json")==0 && fsync(directoryFD)==0;
    if(!ok){unlinkat(directoryFD,"v2-journal.next",0);return NO;}
    v2Generation++;atomic_fetch_add(&v2JournalWrites,1);
    return YES;
}

static void v2Restore(NSString *reason,BOOL retry,NSMutableData *results,struct dw2_restore_reply *summary);
// A journal left by an instance that died holding windows. Each recorded window is
// restored only if its whole recorded identity still resolves to the same process
// instance and passes this instance's scope; the value written is the one captured
// before any helper touched it. A bare window number is never trusted.
static BOOL v2Integer(id value,uint64_t minimum,uint64_t maximum) {
    return isNumber(value) && !CFNumberIsFloatType((__bridge CFNumberRef)value)
        && [value compare:@(minimum)]!=NSOrderedAscending && [value compare:@(maximum)]!=NSOrderedDescending;
}
static BOOL v2Boolean(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID(); }
static BOOL v2LastRestoreValid(id value) {
    if(value==NSNull.null)return YES;
    if(!dw_exact_keys(value,@[@"reason",@"results"]) || ![value[@"reason"]isKindOfClass:NSString.class] || ![value[@"reason"]length]
        || ![value[@"results"]isKindOfClass:NSArray.class] || [value[@"results"]count]>DW2_MAX_TABLE)return NO;
    NSMutableSet *windows=[NSMutableSet set];
    for(NSDictionary *r in value[@"results"]) {
        if(![r isKindOfClass:NSDictionary.class])return NO;
        // Diagnostics never authorize writes and cannot make valid originals
        // unrecoverable. Keep validating the original restoration receipt only.
        NSMutableDictionary *fields=[r mutableCopy];[fields removeObjectForKey:@"diagnostic"];
        if(!dw_exact_keys(fields,@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"outcome",@"set_status"])
            || !v2Integer(r[@"pid"],1,INT_MAX) || !v2Integer(r[@"birth_sec"],1,UINT64_MAX) || !v2Integer(r[@"birth_usec"],0,999999)
            || !v2Integer(r[@"wid"],1,UINT32_MAX) || !isNumber(r[@"set_status"]) || CFNumberIsFloatType((__bridge CFNumberRef)r[@"set_status"])
            || [r[@"set_status"]compare:@(INT_MIN)]==NSOrderedAscending || [r[@"set_status"]compare:@(INT_MAX)]==NSOrderedDescending
            || ![@[@"restored",@"gone",@"pending"]containsObject:r[@"outcome"]] || [windows containsObject:r[@"wid"]])return NO;
        [windows addObject:r[@"wid"]];
    }
    return YES;
}
// Schema 4 preserves released originals for a later, explicitly authorized connection handoff, and records each original as the
// window's placement-1 layer (field layer) instead of the absolute matrix schema 3 held; only schema 4 is accepted, an older journal
// is not migrated (the launcher archives it and starts fresh, scripts/native-desktop-launcher.sh).
static NSArray *v2WriterKeys(void) {
    return @[@"server_pid",@"server_birth_sec",@"server_birth_usec",@"server_uid",@"boot_uuid"];
}
static BOOL v2WriterValid(NSDictionary *value) {
    return v2Integer(value[@"server_pid"],1,INT_MAX) && v2Integer(value[@"server_birth_sec"],1,UINT64_MAX)
        && v2Integer(value[@"server_birth_usec"],0,999999) && v2Integer(value[@"server_uid"],0,UINT32_MAX)
        && dw_boot_uuid_valid(value[@"boot_uuid"]);
}
static NSDictionary *v2CurrentWriterIdentity(void) {
    struct proc_bsdinfo process={0};char boot[37]={0};size_t length=sizeof(boot);
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process)
        || process.pbi_uid!=getuid() || sysctlbyname("kern.bootsessionuuid",boot,&length,NULL,0) || length!=sizeof(boot)
        || boot[36]!='\0' || !process.pbi_start_tvsec)return nil;
    // Unlike calendar boottime, this kernel identity does not move when the
    // wall clock changes. Persist only its exact canonical uppercase spelling.
    NSString *bootUUID=[[NSString alloc]initWithBytes:boot length:36 encoding:NSASCIIStringEncoding];
    if(!dw_boot_uuid_valid(bootUUID))return nil;
    return @{@"server_pid":@(getpid()),@"server_birth_sec":@(process.pbi_start_tvsec),@"server_birth_usec":@(process.pbi_start_tvusec),
        @"server_uid":@(getuid()),@"boot_uuid":bootUUID};
}
static BOOL v2WriterSame(NSDictionary *a,NSDictionary *b) {
    for(NSString *key in v2WriterKeys())if(![a[key]isEqual:b[key]])return NO;
    return YES;
}
static BOOL v2OldWriterDead(NSDictionary *writer) {
    int pid=[writer[@"server_pid"]intValue];struct proc_bsdinfo process={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process))
        return process.pbi_start_tvsec!=[writer[@"server_birth_sec"]unsignedLongLongValue]
            || process.pbi_start_tvusec!=[writer[@"server_birth_usec"]unsignedLongLongValue];
    // An inaccessible process is not dead. ESRCH is affirmative kernel absence.
    errno=0;return kill(pid,0)<0 && errno==ESRCH;
}
static BOOL v2RetiredWriter(NSDictionary *writer) {
    return [writer[@"server_uid"]isEqual:v2WriterIdentity[@"server_uid"]]
        && [writer[@"boot_uuid"]isEqual:v2WriterIdentity[@"boot_uuid"]]
        && !v2WriterSame(writer,v2WriterIdentity) && v2OldWriterDead(writer);
}
static BOOL v2RecoveryConfigValid(NSDictionary *config) {
    NSArray *keys=@[@"recovery_source_sha256",@"recovery_server_pid",@"recovery_server_birth_sec",@"recovery_server_birth_usec",
        @"recovery_server_uid",@"recovery_boot_uuid"];
    NSUInteger count=0;
    for(NSString *key in config)if([key hasPrefix:@"recovery_"]){if(![keys containsObject:key])return NO;count++;}
    if(!count)return YES;
    NSString *hash=config[@"recovery_source_sha256"];
    if(count!=keys.count || ![hash isKindOfClass:NSString.class] || hash.length!=64)return NO;
    for(NSUInteger i=0;i<hash.length;i++){unichar c=[hash characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return NO;}
    NSMutableDictionary *writer=[NSMutableDictionary dictionary];
    for(NSString *key in v2WriterKeys())writer[key]=config[[@"recovery_"stringByAppendingString:key]];
    return v2WriterValid(writer);
}
static NSData *v2ReadJournal(const char *name,BOOL *absent) {
    *absent=NO;int fd=openat(directoryFD,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0){*absent=errno==ENOENT;return nil;}
    struct stat st;
    if(fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&0777)!=0600
        || st.st_size<=0 || st.st_size>4*1024*1024){close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];char chunk[4096];ssize_t n;
    for(;;){n=read(fd,chunk,sizeof(chunk));if(n<0&&errno==EINTR)continue;if(n<=0)break;
        [data appendBytes:chunk length:n];if(data.length>4*1024*1024){n=-1;break;}}
    close(fd);return n==0 && data.length==(NSUInteger)st.st_size ? data : nil;
}
static BOOL v2RemoveStaging(void) {
    struct stat stage;
    if(fstatat(directoryFD,"v2-journal.next",&stage,AT_SYMLINK_NOFOLLOW)==0) {
        if(!S_ISREG(stage.st_mode) || stage.st_uid!=getuid() || (stage.st_mode&0777)!=0600)return NO;
        return !unlinkat(directoryFD,"v2-journal.next",0) && !fsync(directoryFD);
    }
    return errno==ENOENT;
}
static DW2Entry *v2DecodeEntry(NSDictionary *w,BOOL released) {
    NSArray *keys=@[@"pid",@"birth_sec",@"birth_usec",@"wid",@"owner",@"layer",@"alpha",@"alpha_touched",@"bounds",@"state"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"original_space"])keys=[keys arrayByAddingObject:@"original_space"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"original_sublevel"])keys=[keys arrayByAddingObject:@"original_sublevel"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"veil_bare"])keys=[keys arrayByAddingObject:@"veil_bare"];
    if([w isKindOfClass:NSDictionary.class]&&w[@"veil_alpha"])keys=[keys arrayByAddingObject:@"veil_alpha"];
    if(!dw_exact_keys(w,keys)
        || !v2Integer(w[@"pid"],1,INT_MAX) || !v2Integer(w[@"birth_sec"],1,UINT64_MAX) || !v2Integer(w[@"birth_usec"],0,999999)
        || !v2Integer(w[@"wid"],1,UINT32_MAX) || !v2Integer(w[@"owner"],1,INT_MAX) || !v2Boolean(w[@"alpha_touched"])
        || !(released ? [w[@"state"]isEqual:@"released"] : [@[@"held",@"restoring",@"reattaching"]containsObject:w[@"state"]]))return nil;
    NSArray *t=w[@"layer"],*b=w[@"bounds"];
    if(![t isKindOfClass:NSArray.class] || t.count!=6 || ![b isKindOfClass:NSArray.class] || b.count!=4)return nil;
    for(id value in [t arrayByAddingObjectsFromArray:b])if(!isNumber(value) || !isfinite([value doubleValue]))return nil;
    DW2Entry *e=[DW2Entry new];
    e->who=(struct dw2_identity){.pid=[w[@"pid"]intValue],.wid=[w[@"wid"]unsignedIntValue],.birth_sec=[w[@"birth_sec"]unsignedLongLongValue],.birth_usec=[w[@"birth_usec"]unsignedLongLongValue]};
    e->owner=[w[@"owner"]intValue];e->state=DW2_RESTORING;e->reattaching=[w[@"state"]isEqual:@"reattaching"];
    e->layer=CGAffineTransformMake([t[0]doubleValue],[t[1]doubleValue],[t[2]doubleValue],[t[3]doubleValue],[t[4]doubleValue],[t[5]doubleValue]);
    e->bounds=CGRectMake([b[0]doubleValue],[b[1]doubleValue],[b[2]doubleValue],[b[3]doubleValue]);
    if(!finiteMatrix(e->layer) || !v2FiniteRect(e->bounds))return nil;
    if(w[@"alpha"]!=NSNull.null) {
        if(!isNumber(w[@"alpha"]) || !isfinite([w[@"alpha"]doubleValue]) || [w[@"alpha"]doubleValue]<0 || [w[@"alpha"]doubleValue]>1)return nil;
        e->alpha=[w[@"alpha"]floatValue];e->hasAlpha=YES;
    }
    e->alphaTouched=[w[@"alpha_touched"]boolValue];
    if(e->alphaTouched && (!e->hasAlpha || !setAlpha || !getAlpha))return nil;
    // Marks of an arrival veil: only an active, never-released entry has them, and the alpha mark needs its alpha obligation.
    if(w[@"veil_bare"]||w[@"veil_alpha"]){
        if((w[@"veil_bare"]&&(!v2Boolean(w[@"veil_bare"])||![w[@"veil_bare"]boolValue]))||(w[@"veil_alpha"]&&(!v2Boolean(w[@"veil_alpha"])||![w[@"veil_alpha"]boolValue]||!e->alphaTouched))||released)return nil;
        e->veilBare=[w[@"veil_bare"]boolValue];e->veilAlpha=[w[@"veil_alpha"]boolValue];
    }
    id sublevel=w[@"original_sublevel"];
    if(sublevel){
        // Unlike identity fields, a signed sublevel can be negative.
        if(!isNumber(sublevel)||CFNumberIsFloatType((__bridge CFNumberRef)sublevel)
            ||[sublevel compare:@(INT_MIN)]==NSOrderedAscending||[sublevel compare:@(INT_MAX)]==NSOrderedDescending||!v2SublevelAPI())return nil;
        e->originalSublevel=[sublevel intValue];e->sublevelTouched=YES;
    }
    NSDictionary *space=w[@"original_space"];
    if(space) {
        if(!dw_exact_keys(space,@[@"id",@"display",@"pending_target"])||!v2Integer(space[@"id"],1,UINT64_MAX)
            ||!v2Integer(space[@"pending_target"],0,UINT64_MAX)||!dw_boot_uuid_valid(space[@"display"])
            ||(released&&[space[@"pending_target"]unsignedLongLongValue]))return nil;
        e->originalSpace=[space[@"id"]unsignedLongLongValue];e->originalSpaceDisplay=space[@"display"];
        e->pendingSpace=[space[@"pending_target"]unsignedLongLongValue];
    }
    return e;
}
static NSDictionary *v2DecodeJournal(NSData *data,NSMutableDictionary *active,NSMutableDictionary *released) {
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *keys=[v2WriterKeys()arrayByAddingObjectsFromArray:@[@"v",@"generation",@"state",@"windows",@"released_windows",@"last_restore"]];
    if(!dw_exact_keys(journal,keys) || !v2Integer(journal[@"v"],4,4) || !v2WriterValid(journal) || !v2Integer(journal[@"generation"],0,UINT64_MAX-1)
        || ![journal[@"windows"]isKindOfClass:NSArray.class] || ![journal[@"released_windows"]isKindOfClass:NSArray.class]
        || [journal[@"windows"]count]+[journal[@"released_windows"]count]>DW2_MAX_TABLE || !v2LastRestoreValid(journal[@"last_restore"]))return nil;
    BOOL restoring=NO;
    for(NSDictionary *w in journal[@"windows"]) {
        DW2Entry *e=v2DecodeEntry(w,NO);if(!e || active[@(e->who.wid)])return nil;
        restoring|=![w[@"state"]isEqual:@"held"];active[@(e->who.wid)]=e;
    }
    for(NSDictionary *w in journal[@"released_windows"]) {
        DW2Entry *e=v2DecodeEntry(w,YES);if(!e || active[@(e->who.wid)] || released[@(e->who.wid)])return nil;
        released[@(e->who.wid)]=e;
    }
    NSString *state=!active.count ? @"empty" : restoring ? @"restoring" : @"holding";
    return [journal[@"state"]isEqual:state] ? journal : nil;
}
static BOOL v2LoadJournal(NSDictionary *recovery) {
    BOOL absent=NO;NSData *data=v2ReadJournal("v2-journal.json",&absent);
    if(!data&&!absent)return NO;
    BOOL sourceAbsent=NO;NSData *source=v2ReadJournal("recovery-source.json",&sourceAbsent);
    if(recovery) {
        if(!source || !v2RecoveryConfigValid(recovery))return NO;
        unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(source.bytes,(CC_LONG)source.length,bytes);
        NSMutableString *hash=[NSMutableString stringWithCapacity:64];for(unsigned i=0;i<sizeof(bytes);i++)[hash appendFormat:@"%02x",bytes[i]];
        if(![hash isEqual:recovery[@"recovery_source_sha256"]])return NO;
        NSDictionary *history=v2DecodeJournal(source,[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]);if(!history)return NO;
        for(NSString *key in v2WriterKeys())if(![history[key]isEqual:recovery[[@"recovery_"stringByAppendingString:key]]])return NO;
        if(!v2RetiredWriter(history))return NO;
        // After a second crash the newer committed journal is the sole active
        // authority. Validate historical provenance, but never merge or fall
        // back to it when a newer committed journal is malformed.
        if(absent)data=source;
    }else if(!sourceAbsent)return NO;
    if(!data)return v2RemoveStaging();
    NSMutableDictionary *active=[NSMutableDictionary dictionary],*released=[NSMutableDictionary dictionary];
    NSDictionary *journal=v2DecodeJournal(data,active,released);if(!journal)return NO;
    BOOL handoff=!v2WriterSame(journal,v2WriterIdentity);
    if(handoff) {
        if(!v2RetiredWriter(journal))return NO;
        for(NSNumber *wid in released){DW2Entry *e=released[wid];e->reattaching=YES;active[wid]=e;}
        [released removeAllObjects];
    }
    if(!v2RemoveStaging())return NO;
    v2Generation=recovery && absent ? 0 : [journal[@"generation"]unsignedLongLongValue];
    v2LastRestore=journal[@"last_restore"]==NSNull.null ? nil : journal[@"last_restore"];
    [v2Table addEntriesFromDictionary:active];[v2Released addEntriesFromDictionary:released];v2Count();
    // Commit the new writer's complete recovery obligation before any native
    // setter. Reattaching records retain their stricter guard durably on retry.
    if(handoff && !v2Persist())return NO;
    if(active.count)v2Restore(handoff ? @"connection handoff" : @"startup recovery",NO,nil,NULL);
    return YES;
}
