// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Space membership cases. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.
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
