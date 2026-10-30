// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// Placement model and cases. Split from native/privileged/restore_identity_test.m (37b27b1); #imported by DWPayloadRestoreIdentityTests.m
// after the payload and the substitutes, in its fixed order, and never compiled on its own.
// Placements. A model of the window server's per-placement entries, kept honest only about what was observed (docs/native/dock-helper/Payload/README.md "Placements"):
// placement 0 is the window's own entry, [1,0,0,1,-x,-y] while untransformed and following the native frame; placement 1 is a
// relative layer applied after it; the catenated transform is the two composed. The real dwReadAbsolute / dwWriteAbsolute run on
// top of it, so every call site's absolute-matrix meaning is exercised through the placement-1 path. Values are stored as 32-bit
// floats like the window server's. The model proves what the helper asks for (never placement 0, identity at placement 1 on
// restore), not what the window server then does: that is the guest's to show.
// modelExtra stands for every placement above 1 that some other writer holds (the system's own window open animation, measured on the guest
// as a catenated [0.999,0,0,1,0.5,-201] on a Finder window): it is part of the catenated transform, and the helper neither reads nor writes it.
static CGAffineTransform modelBase,modelLayer,modelExtra;static BOOL modelBaseSet,modelIgnoreLayer;static int modelReadStatus;static unsigned modelWrites[4];
static CGAffineTransform modelFloats(CGAffineTransform t) { return CGAffineTransformMake((float)t.a,(float)t.b,(float)t.c,(float)t.d,(float)t.tx,(float)t.ty); }
static CGAffineTransform modelNatural(void) { return CGAffineTransformMake(1,0,0,1,-nativeBounds.origin.x,-nativeBounds.origin.y); }
static CGAffineTransform modelPlacement0(void) { return modelBaseSet ? modelBase : modelFloats(modelNatural()); }
static CGAffineTransform modelCatenated(void) { return modelFloats(CGAffineTransformConcat(CGAffineTransformConcat(modelPlacement0(),modelLayer),modelExtra)); }
static CGError modelGet(int cid,uint32_t wid,int placement,void *flags,CGAffineTransform *out) {
    assert(cid==1&&wid==42&&!flags&&(placement==0||placement==1));
    if(modelReadStatus)return modelReadStatus;
    *out=placement==0 ? modelPlacement0() : modelLayer;return 0;
}
static CGError modelSet(int cid,uint32_t wid,int placement,int flags,const CGAffineTransform *value) {
    assert(cid==1&&wid==42&&flags==0&&(placement==0||placement==1));
    modelWrites[placement]++;
    if(modelIgnoreLayer&&placement==1)return 0;
    if(placement==1)modelLayer=modelFloats(*value);else{modelBase=modelFloats(*value);modelBaseSet=YES;}
    return 0;
}
static void modelReset(CGRect frame) {
    nativeBounds=frame;modelBaseSet=modelIgnoreLayer=NO;modelLayer=modelExtra=CGAffineTransformIdentity;modelReadStatus=0;memset(modelWrites,0,sizeof(modelWrites));
}
static BOOL modelIdentityLayer(void) {
    return modelLayer.a==1&&modelLayer.b==0&&modelLayer.c==0&&modelLayer.d==1&&modelLayer.tx==0&&modelLayer.ty==0;
}
static void placementCases(struct dw2_identity who) {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    skyGetPlacement=modelGet;skySetPlacement=modelSet;getTransform=dwReadAbsolute;setTransform=dwWriteAbsolute;getLayer=dwReadLayer;setLayer=dwWriteLayer;
    fixtureOnly=NO;allowlist=nil;ownerValue=7;connectionStatus=0;processPID=123;processUID=getuid();goneWID=0;boundsStatus=0;transformReadStatus=0;perWindowNatives=NO;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    CGRect savedBounds=nativeBounds;CGAffineTransform savedTransform=nativeTransform;
    struct dw2_restore_reply summary={0};uint8_t status=255;
    struct dw2_record frame={.id=who,.flags=0,.m={.5,0,0,.5,-106.685,-61.37}};
    CGAffineTransform requested=CGAffineTransformMake(.5,0,0,.5,-106.685,-61.37),natural=CGAffineTransformMake(1,0,0,1,-25,-35);

    // A natural window at (25,35) placed at scale 0.5 with a fractional translation: only placement 1 is written, with the request
    // taken after placement 0 (the layer is A after T0^-1: translation -106.685+.5*25, -61.37+.5*35), and the catenated read is the request.
    clearTables();modelReset(CGRectMake(25,35,300,200));
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && !modelWrites[0] && modelWrites[1]==1 && !modelBaseSet && v2SameTransform(modelCatenated(),requested));
    assert(fabs(modelLayer.tx-(-106.685+.5*25))<1e-4 && fabs(modelLayer.ty-(-61.37+.5*35))<1e-4 && modelLayer.a==.5f && modelLayer.d==.5f);
    // The original is the window's placement-1 layer, the identity here, not the absolute matrix.
    assert(CGAffineTransformIsIdentity(v2Table[@42]->layer));
    // The application moves its own window by +140: placement 0 follows the native frame, so the drawn picture moves with it until
    // the next frame, which sees the catenated read differ and writes placement 1 again, to the same absolute request.
    nativeBounds.origin.x+=140;assert(!v2SameTransform(modelCatenated(),requested));
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && !modelWrites[0] && modelWrites[1]==2 && v2SameTransform(modelCatenated(),requested));
    // Restore: the original layer (the identity) is written back at placement 1; placement 0 is never written and the window is natural
    // at the origin it has now (165,35), whatever it did meanwhile.
    v2Restore(@"placement restore",NO,nil,&summary);
    assert(!summary.pending && !v2Table.count && v2Released[@42] && !modelWrites[0] && modelWrites[1]==3 && modelIdentityLayer());
    assert(v2SameTransform(modelCatenated(),CGAffineTransformMake(1,0,0,1,-165,-35)) && !modelBaseSet);

    // After the Dock dies the window server resets what the Dock wrote to identity: a placement-1 layer returns to identity, which
    // here is natural. The helper that replaces it finds the released original (still natural) and writes identity at placement 1.
    DW2Entry *retained=v2Released[@42];clearTables();
    modelLayer=CGAffineTransformMake(.5,0,0,.5,-90,-20);modelLayer=CGAffineTransformIdentity; // reset by the death of the writer
    retained->reattaching=YES;retained->state=DW2_RESTORING;v2Table[@42]=retained;
    unsigned layerWrites=modelWrites[1];
    v2Restore(@"reattach after the Dock was replaced",YES,nil,&summary);
    assert(!summary.pending && !modelWrites[0] && modelWrites[1]==layerWrites+1 && modelIdentityLayer()
        && v2SameTransform(modelCatenated(),CGAffineTransformMake(1,0,0,1,-165,-35)));

    // A window an earlier build left with placement 0 reset to identity (drawn at the display's corner): its layer is the identity, the
    // frame's absolute request is reached with placement 1 alone, and restore puts the layer back and nothing else. Placement 0 is not
    // the helper's to write, so the window stays where that build left it (only its application's restart fixes that, see the README).
    clearTables();modelReset(CGRectMake(25,35,300,200));modelBase=CGAffineTransformIdentity;modelBaseSet=YES;
    v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && !modelWrites[0] && v2SameTransform(modelCatenated(),requested) && v2SameTransform(modelLayer,requested));
    v2Restore(@"restore of a window left at placement 0 = identity",NO,nil,&summary);
    assert(!summary.pending && !modelWrites[0] && modelIdentityLayer() && v2SameTransform(modelCatenated(),CGAffineTransformIdentity));

    // Safety checks that were there stay: an unreadable placement 0 writes nothing, a placement 0 that is not a usable matrix writes
    // nothing, a layer the window server does not take is not acknowledged and not called restored, and is put right once it is taken.
    modelReset(CGRectMake(25,35,300,200));modelReadStatus=1000;
    assert(dwWriteAbsolute(1,42,requested)==1000 && !modelWrites[0] && !modelWrites[1]);
    modelReadStatus=0;modelBase=CGAffineTransformMake(0,0,0,0,0,0);modelBaseSet=YES;
    assert(dwWriteAbsolute(1,42,requested)==kCGErrorFailure && !modelWrites[0] && !modelWrites[1]);
    modelBaseSet=NO;
    clearTables();modelReset(CGRectMake(25,35,300,200));
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    modelIgnoreLayer=YES;frame.m[4]=-80;
    v2Apply(&frame,1,&status);assert(status==DW2_NOT_APPLIED && !modelWrites[0]);
    v2Restore(@"layer not taken",NO,nil,&summary);assert(summary.pending==1 && v2Table[@42] && !modelWrites[0]);
    modelIgnoreLayer=NO;v2Restore(@"layer taken",YES,nil,&summary);
    assert(!summary.pending && !v2Table.count && !modelWrites[0] && modelIdentityLayer() && v2SameTransform(modelCatenated(),natural));

    // Placement 0 is never resolved: there is no symbol to fall back on.
    assert(skyGetPlacement==modelGet);
    clearTables();nativeBounds=savedBounds;nativeTransform=savedTransform;
    getTransform=readTransform;setTransform=writeTransform;getLayer=readTransform;setLayer=writeTransform;
    puts("PASS: every transform is written at placement 1 and read back catenated; a natural window restores with the identity at placement 1, a native move is followed, a reset layer is re-restored, placement 0 is never written, and an unreadable base, an unusable base or a layer the server does not take is refused; modelled window server only");
}
