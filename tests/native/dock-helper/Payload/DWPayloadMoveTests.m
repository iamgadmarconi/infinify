// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
// The helper's native move (DW2_MOVE, native/dock-helper/Payload/DWPayloadMove.m) on the placement model of DWPayloadPlacementTests.m;
// #imported by DWPayloadRestoreIdentityTests.m after it, in its fixed order, and never compiled on its own.
// A transaction is modelled as the window server takes one: its requests are queued and carried out, in their order, by the commit,
// whose return code is the meaningless number macOS 27.2 gives. The model proves what the helper asks for (the move and the layer
// for the new origin in one transaction, the move first, placement 0 never written) and what it accepts, not that the window server
// draws nothing in between: that was measured in the guest (DWPayloadMove.m's header).
static unsigned moveCreates,moveCommits,moveDirects;
static NSMutableArray<NSString *> *moveRequests;
static CGPoint moveQueuedPoint;static CGAffineTransform moveQueuedLayer;static BOOL moveQueuedLayerSet,moveQueuedPointSet;
static BOOL moveClamp,moveLoseLayer;static CGPoint moveClampedTo;
static CFTypeRef fakeTransactionCreate(int cid) { assert(cid==1);moveCreates++;moveRequests=[NSMutableArray array];moveQueuedLayerSet=moveQueuedPointSet=NO;return CFBridgingRetain([NSObject new]); }
static CGError fakeTransactionMove(CFTypeRef transaction,uint32_t wid,CGPoint point) {
    assert(transaction&&wid==42);[moveRequests addObject:@"move"];moveQueuedPoint=point;moveQueuedPointSet=YES;return 0;
}
static CGError fakeTransactionTransform(CFTypeRef transaction,uint32_t wid,int placement,int flags,CGAffineTransform layer) {
    assert(transaction&&wid==42&&placement==1&&flags==0);[moveRequests addObject:@"layer"];moveQueuedLayer=layer;moveQueuedLayerSet=YES;return 0;
}
static CGError fakeTransactionCommit(CFTypeRef transaction,int synchronous) {
    assert(transaction&&synchronous==1);moveCommits++;
    for(NSString *request in moveRequests){
        if([request isEqual:@"move"])nativeBounds.origin=moveClamp?moveClampedTo:moveQueuedPoint;
        else if(!moveLoseLayer)modelSet(1,42,1,0,&moveQueuedLayer);
    }
    return 1156631752; // what macOS 27.2 answers for a transaction that landed
}
static CGError fakeDirectMove(int cid,uint32_t wid,CGPoint *point) {
    assert(cid==1&&wid==42&&point);moveDirects++;nativeBounds.origin=moveClamp?moveClampedTo:*point;return 0;
}
static void moveReset(BOOL transactions) {
    moveCreates=moveCommits=moveDirects=0;moveRequests=nil;moveClamp=moveLoseLayer=NO;
    v2TransactionCreate=transactions?fakeTransactionCreate:NULL;v2TransactionCommit=transactions?fakeTransactionCommit:NULL;
    v2TransactionMove=transactions?fakeTransactionMove:NULL;v2TransactionTransform=transactions?fakeTransactionTransform:NULL;
    v2DirectMove=fakeDirectMove;
}
static BOOL moveNoNativeCall(void) { return !moveCreates&&!moveCommits&&!moveDirects; }
static void moveCases(struct dw2_identity who) {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    skyGetPlacement=modelGet;skySetPlacement=modelSet;getTransform=dwReadAbsolute;setTransform=dwWriteAbsolute;getLayer=dwReadLayer;setLayer=dwWriteLayer;
    fixtureOnly=NO;allowlist=nil;ownerValue=7;connectionStatus=0;processPID=123;processUID=getuid();goneWID=0;boundsStatus=0;transformReadStatus=0;perWindowNatives=NO;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    CGRect savedBounds=nativeBounds;CGAffineTransform savedTransform=nativeTransform;
    struct dw2_restore_reply summary={0};uint8_t status=255;struct dw2_move_reply reply;
    struct dw2_record frame={.id=who,.flags=0,.m={.5,0,0,.5,-106.685,-61.37}};
    CGAffineTransform requested=CGAffineTransformMake(.5,0,0,.5,-106.685,-61.37);

    // The capability follows the symbols: either way of moving offers it, none withholds it.
    moveReset(YES);assert(v2Caps()&DW2_CAP_MOVE);
    moveReset(NO);assert(v2Caps()&DW2_CAP_MOVE);
    moveReset(NO);v2DirectMove=NULL;assert(!(v2Caps()&DW2_CAP_MOVE));
    reply=v2Move(who,CGPointMake(60,35));assert(reply.status==DW2_SCOPE&&!reply.path&&moveNoNativeCall());

    // A held window at (25,35), drawn at half size, is moved natively to (225,35) and stays drawn where it was: one transaction
    // carries the move and then the layer for the new origin, placement 0 is never written, and the commit's number is not the verdict.
    clearTables();modelReset(CGRectMake(25,35,300,200));moveReset(YES);
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED&&v2SameTransform(modelCatenated(),requested));
    NSData *journalBefore=[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]];
    uint64_t journalWrites=atomic_load(&v2JournalWrites);
    reply=v2Move(who,CGPointMake(225,35));
    assert(reply.status==DW2_APPLIED&&reply.path==DW2_MOVE_TRANSACTION&&!memcmp(&reply.id,&who,sizeof(who)));
    assert(moveCreates==1&&moveCommits==1&&!moveDirects&&[moveRequests isEqual:(@[@"move",@"layer"])]);
    assert(moveQueuedPointSet&&moveQueuedPoint.x==225&&moveQueuedPoint.y==35&&moveQueuedLayerSet);
    assert(v2SameTransform(CGAffineTransformConcat(CGAffineTransformMake(1,0,0,1,-225,-35),moveQueuedLayer),requested));
    assert(nativeBounds.origin.x==225&&nativeBounds.origin.y==35&&!modelWrites[0]&&!modelBaseSet&&v2SameTransform(modelCatenated(),requested));
    assert(reply.bounds[0]==225&&reply.bounds[1]==35&&reply.bounds[2]==300&&reply.bounds[3]==200);
    // Nothing a restore depends on changed: the original is still the identity layer, on disk byte for byte.
    assert(CGAffineTransformIsIdentity(v2Table[@42]->layer)&&atomic_load(&v2JournalWrites)==journalWrites);
    assert([[NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"v2-journal.json"]]isEqual:journalBefore]);
    // The next frame, the same request, needs no write: its fresh read already says so.
    unsigned layerWrites=modelWrites[1];v2Apply(&frame,1,&status);assert(status==DW2_APPLIED&&modelWrites[1]==layerWrites);
    // A restore puts the identity layer back: the window is natural where it now is.
    v2Restore(@"restore after a helper move",NO,nil,&summary);
    assert(!summary.pending&&modelIdentityLayer()&&!modelWrites[0]&&v2SameTransform(modelCatenated(),CGAffineTransformMake(1,0,0,1,-225,-35)));

    // An application that holds its window elsewhere (here 20 points lower): the window is still drawn where it was, by a layer for
    // where it landed, and the reply says NOT_APPLIED with the frame it has.
    clearTables();modelReset(CGRectMake(25,35,300,200));moveReset(YES);
    v2Apply(&frame,1,&status);assert(status==DW2_APPLIED);
    moveClamp=YES;moveClampedTo=CGPointMake(225,55);
    reply=v2Move(who,CGPointMake(225,35));
    assert(reply.status==DW2_NOT_APPLIED&&reply.path==DW2_MOVE_TRANSACTION&&reply.bounds[0]==225&&reply.bounds[1]==55);
    assert(v2SameTransform(modelCatenated(),requested)&&!modelWrites[0]);
    // A transaction whose layer did not land is followed by the layer, written alone: the move stands and the window stays drawn.
    clearTables();modelReset(CGRectMake(25,35,300,200));moveReset(YES);
    v2Apply(&frame,1,&status);moveLoseLayer=YES;
    reply=v2Move(who,CGPointMake(225,35));
    assert(reply.status==DW2_APPLIED&&nativeBounds.origin.x==225&&v2SameTransform(modelCatenated(),requested)&&!modelWrites[0]);

    // Without transactions: the move and then at once the layer (not atomic), the same verdicts.
    clearTables();modelReset(CGRectMake(25,35,300,200));moveReset(NO);
    v2Apply(&frame,1,&status);
    reply=v2Move(who,CGPointMake(-400,600));
    assert(reply.status==DW2_APPLIED&&reply.path==DW2_MOVE_DIRECT&&moveDirects==1&&!moveCreates);
    assert(nativeBounds.origin.x==-400&&nativeBounds.origin.y==600&&v2SameTransform(modelCatenated(),requested)&&!modelWrites[0]);

    // Refusals ask nothing of the window server and say nothing more.
    clearTables();modelReset(CGRectMake(25,35,300,200));moveReset(YES);
    reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_SCOPE&&moveNoNativeCall()); // not held
    v2Apply(&frame,1,&status);
    struct dw2_identity other=who;other.birth_usec++;
    reply=v2Move(other,CGPointMake(225,35));assert(reply.status==DW2_SCOPE&&moveNoNativeCall());      // another process instance
    reply=v2Move(who,CGPointMake(NAN,35));assert(reply.status==DW2_MALFORMED&&moveNoNativeCall());
    reply=v2Move(who,CGPointMake(225,INFINITY));assert(reply.status==DW2_MALFORMED&&moveNoNativeCall());
    allowlist=@[@{@"pid":@999,@"birth_sec":@1,@"birth_usec":@2}];
    reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_SCOPE&&moveNoNativeCall());       // out of scope
    allowlist=nil;
    ownerValue++;reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_IDENTITY&&moveNoNativeCall());ownerValue--;
    // A placement 0 that is not the plain [1,0,0,1,-x,-y] of the native frame: the layer for a new origin is unknown.
    modelBase=CGAffineTransformMake(1,0,0,1,-25,-36);modelBaseSet=YES;
    reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_SNAPSHOT&&moveNoNativeCall());modelBaseSet=NO;
    modelReadStatus=1000;reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_SNAPSHOT&&moveNoNativeCall());modelReadStatus=0;
    // An entry being restored is not the session's to move.
    v2Table[@42]->state=DW2_RESTORING;reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_SCOPE&&moveNoNativeCall());
    v2Table[@42]->state=DW2_HELD;
    // The window changes hands between the reads and the move: nothing is moved.
    replaceAfterBounds=YES;reply=v2Move(who,CGPointMake(225,35));assert(reply.status==DW2_IDENTITY&&moveNoNativeCall());
    replaceAfterBounds=NO;ownerValue=7;

    // The request, through the real handler: answered on the apply queue, for the live session only; a wrong length is a protocol error.
    clearTables();modelReset(CGRectMake(25,35,300,200));moveReset(YES);v2Apply(&frame,1,&status);
    dispatch_queue_t savedQueue=v2q,queue=dispatch_queue_create("dw.move.request.test",DISPATCH_QUEUE_SERIAL);v2q=queue;
    int sockets[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));const int near=sockets[0],far=sockets[1];
    DW2Connection *c=[DW2Connection new];c->fd=near;pthread_mutex_init(&c->writeLock,NULL);c->role=DW2_ROLE_CONTROL;c->session=v2Session=7;
    __block struct dw2_header header={.length=sizeof(struct dw2_move),.type=DW2_MOVE,.seq=5};
    struct dw2_move_reply (^ask)(double,double)=^struct dw2_move_reply(double x,double y) {
        struct dw2_move request={.id=who,.origin={x,y}};
        assert(v2Handle(c,&header,&request));header.seq++;dispatch_sync(queue,^{});
        struct { struct dw2_header h; struct dw2_move_reply r; } in;
        assert(read(far,&in,sizeof(in))==sizeof(in)&&in.h.type==(DW2_MOVE|DW2_REPLY)&&in.h.seq==header.seq-1&&in.h.length==sizeof(in.r));
        return in.r;
    };
    reply=ask(225,35);assert(reply.status==DW2_APPLIED&&reply.path==DW2_MOVE_TRANSACTION&&nativeBounds.origin.x==225&&v2SameTransform(modelCatenated(),requested));
    v2Session=8;moveReset(YES);reply=ask(25,35);assert(reply.status==DW2_SCOPE&&moveNoNativeCall()&&nativeBounds.origin.x==225);v2Session=7;
    header.length=24;{struct dw2_move request={.id=who};assert(!v2Handle(c,&header,&request));}
    c->fd=-1;close(near);close(far);v2q=savedQueue;v2Session=0;

    clearTables();nativeBounds=savedBounds;nativeTransform=savedTransform;moveReset(NO);v2DirectMove=NULL;
    getTransform=readTransform;setTransform=writeTransform;getLayer=readTransform;setLayer=writeTransform;
    puts("PASS: a native move of a held window goes with the layer for its new origin in one transaction (move first, placement 0 never written, the commit's number ignored), keeps the drawn matrix where an application holds the window elsewhere or the layer did not land, falls back to a direct move and layer, refuses without a native call what is not the live session's held, current, natural window, and leaves the original and the journal as they were");
}
