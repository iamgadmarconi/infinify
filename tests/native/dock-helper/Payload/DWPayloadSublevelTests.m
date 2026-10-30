// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Pin sublevel substitutes and cases. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.
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
