// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_FORWARD_OPERATIONS_H
#define DW_FORWARD_OPERATIONS_H
// New implementation. ABI only checked against yabai (MIT), exact source:
// dd845723416f5fe92af49fad5ebab00369e07edd src/misc/extern.h:87-93 and
// src/window_manager.c:504-519. Upstream uses owned proxy windows, arguments
// 0,0 for SetWindowTransform, Commit(transaction,0), then CFRelease.
// https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L87-L93
// https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L504-L519
// On macOS 27.0.0 (26A434), disassembly and fixture observations show that
// stage/commit do NOT return a usable CGError despite the pinned declarations:
// stage returns scratch allocation values; commit leaves cleanup's return value.
// Upstream ignores both. The adapter therefore ignores both return registers;
// only actual per-window native readback and identity may establish APPLIED.
//
// Plural scalar ABI is from the same installed SkyLight build, not guessed from
// its symbol: SLSSetWindowTransforms moves x3->x5, x2->x4, zeros w2/w3, then
// tail-calls SLSSetWindowTransformsAtPlacement. That callee reads 4-byte WIDs,
// 48-byte CGAffineTransforms and the count in w5, converting six doubles/window
// to floats in one window-list message. Scalar SLSSetWindowTransform uses the
// same AtPlacement mechanism with one WID. See the recorded VM disassembly in
// target/native-perf/skylight-forward-bytes.{json,disassembly}.
// Neither source declarations nor symbol presence prove foreign authority or
// usable presentation; live fixture/optical/restoration evidence is separate.
#ifndef DW_V2_WINDOW_LIST_BATCH
#define DW_V2_WINDOW_LIST_BATCH 0
#endif
#ifndef DW_V2_TRANSACTION_BATCH
#define DW_V2_TRANSACTION_BATCH 0
#endif
// Upstream exercises asynchronous commit (0). The synchronous variant is an
// explicit diagnostic comparison, with the same mandatory native readbacks.
#ifndef DW_V2_TRANSACTION_SYNC
#define DW_V2_TRANSACTION_SYNC 0
#endif
#ifndef DW_V2_TRANSACTION_TRACE
#define DW_V2_TRANSACTION_TRACE 0
#endif
#ifndef DW_V2_ALPHA_DEDUP
#define DW_V2_ALPHA_DEDUP 1
#endif
// Compile the optional batching machinery out of ordinary scalar builds. The
// deterministic controller regression opts in explicitly to exercise all paths.
#ifndef DW_V2_FORWARD_TEST
#define DW_V2_FORWARD_TEST 0
#endif
#define DW_V2_BATCH_COMPILED (DW_V2_TRANSACTION_BATCH || DW_V2_WINDOW_LIST_BATCH || DW_V2_FORWARD_TEST)
#if DW_V2_BATCH_COMPILED
static BOOL v2UseTransactionBatch=DW_V2_TRANSACTION_BATCH;
static BOOL v2UseWindowListBatch=DW_V2_WINDOW_LIST_BATCH;
static CFTypeRef (*v2TransactionCreate)(int);
static void (*v2TransactionCommit)(CFTypeRef,int);
static void (*v2TransactionSetTransform)(CFTypeRef,uint32_t,int,int,CGAffineTransform);
static CGError (*v2SetWindowTransforms)(int,const uint32_t *,const CGAffineTransform *,uint32_t);
static BOOL v2ForwardTransactionsAvailable(void) {
    return v2TransactionCreate&&v2TransactionCommit&&v2TransactionSetTransform;
}
static void v2ResolveForwardTransactions(void) {
    if(!v2UseTransactionBatch&&!v2UseWindowListBatch)return;
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    if(!sky)return;
    v2TransactionCreate=dlsym(sky,"SLSTransactionCreate");
    v2TransactionCommit=dlsym(sky,"SLSTransactionCommit");
    v2TransactionSetTransform=dlsym(sky,"SLSTransactionSetWindowTransform");
    v2SetWindowTransforms=dlsym(sky,"SLSSetWindowTransforms");
}
#endif // DW_V2_BATCH_COMPILED
#endif
