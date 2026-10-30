// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Original-layer cases on the modelled window server of DWPayloadPlacementTests.m (placement 0 following the native frame, the
// placement-1 layer the helper owns, and an extra placement some other writer holds, which neither a frame's readback nor a restore may depend on); #imported by DWPayloadRestoreIdentityTests.m after
// it, in its fixed order, and never compiled on its own. Replaces the re-basing cases of native/privileged/restore_identity_test.m (37b27b1).
//
// A window's original is its placement-1 layer, written back verbatim and read back as the layer. Measured in the guest: a Finder window
// adopted while the system's open animation still held another placement (catenated [0.999,0,0,1,0.5,-201]) was journalled with that
// catenated matrix as its original, restored to it, left visibly displaced, and after a Dock restart no state the guard accepted matched it,
// so the entry stayed 'reattaching' and the launcher's pending marker blocked every later start. The model proves what the helper asks for
// and accepts, not what the window server then does: that is the guest's to show.
static void layerCasesSetup(void) {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    skyGetPlacement=modelGet;skySetPlacement=modelSet;getTransform=dwReadAbsolute;setTransform=dwWriteAbsolute;getLayer=dwReadLayer;setLayer=dwWriteLayer;
    fixtureOnly=NO;allowlist=nil;ownerValue=7;connectionStatus=0;processPID=123;processUID=getuid();goneWID=0;boundsStatus=0;transformReadStatus=0;perWindowNatives=NO;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
}
// The state a Dock death leaves: the entries the Dock's connection owned are reset to identity (CGXRemoveWindowTransformsForConnection), the
// extra placement belongs to another connection and stays. Then a new helper replaces the retired writer 456 and reads the journal.
static BOOL layerHandoff(NSDictionary *journal) {
    NSMutableDictionary *old=[journal mutableCopy];old[@"server_pid"]=@456;old[@"server_birth_sec"]=@50;old[@"server_birth_usec"]=@0;
    assert(!unlinkat(directoryFD,"v2-journal.json",0)||errno==ENOENT);
    writeJSON(@"v2-journal.json",old);clearTables();oldWriterAlive=NO;
    return v2LoadJournal(nil);
}
static BOOL layerRowsAllSettled(void) {
    for(NSDictionary *row in readJournal()[@"windows"])if(![row[@"state"]isEqual:@"held"])return NO;
    return YES;
}
static CGAffineTransform requestedFor(struct dw2_record frame) { return CGAffineTransformMake(frame.m[0],frame.m[1],frame.m[2],frame.m[3],frame.m[4],frame.m[5]); }
static void layerCases(struct dw2_identity who) {
    layerCasesSetup();
    CGRect savedBounds=nativeBounds;CGAffineTransform savedTransform=nativeTransform;
    struct dw2_restore_reply summary={0};uint8_t status=255;
    struct dw2_record frame={.id=who,.flags=0,.m={.5,0,0,.5,-106.685,-61.37}};
    CGAffineTransform opening=CGAffineTransformMake(0.999,0,0,1,0.5,-201),natural=CGAffineTransformMake(1,0,0,1,-25,-35);
    NSArray *identityRow=matrix(CGAffineTransformIdentity);

    // (i) Adoption while another placement is non-natural: the original is the layer (the identity), the journal says so, and restore
    // writes the identity at placement 1 and reads the layer back, whatever the extra placement holds, so it is not pending and not
    // restored "to" the animation's contribution; once the animation is over the window is natural.
    clearTables();modelReset(CGRectMake(25,35,300,200));modelExtra=opening;
    assert(!v2SameTransform(modelCatenated(),natural));
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && !modelWrites[0] && CGAffineTransformIsIdentity(v2Table[@42]->layer)
        && !v2SameTransform(modelCatenated(),requestedFor(frame))); // applied although the drawn matrix carries the other writer's placement
    assert([readJournal()[@"windows"][0][@"layer"]isEqual:identityRow] && !readJournal()[@"windows"][0][@"transform"]);
    v2Restore(@"restore with the system animation still on another placement",NO,nil,&summary);
    assert(!summary.pending && !v2Table.count && v2Released[@42] && !modelWrites[0] && modelWrites[1]==2 && modelIdentityLayer());
    assert(CGAffineTransformEqualToTransform(modelExtra,opening)); // never touched
    modelExtra=CGAffineTransformIdentity;
    assert(v2SameTransform(modelCatenated(),natural) && !modelBaseSet);
    assert([readJournal()[@"released_windows"][0][@"layer"]isEqual:identityRow]);

    // The window server's own state moves while the window is held: the application moves its window and the animation ends. The
    // layer was not in either, so restoration needs no re-basing and leaves the window natural where it now is.
    clearTables();modelReset(CGRectMake(25,35,300,200));modelExtra=opening;
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    nativeBounds.origin.x+=140;modelExtra=CGAffineTransformIdentity;
    v2Restore(@"restore after a native move",NO,nil,&summary);
    assert(!summary.pending && modelIdentityLayer() && !modelWrites[0] && v2SameTransform(modelCatenated(),CGAffineTransformMake(1,0,0,1,-165,-35)));

    // An original layer that is not the identity (another writer's) is written back exactly, and read back as the layer.
    clearTables();modelReset(CGRectMake(25,35,300,200));modelLayer=CGAffineTransformMake(1,0,0,1,3,4);
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && v2SameTransform(v2Table[@42]->layer,CGAffineTransformMake(1,0,0,1,3,4)));
    assert([readJournal()[@"windows"][0][@"layer"]isEqual:matrix(CGAffineTransformMake(1,0,0,1,3,4))]);
    v2Restore(@"restore of a non-identity original layer",NO,nil,&summary);
    assert(!summary.pending && v2SameTransform(modelLayer,CGAffineTransformMake(1,0,0,1,3,4)) && !modelWrites[0]);

    // A restore that the window server does not take is verified on the layer and stays pending, with the layer in its diagnostic.
    clearTables();modelReset(CGRectMake(25,35,300,200));
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    modelIgnoreLayer=YES;v2Restore(@"layer not taken",NO,nil,&summary);
    NSDictionary *diagnostic=v2LastRestore[@"results"][0][@"diagnostic"];
    assert(summary.pending==1 && [diagnostic[@"layer_matches"]isEqual:@NO] && [diagnostic[@"saved_layer"]isEqual:identityRow] && v2LastRestoreValid(v2LastRestore));
    modelIgnoreLayer=NO;v2Restore(@"layer taken",YES,nil,&summary);assert(!summary.pending && !v2Table.count && modelIdentityLayer());

    // (ii) Recovery after a Dock reset converges. The Dock died holding the window placed (layer scaled); its entries were reset to the
    // identity, the animation placement was not. The new helper reads the journal of the retired writer and puts the window back.
    clearTables();modelReset(CGRectMake(25,35,300,200));modelExtra=opening;
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED && !modelIdentityLayer());
    NSDictionary *journal=readJournal();
    modelLayer=CGAffineTransformIdentity; // the Dock's connection died
    assert(layerHandoff(journal));
    assert(!v2Table.count && !atomic_load(&v2Restoring) && !atomic_load(&v2Held) && v2Released.count==1 && modelIdentityLayer() && !modelWrites[0]);
    assert([readJournal()[@"state"]isEqual:@"empty"] && ![readJournal()[@"windows"]count] && layerRowsAllSettled());
    assert([v2LastRestore[@"results"][0][@"outcome"]isEqual:@"restored"]);

    // The same window, already restored and retained as a released original when the Dock died (the guest's failing case: the entry
    // became 'reattaching' and no accepted state matched it). The layer it holds is the identity again, which is the original: it
    // converges to restored at once, with the animation placement still non-natural, and no entry is left to retry.
    clearTables();modelReset(CGRectMake(25,35,300,200));modelExtra=opening;
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    v2Restore(@"restored before the Dock died",NO,nil,&summary);assert(!summary.pending && v2Released.count==1);
    journal=readJournal();assert([journal[@"released_windows"]count]==1);
    modelLayer=CGAffineTransformIdentity;
    assert(layerHandoff(journal));
    assert(!v2Table.count && !atomic_load(&v2Restoring) && v2Released.count==1 && !v2Released[@42]->reattaching && modelIdentityLayer() && !modelWrites[0]);
    assert([readJournal()[@"state"]isEqual:@"empty"] && ![readJournal()[@"windows"]count]);
    assert(!v2JournalStale && [v2LastRestore[@"results"][0][@"outcome"]isEqual:@"restored"]);

    // A window whose original layer was not the identity comes back to it after the reset.
    clearTables();modelReset(CGRectMake(25,35,300,200));modelLayer=CGAffineTransformMake(1,0,0,1,3,4);
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    journal=readJournal();modelLayer=CGAffineTransformIdentity;
    assert(layerHandoff(journal));
    assert(!v2Table.count && !atomic_load(&v2Restoring) && v2SameTransform(modelLayer,CGAffineTransformMake(1,0,0,1,3,4)));

    // A layer someone else has written since is not the helper's to undo: the guard still refuses it and the entry stays reattaching.
    clearTables();modelReset(CGRectMake(25,35,300,200));
    v2Apply(&frame,1,&status);v2Restore(@"released",NO,nil,&summary);journal=readJournal();
    modelLayer=CGAffineTransformMake(1,0,0,1,9,9);unsigned writes=modelWrites[1];
    assert(layerHandoff(journal));
    assert(v2Table.count==1 && v2Table[@42]->reattaching && atomic_load(&v2Restoring)==1 && modelWrites[1]==writes);
    modelLayer=CGAffineTransformIdentity;v2Restore(@"reset afterwards",YES,nil,&summary);
    assert(!summary.pending && !v2Table.count);

    // A released window the application or a drag moved after its release is natural where it now is: the layer does not depend on the
    // frame, so the Dock's death converges it to restored instead of leaving it reattaching on the stale retained bounds.
    clearTables();modelReset(CGRectMake(25,35,300,200));
    v2Apply(&frame,1,&status);v2Restore(@"released, then moved",NO,nil,&summary);assert(!summary.pending && v2Released.count==1);
    journal=readJournal();nativeBounds.origin.x+=40;modelLayer=CGAffineTransformIdentity;
    assert(layerHandoff(journal));
    assert(!v2Table.count && !atomic_load(&v2Restoring) && v2Released.count==1 && !v2Released[@42]->reattaching && modelIdentityLayer() && !modelWrites[0]);
    assert([readJournal()[@"state"]isEqual:@"empty"] && [v2LastRestore[@"results"][0][@"outcome"]isEqual:@"restored"]);
    nativeBounds=savedBounds;

    // (iii) A journal of the previous schema is refused whole: it names the absolute original in a field this schema no longer has, so
    // its rows cannot be decoded, and nothing is written. The launcher archives such a journal and starts fresh
    // (tests/e2e/native-launcher.sh); the payload leaves the file as it found it.
    clearTables();modelReset(CGRectMake(25,35,300,200));
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    journal=readJournal();assert([journal[@"v"]isEqual:@4]);
    NSMutableDictionary *previous=[journal mutableCopy];previous[@"v"]=@3;
    NSMutableDictionary *row=[journal[@"windows"][0]mutableCopy];row[@"transform"]=row[@"layer"];[row removeObjectForKey:@"layer"];previous[@"windows"]=@[row];
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:previous options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));
    NSMutableDictionary *relabelled=[journal mutableCopy];relabelled[@"v"]=@3; // right fields, wrong schema number
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:relabelled options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));
    previous[@"v"]=@4; // new number, old field
    assert(!v2DecodeJournal([NSJSONSerialization dataWithJSONObject:previous options:0 error:NULL],[NSMutableDictionary dictionary],[NSMutableDictionary dictionary]));
    NSMutableDictionary *retired=[previous mutableCopy];retired[@"v"]=@3;retired[@"server_pid"]=@456;retired[@"server_birth_sec"]=@50;retired[@"server_birth_usec"]=@0;
    assert(!unlinkat(directoryFD,"v2-journal.json",0));
    NSData *bytes=writeJSON(@"v2-journal.json",retired);clearTables();writes=modelWrites[1];unsigned all=modelWrites[0]+modelWrites[1];
    assert(!v2LoadJournal(nil) && !v2Table.count && !v2Released.count && modelWrites[0]+modelWrites[1]==all && modelWrites[1]==writes);
    assert([[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]]isEqual:bytes]);
    assert(!unlinkat(directoryFD,"v2-journal.json",0));clearTables();

    clearTables();nativeBounds=savedBounds;nativeTransform=savedTransform;
    getTransform=readTransform;setTransform=writeTransform;getLayer=readTransform;setLayer=writeTransform;
    puts("PASS: the original is the placement-1 layer, journalled as schema 4 and restored and verified as the layer whatever another placement holds or the window did; a Dock reset converges with no entry left, a foreign layer is still refused, and a previous-schema journal is refused untouched; modelled window server only");
}
