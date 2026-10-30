// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Restore re-basing cases. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.

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
