// SPDX-License-Identifier: GPL-3.0-or-later
// Reuse the actual presenter's in-memory transport and ACK fixture. Native
// geometry checks below are substituted; no window, getter, input or drag
// session starts, and success is never optical or native-input parity proof.
#define main DWPresenterReadinessFixtureMain
#import "DWNativePresenterTests.m"
#undef main
#import "DWNativeViews.h"

static NSDictionary *transferFamily(NSDictionary *root,uint64_t generation,CGRect native,CGRect child) {
    return @{@"identity":root,@"generation":@(generation),@"native_bounds":rect(native),@"root":root[@"wid"],@"members":@[
        @{@"identity":root,@"native_bounds":rect(native),@"parent":@0},
        @{@"identity":identity([root[@"pid"]intValue],43),@"native_bounds":rect(child),@"parent":root[@"wid"]}]};
}
static NSDictionary *transferSnapshot(NSDictionary *root,uint64_t generation,CGRect native,CGRect first,CGRect second) {
    NSDictionary *source=@{@"identity":root,@"generation":@(generation),@"observation_known":@YES,@"observed_rect":rect(native)};
    NSDictionary *window=@{@"window":@7,@"kind":@"window",@"source":source,@"world_rect":rect(native)};
    NSMutableDictionary *one=[window mutableCopy],*two=[window mutableCopy];
    one[@"output"]=@1;one[@"screen_rect"]=rect(first);one[@"clip_rect"]=rect(first);
    two[@"output"]=@2;two[@"screen_rect"]=rect(second);two[@"clip_rect"]=rect(second);
    NSDictionary *viewport=rect(CGRectMake(0,0,1200,900));
    return @{@"outputs":@[@{@"id":@1,@"screen_bounds":viewport,@"camera":@{@"x":@0,@"y":@0},@"zoom":@1},
        @{@"id":@2,@"screen_bounds":viewport,@"camera":@{@"x":@0,@"y":@0},@"zoom":@1}],@"windows":@[window],@"placements":@[one.copy,two.copy]};
}
static NSDictionary *transferDescribe(DWNativeViews *views,NSDictionary *state,NSDictionary *root,NSDictionary *audit) {
    return [views describe:state bound:@{@7:root}families:audit?@{@7:audit}:@{}];
}
static DWNativeAppliedPlacement *transferAck(DWNativePresenter *presenter,DWNativeViews *views,NSDictionary *state,NSDictionary *root,NSDictionary *audit,DWNativeViewTransfer *transfer) {
    // Main requests a fresh ACK once per placementRequestRevision, never on
    // successful-admission repaint. These are actual, never forged receipts.
    [presenter requireFreshPlacementAcknowledgement];[presenter describe:transferDescribe(views,state,root,audit)bound:@{@7:root}];[presenter submit];ack(presenter);
    return [presenter acknowledgedPlacementForWindow:@7 identity:root generation:@(transfer.generation)output:@(transfer.output)];
}
int main(void) {@autoreleasepool {
    check(DWPresenterReadinessFixtureMain()==0,@"existing presenter correspondence oracle passes");
    NSDictionary *root=identity(123,42);CGRect native=CGRectMake(100,100,320,232),child=CGRectMake(150,125,90,60);
    CGRect first=CGRectMake(250,200,160,116),second=CGRectMake(650,200,160,116);
    NSDictionary *state=transferSnapshot(root,1,native,first,second),*audit=transferFamily(root,1,native,child);
    DWNativeViews *views=[DWNativeViews new];DWNativePresenter *presenter=[DWNativePresenter fixturePID:@123];[presenter bound:root bounds:native family:audit];
    NSDictionary *desired=transferDescribe(views,state,root,audit);
    check([views desiredOwnerForWindow:@7].unsignedLongLongValue==1&&![views replica:@7 output:@1]&&[views replica:@7 output:@2],@"initial automatic primary rendering is unchanged");
    check(![views admittedOwnerForWindow:@7]&&!views.pendingTransfers.count,@"ordinary rendering is no transfer admission");
    [presenter describe:desired bound:@{@7:root}];[presenter submit];ack(presenter);DWNativeAppliedPlacement *ordinary=receipt(presenter,root,1,1);
    DWNativeViewTransfer *transfer=[views requestTransferForWindow:@7 output:@2];
    check(transfer&&views.pendingTransfers.count==1&&[views replica:@7 output:@1]&&[views replica:@7 output:@2],@"explicit pending transfer preserves both captured sites");
    check([views requiresPlacementAdmissionForWindow:@7]&&![views requiresPlacementAdmissionForWindow:@8],@"covered family requires admission; unrelated source does not");
    uint64_t requestRevision=views.placementRequestRevision;
    DWNativeViewPlacementCheck current=^BOOL(DWNativeAppliedPlacement *placement){return [presenter isAcknowledgedPlacementCurrent:placement];};
    __block NSUInteger validations=0;DWNativeViewPlacementCheck geometry=^BOOL(DWNativeAppliedPlacement *placement){(void)placement;validations++;return YES;};
    check(![views completeTransfer:transfer placement:nil current:current validateGeometry:geometry]
        &&![views completeTransfer:transfer placement:ordinary current:current validateGeometry:geometry]&&validations==0,@"missing and wrong-output ACKs cannot admit transfer");
    DWNativeAppliedPlacement *placed=transferAck(presenter,views,state,root,audit,transfer);check(placed!=nil,@"actual new complete family ACK matches transfer");
    check(![views completeTransfer:transfer placement:placed current:current validateGeometry:^BOOL(DWNativeAppliedPlacement *p){(void)p;return NO;}]
        &&[views replica:@7 output:@2],@"ACK without fresh geometry keeps the destination captured");
    check([views completeTransfer:transfer placement:placed current:current validateGeometry:geometry]&&validations==1,@"exact ACK plus substituted geometry commits presentation only");
    check(!views.pendingTransfers.count&&! [views replica:@7 output:@2]&&[views replica:@7 output:@1]&&[views admittedOwnerForWindow:@7].unsignedLongLongValue==2,@"admission changes only this ordinary primary");
    check(![views requiresPlacementAdmissionForWindow:@7],@"completed primary no longer suppresses a future physical press");
    check(views.placementRequestRevision==requestRevision&&[views isAdmissionCurrentForTransfer:transfer placement:placed],@"admission repaint does not demand or revoke another ACK");
    check(![views completeTransfer:transfer placement:placed current:current validateGeometry:geometry],@"completed transfer is never performed twice");
    first.origin.x+=10;second.origin.x+=10;state=transferSnapshot(root,1,native,first,second);transferDescribe(views,state,root,audit);
    check(![views isTransferCurrent:transfer]&&!views.pendingTransfers.count&&![views admittedOwnerForWindow:@7]
        &&![views replica:@7 output:@2]&&views.placementRequestRevision==requestRevision,@"same-output camera motion keeps ordinary primary rendering and revokes old admission");

    transfer=[views requestTransferForWindow:@7 output:@1];placed=transferAck(presenter,views,state,root,audit,transfer);
    [views cancelTransfer:transfer];DWNativeViewTransfer *recovery=[views currentTransferForWindow:@7];
    check(recovery&&recovery!=transfer&&recovery.output==2&&![recovery.requestID isEqual:transfer.requestID]
        &&[views replica:@7 output:@1]&&[views replica:@7 output:@2],@"cancellation stages a new previous-primary recovery token");
    check(![views completeTransfer:transfer placement:placed current:current validateGeometry:geometry],@"cancelled token cannot settle its replacement");
    placed=transferAck(presenter,views,state,root,audit,recovery);
    check([views completeTransfer:recovery placement:placed current:current validateGeometry:geometry],@"geometry-only recovery settles off-pointer without input permission");
    [views cancelTransfer:recovery];check(![views currentTransferForWindow:@7]&&! [views replica:@7 output:@2],@"ending completed transfer keeps its committed ordinary primary");

    transfer=[views requestTransferForWindow:@7 output:@1];placed=transferAck(presenter,views,state,root,audit,transfer);
    __block NSUInteger ackChecks=0;
    check(![views completeTransfer:transfer placement:placed current:^BOOL(DWNativeAppliedPlacement *p){
        ackChecks++;if(ackChecks==2)[views cancelTransfer:transfer];return [presenter isAcknowledgedPlacementCurrent:p];
    }validateGeometry:geometry]&&ackChecks==2&&[views currentTransferForWindow:@7]!=transfer,@"supersession during final ACK check cannot commit an old request");
    transfer=[views requestTransferForWindow:@7 output:@1];placed=transferAck(presenter,views,state,root,audit,transfer);
    check(![views completeTransfer:transfer placement:placed current:current validateGeometry:^BOOL(DWNativeAppliedPlacement *p){(void)p;[views cancelTransfer:transfer];return YES;}],@"supersession during geometry checks loses the exact token fence");
    recovery=[views currentTransferForWindow:@7];placed=transferAck(presenter,views,state,root,audit,recovery);
    [presenter fixtureExpire];check(![views completeTransfer:recovery placement:placed current:current validateGeometry:geometry],@"session loss prevents geometry admission");[presenter finish];

    [views reset];CGRect partial=second;partial.origin.x=1150;state=transferSnapshot(root,1,native,first,partial);transferDescribe(views,state,root,audit);
    check(![views requestTransferForWindow:@7 output:@2]&&[views replica:@7 output:@2],@"partial root remains ordinary presentation and cannot transfer");
    second=CGRectMake(1100,200,100,72.5);state=transferSnapshot(root,1,native,first,second);NSDictionary *outside=transferFamily(root,1,native,CGRectMake(400,125,90,60));transferDescribe(views,state,root,outside);
    check(![views requestTransferForWindow:@7 output:@2],@"fully visible root cannot transfer a clipped descendant");
    state=transferSnapshot(root,1,native,first,CGRectMake(650,200,160,116));transferDescribe(views,state,root,nil);
    check(![views requestTransferForWindow:@7 output:@2],@"missing family report is not root-only authority");
    NSMutableDictionary *rootOnly=[audit mutableCopy];rootOnly[@"members"]=@[audit[@"members"][0]];rootOnly[@"generation"]=@2;
    transferDescribe(views,state,root,rootOnly);check(![views requestTransferForWindow:@7 output:@2],@"mismatched root-only audit cannot be mistaken for a valid empty child list");
    rootOnly[@"generation"]=@1;rootOnly[@"identity"]=identity(123,44);
    transferDescribe(views,state,root,rootOnly);check(![views requestTransferForWindow:@7 output:@2],@"root-only audit must have the exact source identity");
    transferDescribe(views,state,root,audit);transfer=[views requestTransferForWindow:@7 output:@2];
    NSDictionary *newState=transferSnapshot(root,2,native,first,CGRectMake(650,200,160,116));transferDescribe(views,newState,root,audit);
    check(![views isTransferCurrent:transfer]&&!views.pendingTransfers.count&&[views replica:@7 output:@1],@"generation change waits for a matching audited family");
    check(![views currentTransferForWindow:@7]&&[views requiresPlacementAdmissionForWindow:@7],@"coverage without any eligible recovery token still refuses its family's press");
    transferDescribe(views,newState,root,transferFamily(root,2,native,child));recovery=[views currentTransferForWindow:@7];
    check(recovery&&recovery!=transfer&&recovery.generation==2&&recovery.output==1,@"fresh audit restages bounded recovery without resurrecting old generation");
    [views describe:nil bound:@{@7:root}families:@{@7:audit}];check(!views.pendingTransfers.count&&!views.capturedWindows.count&&![views isTransferCurrent:recovery],@"invalid snapshot/reset revokes all adapter transfer state");
    check(![views requiresPlacementAdmissionForWindow:@7],@"session/reset removes stale coverage admission requirements");
    printf("PASS: %lu presenter + explicit transfer checks; substituted geometry only, no native input/optical proof\n",(unsigned long)checks);
}return 0;}
