// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Arrival veil cases. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.

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

    // The alpha put back is the journalled original, not a constant: an entry holding a fractional original (as a replay
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
