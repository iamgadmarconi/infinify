// SPDX-License-Identifier: GPL-3.0-or-later
// Native moves of a held window (DW2_MOVE, negotiated by DW2_CAP_MOVE; DWHelperProtocol.h). #imported by DWPayload.m in a fixed order;
// never compiled alone.
//
// Adapts a technique of Sunlight, https://github.com/spacefarm-digital/sunlight commit 7e28956adeeaafc28b22ba6b062a84b9a10aa825
// (MIT, Copyright (c) 2026 spacefarm; licence text native/app/Resources/SUNLIGHT-NOTICE.txt), LiveWindows/osax/sunbeam.h:
// the window server keeps a window's transform relative to its native origin, so a native move made while a transform is in force
// shifts the drawn window by the move until the transform is set again; a move made in the same SkyLight transaction as the
// transform shows nothing in between (lines 1222-1238, sunbeam_moves_in_transaction, and 1240-1245, sunbeam_move); the commit's
// return code is not the verdict, since on macOS 27.2 it is never kCGErrorSuccess while the transaction lands (lines 222-230). The
// transaction prototypes are those of lines 36-37, 39 and 41, and the direct fallback is sunbeam_move's SLSMoveWindowWithGroup.
// Here the transform written with the move is the placement-1 layer (SLSTransactionSetWindowTransform's two integers are the
// placement and the flags of SLSSetWindowTransformAtPlacement, read from the system SkyLight's disassembly on macOS 27.2 26B118:
// both are encoded into the transaction with the window ID, before the matrix, passed by reference on arm64), so placement 0 is
// still never written. Measured on the macOS 27.0.1 guest on an owned window drawn 150 points right of its native place, sampled
// about 70 000 times a second: a direct SLSMoveWindow of 200 points drew it at the moved place until the layer was written again;
// the move and the layer for the new origin in one transaction, in either order, drew it at one place throughout.

static CFTypeRef (*v2TransactionCreate)(int);
static CGError (*v2TransactionCommit)(CFTypeRef,int);
static CGError (*v2TransactionMove)(CFTypeRef,uint32_t,CGPoint);
static CGError (*v2TransactionTransform)(CFTypeRef,uint32_t,int,int,CGAffineTransform);
static CGError (*v2DirectMove)(int,uint32_t,CGPoint *);
static void v2ResolveMove(void) {
    void *sky=v2Sky();
    if(!sky)return;
    v2TransactionCreate=dlsym(sky,"SLSTransactionCreate");v2TransactionCommit=dlsym(sky,"SLSTransactionCommit");
    v2TransactionMove=dlsym(sky,"SLSTransactionMoveWindowWithGroup");v2TransactionTransform=dlsym(sky,"SLSTransactionSetWindowTransform");
    v2DirectMove=dlsym(sky,"SLSMoveWindowWithGroup");
}
static BOOL v2MoveInTransaction(void) { return v2TransactionCreate&&v2TransactionCommit&&v2TransactionMove&&v2TransactionTransform; }
static BOOL v2MoveAPI(void) { return v2MoveInTransaction()||v2DirectMove; }

// Moves a window this session holds to `origin` and keeps it drawn where it is. Runs on v2q. Nothing is asked of the window server
// before the window is known to be held, current, untransformed at placement 0 ([1,0,0,1,-x,-y], the only placement 0 the new layer
// can be computed for) and readable; from the first native call on the answer is APPLIED or NOT_APPLIED (or IDENTITY, when the
// window changed hands meanwhile). The original layer, the journal and the table are untouched: the move changes neither what a
// restore writes nor whom the window belongs to, and a frame that follows still verifies its matrix by a fresh read.
static struct dw2_move_reply v2Move(struct dw2_identity requested,CGPoint origin) {
    struct dw2_move_reply reply={.id=requested,.status=DW2_SCOPE};
    if(!v2MoveAPI()||!v2InScope(&requested))return reply;
    reply.status=DW2_MALFORMED;
    if(!isfinite(origin.x)||!isfinite(origin.y)||fabs(origin.x)>1000000||fabs(origin.y)>1000000)return reply;
    reply.status=DW2_SCOPE;
    DW2Entry *e=v2Table[@(requested.wid)];
    if(!e||e->state!=DW2_HELD||e->reattaching||!v2SameProcess(&e->who,&requested))return reply;
    reply.status=DW2_IDENTITY;
    if(!v2EntryCurrent(e))return reply;
    reply.status=DW2_SNAPSHOT;
    int cid=mainConnection();uint32_t wid=requested.wid;
    CGAffineTransform base=CGAffineTransformIdentity,drawn=CGAffineTransformIdentity;CGRect before=CGRectZero;
    if(skyGetPlacement(cid,wid,DW_BASE_PLACEMENT,NULL,&base)||getTransform(cid,wid,&drawn)||getBounds(cid,wid,&before)
        ||!finiteMatrix(base)||!finiteMatrix(drawn)||!v2FiniteRect(before))return reply;
    if(!v2SameTransform(base,CGAffineTransformMake(1,0,0,1,-before.origin.x,-before.origin.y)))return reply;
    // The layer that draws the window where it is from the new origin: A = L after T0', so L = A after T0'^-1 (dwWriteAbsolute's rule).
    CGAffineTransform layer=CGAffineTransformConcat(CGAffineTransformInvert(CGAffineTransformMake(1,0,0,1,-origin.x,-origin.y)),drawn);
    if(!finiteMatrix(layer))return reply;
    reply.status=DW2_IDENTITY;
    if(!v2EntryCurrent(e))return reply;
    reply.status=DW2_NOT_APPLIED;
    CFTypeRef transaction=v2MoveInTransaction()?v2TransactionCreate(cid):NULL;
    if(transaction){
        // The move first, then the layer taken against the origin it gives; the commit is synchronous and its code is not read.
        v2TransactionMove(transaction,wid,origin);
        v2TransactionTransform(transaction,wid,DW_LAYER_PLACEMENT,0,layer);
        v2TransactionCommit(transaction,1);CFRelease(transaction);
        reply.path=DW2_MOVE_TRANSACTION;
    }else if(v2DirectMove){
        CGPoint point=origin;v2DirectMove(cid,wid,&point);
        setTransform(cid,wid,drawn);
        reply.path=DW2_MOVE_DIRECT;
    }else return reply;
    CGRect after=CGRectZero;CGAffineTransform now=CGAffineTransformIdentity;
    if(getBounds(cid,wid,&after)||!v2FiniteRect(after))return reply;
    memcpy(reply.bounds,(double[]){after.origin.x,after.origin.y,after.size.width,after.size.height},sizeof(reply.bounds));
    // Where the window server put the window elsewhere (an application's own limit), or the layer did not land, the window is drawn
    // where it was by a layer for wherever it now is.
    BOOL kept=getTransform(cid,wid,&now)==0&&v2SameTransform(now,drawn);
    if(!kept){
        if(!v2EntryCurrent(e)){reply.status=DW2_IDENTITY;return reply;}
        kept=setTransform(cid,wid,drawn)==0&&getTransform(cid,wid,&now)==0&&v2SameTransform(now,drawn);
    }
    if(!v2EntryCurrent(e)){reply.status=DW2_IDENTITY;return reply;}
    if(kept&&fabs(after.origin.x-origin.x)<.5&&fabs(after.origin.y-origin.y)<.5)reply.status=DW2_APPLIED;
    return reply;
}
