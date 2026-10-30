// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Arrival placement cases. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.
// A child window of a placed root is placed with its root when the window server announces it (v2ArrivalPlace). Substituted native calls, a root
// (42) and a child (43) with their own transforms, bounds and parents, and a suspended queue so that no 500 ms bound fires on its own.
static void arrivalCases(struct dw2_identity who) {
    static dispatch_queue_t suspended;
    dispatch_queue_t savedQueue=v2q;suspended=dispatch_queue_create("dw.arrival.test",DISPATCH_QUEUE_SERIAL);dispatch_suspend(suspended);v2q=suspended;
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;getTransform=readTransform;setTransform=writeTransform;getLayer=readTransform;setLayer=writeTransform;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    fixtureOnly=NO;allowlist=nil;v2ParentOf=fakeParentOf;perWindowNatives=YES;
    struct dw2_restore_reply summary={0};uint8_t status=255;
    // The root as the application made it (768,200, 520x452) and the window it opens (869,262, 223x202), the way a context menu is.
    CGAffineTransform rootNative=CGAffineTransformMake(1,0,0,1,-768,-200),childNative=CGAffineTransformMake(1,0,0,1,-869,-262);
    // The shell's placement of the root at zoom 0.5, drawn at (898,512), and what its family gives the child: the same matrix, moved by the offset (101,62).
    struct dw2_record rootFrame={.id=who,.m={2,0,0,2,-1796,-1024}};
    CGAffineTransform childPlaced=CGAffineTransformMake(2,0,0,2,-1796-101,-1024-62);
    struct dw2_record childFrame={.id=who,.m={2,0,0,2,-1796-101,-1024-62}};childFrame.id.wid=43;
    #define ARRIVAL_RESET(layer) do{ clearTables();nativeLog=[NSMutableArray array];rows=veilRows(layer,NO);nativeAlpha=journalAlpha=1;transformWrites=alphaWrites=0;failNextSync=NO;replaceOnSync=NO;\
        ownerValue=7;goneWID=0;processPID=123;processUID=getuid();boundsStatus=0;transformReadStatus=0;ignoreTransformWrites=NO;ignoreAlphaWrites=NO;requireArrivalPlacedBeforeTransform=NO;\
        atomic_store(&v2VeilOn,true);atomic_store(&v2VeilClient,999);\
        perTransform=[@{@42:[NSValue valueWithBytes:&rootNative objCType:@encode(CGAffineTransform)],@43:[NSValue valueWithBytes:&childNative objCType:@encode(CGAffineTransform)]}mutableCopy];\
        perBounds=[@{@42:[NSValue valueWithRect:NSMakeRect(768,200,520,452)],@43:[NSValue valueWithRect:NSMakeRect(869,262,223,202)]}mutableCopy];\
        parentOfWindow=[@{@42:@0,@43:@42}mutableCopy];\
        v2Apply(&rootFrame,1,&status);assert(status==DW2_APPLIED);[nativeLog removeAllObjects];transformWrites=0; }while(0)
    // The perBounds above hold an NSRect; the reader wants a CGRect (the same bytes on arm64).
    static_assert(sizeof(NSRect)==sizeof(CGRect),"NSRect and CGRect share a layout");

    // A child of a placed root, at level 101 (a context menu): journalled with its original first, then the root's placement with the offset,
    // and nothing else written (not its alpha, which the application animates itself).
    ARRIVAL_RESET(101);requireArrivalPlacedBeforeTransform=YES;uint64_t writesBefore=atomic_load(&v2JournalWrites);
    v2Veil(43);
    DW2Entry *child=v2Table[@43];
    assert(child && child->arrival && child->state==DW2_HELD && !child->veiled && !child->veilBare && !child->veilAlpha && child->hasAlpha && !child->alphaTouched && child->alpha==1);
    assert(v2SameTransform(child->layer,childNative) && CGRectEqualToRect(child->bounds,CGRectMake(869,262,223,202)));
    assert(v2SameTransform(perWindowTransform(43),childPlaced) && v2SameTransform(child->appliedTransform,childPlaced) && child->appliedTransformKnown);
    assert([nativeLog isEqualToArray:(@[@"T"])] && !alphaWrites && atomic_load(&v2JournalWrites)==writesBefore+1);
    assert(v2SameTransform(perWindowTransform(42),CGAffineTransformMake(2,0,0,2,-1796,-1024))); // the root itself is untouched
    requireArrivalPlacedBeforeTransform=NO;
    // The same window announced again is the shell's (known to the table): no second placement, no write.
    [nativeLog removeAllObjects];v2Veil(43);assert(!nativeLog.count && atomic_load(&v2JournalWrites)==writesBefore+1);

    // The shell's frame naming it claims it, and writes nothing when it asks for the same placement; the bound then ends nothing.
    unsigned placedWrites=transformWrites;v2Apply(&childFrame,1,&status);assert(status==DW2_APPLIED && !child->arrival && !nativeLog.count && transformWrites==placedWrites);
    v2ArrivalExpire(child);assert(v2Table[@43]==child && child->state==DW2_HELD && !nativeLog.count);
    // A frame that asks for another placement moves it (the camera moved): the shell's value wins.
    childFrame.m[4]-=40;v2Apply(&childFrame,1,&status);assert(status==DW2_APPLIED && perWindowTransform(43).tx==childPlaced.tx-40);childFrame.m[4]+=40;

    // Level 0 and a fading alpha are placed the same way (the veil holds neither a window the application fades nor one above level 0).
    ARRIVAL_RESET(0);nativeAlpha=.3f;v2Veil(43);child=v2Table[@43];
    assert(child && child->arrival && !child->veiled && child->alpha==.3f && !child->alphaTouched && !alphaWrites && v2SameTransform(perWindowTransform(43),childPlaced));
    // A window nobody names is released by the bound: the original transform back, by the ordinary release, nothing else written.
    [nativeLog removeAllObjects];v2ArrivalExpire(child);
    assert(!v2Table[@43] && v2Released[@43] && v2SameTransform(perWindowTransform(43),childNative) && [nativeLog isEqualToArray:(@[@"T"])] && !alphaWrites && v2Table[@42]);
    // ... and a window the helper released is not placed again however often it is announced.
    [nativeLog removeAllObjects];for(int announcements=0;announcements<3;announcements++)v2Veil(43);assert(!nativeLog.count && !v2Table[@43]);
    // The end of the veil (the session, or VEIL mode 0) releases it too, and leaves the root with the shell.
    ARRIVAL_RESET(101);v2Veil(43);assert(v2Table[@43]->arrival);v2VeilRelease();
    assert(!v2Table[@43] && v2Released[@43] && v2SameTransform(perWindowTransform(43),childNative) && v2Table[@42] && v2Table[@42]->state==DW2_HELD);
    // A restore record for it releases it at once; the placement is undone.
    ARRIVAL_RESET(101);v2Veil(43);{struct dw2_record release={.id=who,.flags=DW2_RECORD_RESTORE};release.id.wid=43;v2Apply(&release,1,&status);
        assert(status==DW2_APPLIED && !v2Table[@43] && v2Released[@43] && v2SameTransform(perWindowTransform(43),childNative));}
    // A window gone before the bound: dropped by the identity logic with no write.
    ARRIVAL_RESET(101);v2Veil(43);child=v2Table[@43];goneWID=43;[nativeLog removeAllObjects];v2ArrivalExpire(child);assert(!v2Table[@43] && !nativeLog.count);goneWID=0;

    // Everything else is left alone: nothing is written for it and no record of it is made.
    struct {const char *name;void (^arrange)(void);} refusals[]={
        {"no parent (the global menu bar's menus, status items, an application's own window)",^{[parentOfWindow removeObjectForKey:@43];}},
        {"a parent query that is not exact",^{parentOfWindow=[@{@42:@0}mutableCopy];}},
        {"a root the shell has not placed",^{[v2Table removeObjectForKey:@42];}},
        {"a parent that is no window of the table",^{parentOfWindow[@43]=@44;parentOfWindow[@44]=@0;}},
        {"a cycle",^{parentOfWindow[@43]=@44;parentOfWindow[@44]=@43;}},
        {"a root whose placement is not the one applied",^{perTransform[@42]=[NSValue valueWithBytes:&(CGAffineTransform){2,0,0,2,-1700,-1000} objCType:@encode(CGAffineTransform)];}},
        {"a root being released",^{v2Table[@42]->state=DW2_RESTORING;}},
        {"a root only hidden by the veil",^{v2Table[@42]->veilBare=YES;}},
        {"a root with no applied transform",^{v2Table[@42]->appliedTransformKnown=NO;}},
        {"a root that is not the window's process",^{v2Table[@42]->who.pid=124;}},
        {"a root of another connection",^{v2Table[@42]->owner=8;}},
        {"a placement that is the window's own (the root drawn where it is)",^{struct dw2_record identity={.id=who,.m={1,0,0,1,-768,-200}};uint8_t applied=255;v2Apply(&identity,1,&applied);assert(applied==DW2_APPLIED);}},
        {"no veil asked",^{atomic_store(&v2VeilOn,false);}},
        {"the client's own process",^{atomic_store(&v2VeilClient,123);}},
        {"another user's window",^{processUID=getuid()+1;}},
        {"a root with a rotation",^{perTransform[@42]=[NSValue valueWithBytes:&(CGAffineTransform){2,1,0,2,-1796,-1024} objCType:@encode(CGAffineTransform)];v2Table[@42]->appliedTransform=(CGAffineTransform){2,1,0,2,-1796,-1024};}},
        {"unreadable bounds",^{boundsStatus=1000;}},
    };
    for(unsigned i=0;i<sizeof(refusals)/sizeof(*refusals);i++){
        ARRIVAL_RESET(101);refusals[i].arrange();[nativeLog removeAllObjects];uint64_t before=atomic_load(&v2JournalWrites);unsigned writesNow=transformWrites;
        // A window with no parent is also a veil candidate at level 0: leave the level at 101 so only this path is judged.
        v2Veil(43);
        if(v2Table[@43]||v2Released[@43]||transformWrites!=writesNow||alphaWrites||atomic_load(&v2JournalWrites)!=before||nativeLog.count){fprintf(stderr,"arrival placed when %s\n",refusals[i].name);abort();}
    }

    // No record, no write: a journal that cannot be written changes nothing, and is retried.
    ARRIVAL_RESET(101);failNextSync=YES;v2Veil(43);
    assert(!v2Table[@43] && !transformWrites && v2JournalStale && v2SameTransform(perWindowTransform(43),childNative));
    v2Restore(@"arrival journal retry",YES,nil,&summary);assert(summary.journal_persisted && !v2JournalStale);
    // A transform that does not take is not kept: released at once (read back unchanged, so nothing to put back).
    ARRIVAL_RESET(101);ignoreTransformWrites=YES;v2Veil(43);
    assert(!v2Table[@43] && v2Released[@43] && transformWrites>=1 && v2SameTransform(perWindowTransform(43),childNative));ignoreTransformWrites=NO;
    // The identity of the window is fenced again after the write: a reused window number gets nothing and is left alone.
    ARRIVAL_RESET(101);replaceAfterTransform=YES;v2Veil(43);assert(!v2Table[@43] || v2Table[@43]->state==DW2_RESTORING);replaceAfterTransform=NO;ownerValue=7;
    // Replay of a writer that died with the placement undoes it: the journal row is an ordinary one.
    ARRIVAL_RESET(101);v2Veil(43);assert(v2Table[@43]->arrival);
    {NSMutableDictionary *dead=[readJournal()mutableCopy];dead[@"server_pid"]=@456;dead[@"server_birth_sec"]=@50;dead[@"server_birth_usec"]=@0;
     NSDictionary *survivor=v2WriterIdentity;writeJSON(@"v2-journal.json",dead);clearTables();
     assert(v2LoadJournal(nil) && v2SameTransform(perWindowTransform(43),childNative) && v2SameTransform(perWindowTransform(42),childNative)==NO && v2WriterSame(readJournal(),survivor));}

    v2q=savedQueue;clearTables();atomic_store(&v2VeilOn,false);atomic_store(&v2VeilClient,0);perWindowNatives=NO;perTransform=perBounds=nil;parentOfWindow=nil;v2ParentOf=v2NativeParentOf;nativeLog=nil;
    #undef ARRIVAL_RESET
    puts("PASS: arrival placement gives a child of a placed root, at any level and alpha, the root's placement plus its offset with a journalled original before the write, hands it to the shell's first frame, releases it by bound, decline, end of veil and replay, and leaves every window without such a parent, root or placement alone; substituted calls only");
}
