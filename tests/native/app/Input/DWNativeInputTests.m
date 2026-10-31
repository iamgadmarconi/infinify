// SPDX-License-Identifier: GPL-3.0-or-later
// Adapter policy only: call the real tap handlers with in-memory packets. No
// tap, NSApplication, window, file promise, event posting or native drag session
// is created. Passing does not prove third-party drag-and-drop delivery.
#import <ApplicationServices/ApplicationServices.h>
static uint32_t physicalButtons;
static bool physicalButtonState(CGEventSourceStateID state,CGMouseButton button) {
    (void)state;return button<32&&(physicalButtons&(1u<<button))!=0;
}
#define CGEventSourceButtonState physicalButtonState
#import "DWNativeInput.m"
#undef CGEventSourceButtonState
#import "DWNativeDragTakeover.h"
#import "DWNativeToolbarExtent.h"
#import <objc/runtime.h>

@interface PolicyTouchFrame : DWTrackpadTouchFrame
@property NSUInteger testFingers;
@end
@implementation PolicyTouchFrame
- (id)device { return @"policy-fixture-trackpad"; }
- (NSArray<NSDictionary *> *)touches { return @[]; }
- (NSUInteger)fingers { return self.testFingers; }
- (NSTimeInterval)time { return 1; }
@end
// Supply deterministic decoded contact frames while exercising the actual tap
// handler and actual NSEvent conversion. This substitution exists only inside
// the isolated regression process, and is restored before exit.
static PolicyTouchFrame *policyFrame;
static id decodedFrame(id cls,SEL selector,NSEvent *event,id device) {
    (void)cls;(void)selector;(void)event;(void)device;return policyFrame;
}

static void check(BOOL value,NSString *message) {
    if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static CGEventRef packet(CGEventType type,int64_t button,int64_t recipient) {
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,CGPointMake(113.25,229.5),(CGMouseButton)button);
    check(event!=NULL,@"create in-memory packet");
    CGEventSetIntegerValueField(event,kCGMouseEventButtonNumber,button);
    CGEventSetIntegerValueField(event,kCGEventSourceUnixProcessID,0);
    CGEventSetIntegerValueField(event,kCGEventTargetUnixProcessID,recipient);
    CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,0);
    CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer,0);
    CGEventSetIntegerValueField(event,kCGMouseEventDeltaX,17);
    CGEventSetIntegerValueField(event,kCGMouseEventDeltaY,-9);
    CGEventSetDoubleValueField(event,kCGMouseEventPressure,.375);
    CGEventSetFlags(event,kCGEventFlagMaskAlternate|kCGEventFlagMaskShift);
    return event;
}
static BOOL unchanged(CGEventRef event,CGEventRef (^handle)(void)) {
    CFDataRef before=CGEventCreateData(NULL,event);CGEventRef result=handle();
    CFDataRef after=CGEventCreateData(NULL,event);
    BOOL same=result==event&&before&&after&&CFEqual(before,after);
    if(before)CFRelease(before);if(after)CFRelease(after);return same;
}
static CGEventRef dockPacket(NSInteger phase) {
    CGEventRef event=CGEventCreate(NULL);check(event!=NULL,@"create in-memory Dock envelope");
    CGEventSetType(event,30);CGEventSetIntegerValueField(event,DWGestureRealType,30);
    CGEventSetIntegerValueField(event,DWGestureHIDType,23);CGEventSetIntegerValueField(event,DWGestureAxis,1);
    CGEventSetIntegerValueField(event,DWGesturePhase,phase);return event;
}
int main(void) {@autoreleasepool {
    __block NSUInteger consumed=0,cancelled=0;__block BOOL take=NO;
    DWNativeInput *input=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;consumed++;return take;}
        earlyConsume:nil
        ignoreEvent:^BOOL(CGEventRef event){return CGEventGetIntegerValueField(event,kCGEventSourceUserData)==771;}
        cancelled:^{cancelled++;}];
    __block NSIndexSet *nativeOwned=nil;__block NSUInteger nativeChanges=0,nativeResets=0;
    input.nativeMouseOwnershipChanged=^(CGEventRef event,NSIndexSet *buttons){nativeOwned=buttons;nativeChanges++;if(!event)nativeResets++;};
    const int64_t foreign=(int64_t)getpid()+100000;
    CGEventRef down=packet(kCGEventLeftMouseDown,0,foreign),drag=packet(kCGEventLeftMouseDragged,0,getpid()),up=packet(kCGEventLeftMouseUp,0,getpid()),move=packet(kCGEventMouseMoved,0,getpid());
    CGEventRef taggedUp=packet(kCGEventLeftMouseUp,0,getpid()),taggedDown=packet(kCGEventLeftMouseDown,0,foreign);
    CGEventSetIntegerValueField(taggedUp,kCGEventSourceUserData,771);CGEventSetIntegerValueField(taggedDown,kCGEventSourceUserData,771);
    check(unchanged(down,^{return [input handle:kCGEventLeftMouseDown event:down];})&&consumed==1,@"native down reaches consumer once and remains original");
    check(nativeChanges==1&&[nativeOwned isEqualToIndexSet:[NSIndexSet indexSetWithIndex:0]],@"native owner learns the exact unclaimed physical down before it returns");
    take=YES;
    check(unchanged(drag,^{return [input handle:kCGEventLeftMouseDragged event:drag];})&&consumed==1,@"foreign drag crossing own canvas bypasses consumer with exact payload");
    check(nativeChanges==2&&nativeOwned.count==1,@"native drag is observed without intercepting or retargeting its original packet");
    check(unchanged(move,^{return [input handle:kCGEventMouseMoved event:move];})&&consumed==1,@"native tracking motion retains location, deltas, flags and pressure");
    check(unchanged(taggedUp,^{return [input handle:kCGEventLeftMouseUp event:taggedUp];})&&consumed==1,@"tagged synthetic release cannot end native physical pair");
    check(nativeChanges==2&&nativeOwned.count==1,@"synthetic and crossing packets cannot retire or retarget native ownership");
    check([input handle:kCGEventLeftMouseDragged event:drag]==drag&&consumed==1,@"native pair survives tagged release");
    check(unchanged(up,^{return [input handle:kCGEventLeftMouseUp event:up];})&&consumed==1,@"physical native release remains original");
    check(nativeChanges==4&&!nativeOwned.count,@"native release notifies after retiring its owned button");
    check([input handle:kCGEventMouseMoved event:move]==NULL&&consumed==2,@"physical release ends native reservation");

    take=NO;[input handle:kCGEventLeftMouseDown event:down];NSUInteger before=consumed;take=YES;
    CGEventRef second=packet(kCGEventRightMouseDown,1,getpid()),secondDrag=packet(kCGEventRightMouseDragged,1,getpid()),secondUp=packet(kCGEventRightMouseUp,1,getpid());
    check([input handle:kCGEventRightMouseDown event:second]==second&&consumed==before,@"additional native button cannot begin canvas action during drag");
    check(nativeOwned.count==2,@"additional button retains the original native owner");
    [input handle:kCGEventLeftMouseUp event:up];
    check([nativeOwned isEqualToIndexSet:[NSIndexSet indexSetWithIndex:1]],@"one release cannot resume a still-held second native button");
    check([input handle:kCGEventRightMouseDragged event:secondDrag]==secondDrag&&consumed==before,@"each native button retains its own physical pair");
    [input handle:kCGEventRightMouseUp event:secondUp];
    check([input handle:kCGEventMouseMoved event:move]==NULL&&consumed==before+1,@"last native release retires reservation");

    take=NO;[input handle:kCGEventLeftMouseDown event:down];before=consumed;take=YES;
    CGEventRef own=packet(kCGEventLeftMouseDown,0,getpid());
    check([input handle:kCGEventLeftMouseDown event:own]==NULL&&consumed==before+1,@"fresh same-button down retires lost native release");
    take=NO;check([input handle:kCGEventLeftMouseUp event:up]==NULL,@"captured press keeps its matching up even when consumer declines");
    take=YES;check([input handle:kCGEventLeftMouseDown event:own]==NULL,@"pending ownership refusal captures the physical canvas down");
    take=NO;check([input handle:kCGEventLeftMouseDragged event:drag]==NULL&&[input handle:kCGEventLeftMouseUp event:up]==NULL,
        @"cancelling hover placement still suppresses the entire refused physical pair without reposting");
    check(unchanged(down,^{return [input handle:kCGEventLeftMouseDown event:down];})
        &&unchanged(drag,^{return [input handle:kCGEventLeftMouseDragged event:drag];})
        &&unchanged(up,^{return [input handle:kCGEventLeftMouseUp event:up];}),@"a subsequent admitted native pair retains all original physical payloads");
    take=NO;[input handle:kCGEventLeftMouseDown event:down];before=consumed;
    [input handle:kCGEventTapDisabledByTimeout event:NULL];take=YES;
    check(nativeResets>=1&&!nativeOwned.count,@"tap loss reports cancellation distinctly from a physical release");
    check(cancelled==1&&[input handle:kCGEventMouseMoved event:move]==NULL&&consumed==before+1,@"tap disable discards stale native reservation");
    [input handle:kCGEventLeftMouseDown event:own];take=NO;
    [input handle:kCGEventTapDisabledByUserInput event:NULL];
    check(cancelled==2&&[input handle:kCGEventLeftMouseUp event:up]==NULL,@"tap cancellation retains suppression for an already captured down");

    take=NO;[input handle:kCGEventLeftMouseDown event:down];before=consumed;take=YES;physicalButtons=1;
    [input handle:kCGEventTapDisabledByTimeout event:NULL];
    check([nativeOwned isEqualToIndexSet:[NSIndexSet indexSetWithIndex:0]],@"tap timeout retains a physically held native button");
    check(unchanged(second,^{return [input handle:kCGEventRightMouseDown event:second];})&&consumed==before&&nativeOwned.count==2,
        @"secondary button after timeout cannot start a competing canvas action");
    physicalButtons=2;[input handle:kCGEventTapDisabledByUserInput event:NULL];
    check([nativeOwned isEqualToIndexSet:[NSIndexSet indexSetWithIndex:1]],@"tap cancellation prunes only native buttons confirmed released");
    check(unchanged(secondDrag,^{return [input handle:kCGEventRightMouseDragged event:secondDrag];})&&consumed==before,
        @"remaining native drag after cancellation keeps its original packets");
    physicalButtons=0;
    check(unchanged(secondUp,^{return [input handle:kCGEventRightMouseUp event:secondUp];})&&!nativeOwned.count,
        @"final physical native release ends timeout reservation");

    before=consumed;
    check([input handle:kCGEventLeftMouseDown event:taggedDown]==taggedDown&&consumed==before,@"tagged down bypasses physical bookkeeping");
    take=YES;check([input handle:kCGEventMouseMoved event:move]==NULL,@"tagged down creates no native reservation");

    // Below [zoom] interact_min a window takes no hover (docs/crates/desktop/POINTER.md): the shell's consumer claims a mouse-moved packet over a pick target
    // and the tap must then drop it, while one it does not claim goes on untouched. The packet is offered to the consumer every time, and
    // a moved packet while a native button is held (the application's own drag tracking) is never the consumer's to claim.
    {CGEventRef still=packet(kCGEventMouseMoved,0,foreign);NSUInteger offered=consumed;
        check(DWNativeInputAnnotatedMask()&CGEventMaskBit(kCGEventMouseMoved),@"the annotated tap subscribes to mouse-moved packets");
        take=NO;check(unchanged(still,^{return [input handle:kCGEventMouseMoved event:still];})&&consumed==offered+1,@"a moved packet over an application is offered to the consumer and left untouched when it declines");
        take=YES;check([input handle:kCGEventMouseMoved event:still]==NULL&&consumed==offered+2,@"a moved packet the consumer claims (a pick target) is dropped, once offered");
        take=NO;[input handle:kCGEventLeftMouseDown event:down];offered=consumed;take=YES;
        check(unchanged(still,^{return [input handle:kCGEventMouseMoved event:still];})&&consumed==offered,@"a moved packet while a native button is held is not offered and not dropped");
        [input handle:kCGEventLeftMouseUp event:up];
        CGEventRef tagged=packet(kCGEventMouseMoved,0,foreign);CGEventSetIntegerValueField(tagged,kCGEventSourceUserData,771);offered=consumed;
        check(unchanged(tagged,^{return [input handle:kCGEventMouseMoved event:tagged];})&&consumed==offered,@"the shell's own tagged motion is neither offered nor dropped");
        CFRelease(still);CFRelease(tagged);take=NO;}

    // Which native presses count as the application's own window drag of a transformed window (DWNativeDragTakeover.h).
    {CGRect press=CGRectMake(0,528,800,632),drawn=CGRectMake(611,309,401,317),moved=CGRectMake(236,447,800,632);CGPoint start=CGPointMake(891,323),away=CGPointMake(841,348);
        check(DWNativeWindowDragStarted(press,drawn,moved,start,away),@"a transformed window whose native origin moves with its extent unchanged is the application's own drag");
        check(!DWNativeWindowDragStarted(press,press,moved,start,away),@"an identity placement (drawn where it is natively) is left to drag natively");
        check(!DWNativeWindowDragStarted(press,drawn,press,start,away),@"no native motion is a content drag");
        check(!DWNativeWindowDragStarted(press,drawn,CGRectMake(0.5,528.5,800,632),start,away),@"native motion of a point or less is no drag");
        check(!DWNativeWindowDragStarted(press,drawn,CGRectMake(0,528,830,632),start,away)&&!DWNativeWindowDragStarted(press,drawn,CGRectMake(236,447,830,640),start,away),@"a changed extent is a resize, left native");
        check(!DWNativeWindowDragStarted(press,drawn,moved,start,CGPointMake(893,325)),@"under 4 points of pointer travel is still a click");
        // The sequence that dragged a Finder window at zoom 0.5 natively for 24 to 30 samples of scale 1 (guest, 2026-10-30): the window list
        // read the NATIVE frame as the bounds of a window drawn at half size from its own corner (800x600 at 300,200 against the drawn
        // 400x300 at 560,746), so the press looked untransformed and no takeover ever started. The controller's placement is what is drawn.
        CGRect finder=CGRectMake(300,200,800,600),listed=finder,placed=CGRectMake(560,746,400,300),dragged=CGRectMake(448,296,800,600);CGPoint from=CGPointMake(640,760),to=CGPointMake(600,790);
        check(!DWNativeWindowDragStarted(finder,listed,dragged,from,to),@"the window list's bounds alone cannot show that the window is drawn elsewhere (the failing sequence)");
        check(DWNativeWindowDragStarted(finder,placed,dragged,from,to),@"the placement the controller drew shows it, and the application's drag is taken over");}
    // A press that ends as a click but whose native origin WindowServer moved (Chrome's empty tab strip at zoom 0.5 in the guest, 2026-10-30:
    // the window drawn at 550,355 600x400 from the native frame 210,393 1200x800; the click left the frame at 100,348, the next click at
    // 160,468). The click is reverted, not adopted; a real drag is still the takeover's; an unchanged click stays unchanged.
    {CGRect press=CGRectMake(210,393,1200,800),drawn=CGRectMake(550,355,600,400),after=CGRectMake(100,348,1200,800);
        check(DWNativeClickSettleKind(YES,NO,press,after,NO)==DWNativeClickSettleRevert,@"a click whose native origin moved with the extent unchanged is reverted (the failing sequence)");
        check(DWNativeClickSettleKind(YES,NO,press,after,YES)==DWNativeClickSettleRevert,@"a displaced frame is reverted whatever the window list's bounds say");
        check(DWNativeClickSettleKind(YES,NO,press,press,YES)==DWNativeClickSettleUnchanged,@"a click that moved nothing still ends as an unchanged native click");
        check(DWNativeClickSettleKind(YES,NO,press,press,NO)==DWNativeClickSettleAdopt,@"unchanged frame with other window-list bounds is left to the adoption");
        check(DWNativeClickSettleKind(NO,NO,press,after,NO)==DWNativeClickSettleAdopt,@"a press that was a drag (not a click) is adopted as before, never reverted");
        check(DWNativeClickSettleKind(YES,YES,press,after,NO)==DWNativeClickSettleAdopt,@"a taken-over press is the canvas's and is never reverted");
        check(DWNativeClickSettleKind(YES,NO,press,CGRectMake(100,348,1230,800),NO)==DWNativeClickSettleAdopt&&DWNativeClickSettleKind(YES,NO,press,CGRectMake(210.5,393.5,1200,800),NO)==DWNativeClickSettleAdopt,@"a changed extent is a resize and a move of a point or less is no move: neither is reverted");
        // The same press, seen while the button is still down: the application's drag has already moved the origin with the pointer at rest.
        CGPoint start=CGPointMake(1000,362);
        check(DWNativeWindowDragBegunInPlace(press,drawn,after,start,start),@"the origin moving at the down, pointer at rest, is the application's drag begun in place");
        check(DWNativeWindowDragBegunInPlace(press,drawn,after,start,CGPointMake(1002,363)),@"a pointer within the click slop is still at rest");
        check(!DWNativeWindowDragBegunInPlace(press,drawn,after,start,CGPointMake(1010,362)),@"a pointer past 4 points is the ordinary takeover's (the drag packets), not this one's");
        check(!DWNativeWindowDragBegunInPlace(press,drawn,press,start,start),@"nothing moved natively: a content press stays the application's");
        check(!DWNativeWindowDragBegunInPlace(press,press,after,start,start),@"an identity placement drags natively without trouble");
        check(!DWNativeWindowDragBegunInPlace(press,drawn,CGRectMake(100,348,1230,800),start,start),@"a changed extent is a resize, left native");}
    // Which part of a toolbar group is native (DWNativeToolbarExtent.h). Safari 27.0.1's centre group, read with Accessibility in the guest:
    // the group is 541,0 753x52; its children are the search button 547,11.5 23.5x30 and the address field 568,18 720x31.
    {CGRect group=CGRectMake(541,0,753,52),kids[]={CGRectMake(547,11.5,23.5,30),CGRectMake(568,18,720,31)},extent;
        check(DWToolbarGroupExtent(group,kids,2,&extent)&&CGRectEqualToRect(extent,CGRectMake(541,11.5,753,37.5)),@"a group keeps its width and the vertical extent of its children");
        CGRect inflated=CGRectInset(extent,-1,-1);
        check(!CGRectContainsPoint(inflated,CGPointMake(917,7))&&!CGRectContainsPoint(inflated,CGPointMake(917,50.5)),@"the strips above and below the address field are the window's, at the press point that failed at zoom 0.5 (local y 7)");
        check(CGRectContainsPoint(inflated,CGPointMake(917,14))&&CGRectContainsPoint(inflated,CGPointMake(543,30))&&CGRectContainsPoint(inflated,CGPointMake(1292,30)),@"the field, its rounded ends and the search button stay native");
        CGRect nested[]={CGRectMake(166,7,75,38)};group=CGRectMake(163,0,77,52);
        check(DWToolbarGroupExtent(group,nested,1,&extent)&&CGRectEqualToRect(extent,CGRectMake(163,7,77,38)),@"a segmented control's group is trimmed the same way");
        CGRect whole[]={CGRectMake(0,0,50,52)};group=CGRectMake(0,0,50,52);
        check(DWToolbarGroupExtent(group,whole,1,&extent)&&CGRectEqualToRect(extent,group),@"a child that fills the group leaves it whole");
        CGRect slightly[]={CGRectMake(95,-0.5,38,53)};group=CGRectMake(92,0,71,52);
        check(DWToolbarGroupExtent(group,slightly,1,&extent)&&CGRectEqualToRect(extent,CGRectMake(92,0,71,52)),@"a child a point past the group is clipped to it");
        CGRect outside[]={CGRectMake(95,7,38,60)},empty[]={CGRectMake(95,7,0,38)},bad[]={CGRectMake(NAN,7,38,38)},far[]={CGRectMake(400,7,38,38)};
        check(!DWToolbarGroupExtent(group,outside,1,&extent)&&!DWToolbarGroupExtent(group,empty,1,&extent)&&!DWToolbarGroupExtent(group,bad,1,&extent)&&!DWToolbarGroupExtent(group,far,1,&extent),
            @"a child outside the group, an empty or a non-finite one cannot be trusted: the group stays whole");
        check(!DWToolbarGroupExtent(group,kids,0,&extent)&&!DWToolbarGroupExtent(group,NULL,1,&extent)&&!DWToolbarGroupExtent(CGRectMake(0,0,0,52),whole,1,&extent),@"no children, no array or an empty group: whole");}
    // The consumer takes a held native drag over from inside the ownership callback (a transformed window that began the application's
    // own window drag). That packet and the rest of the physical pair become the canvas's; nothing else about the pair changes.
    __block DWNativeInput *taking=nil;__block BOOL takeNow=NO;__block NSUInteger takenConsumed=0;__block BOOL tookButton=NO;
    taking=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;takenConsumed++;return NO;} earlyConsume:nil ignoreEvent:nil cancelled:^{}];
    taking.nativeMouseOwnershipChanged=^(CGEventRef event,NSIndexSet *buttons){if(takeNow&&event&&CGEventGetType(event)==kCGEventLeftMouseDragged&&buttons.count==1)tookButton=[taking takeNativeButton:0];};
    check(![taking takeNativeButton:0],@"no held native button, nothing to take");
    check(unchanged(down,^{return [taking handle:kCGEventLeftMouseDown event:down];})&&takenConsumed==1,@"takeover scenario: a native press is first an ordinary original pair");
    check(unchanged(drag,^{return [taking handle:kCGEventLeftMouseDragged event:drag];})&&!tookButton&&takenConsumed==1,@"a native drag the consumer does not take stays original");
    takeNow=YES;
    check([taking handle:kCGEventLeftMouseDragged event:drag]==NULL&&tookButton,@"the packet that shows the application's window drag is swallowed when the consumer takes the button");
    check([taking holdsCapturedButton:0]&&![taking holdsCapturedButton:1],@"the canvas holds the taken button's physical pair until its release (the lost-input watchdog reads this)");
    NSUInteger tails=takenConsumed;
    check([taking handle:kCGEventLeftMouseDragged event:drag]==NULL&&takenConsumed==tails+1,@"later drags of the taken pair are swallowed and offered to the consumer");
    check([taking handle:kCGEventLeftMouseUp event:up]==NULL&&takenConsumed==tails+2&&![taking holdsCapturedButton:0],@"the physical release of the taken pair is swallowed, offered to the consumer, and ends the canvas's hold");
    takeNow=NO;
    check(unchanged(down,^{return [taking handle:kCGEventLeftMouseDown event:down];})&&unchanged(drag,^{return [taking handle:kCGEventLeftMouseDragged event:drag];}),@"the next press is a fresh native pair again");
    check(![taking takeNativeButton:1],@"another button that is not held native cannot be taken");
    [taking handle:kCGEventLeftMouseUp event:up];[taking stop];

    __block NSUInteger earlyDowns=0,earlyTails=0,earlyCancels=0;
    DWNativeInput *early=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;earlyTails++;return NO;}
        earlyConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;earlyDowns++;return YES;}
        ignoreEvent:^BOOL(CGEventRef event){return CGEventGetIntegerValueField(event,kCGEventSourceUserData)==771;}
        cancelled:^{earlyCancels++;}];
    check(unchanged(taggedDown,^{return [early handleEarly:kCGEventLeftMouseDown event:taggedDown];})&&earlyDowns==0,@"tagged copies never enter early title admission");
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL&&earlyDowns==1&&early.hasEarlyMousePress,@"title down is owned before annotation independently of AppKit button state");
    check(unchanged(taggedUp,^{return [early handleEarly:kCGEventLeftMouseUp event:taggedUp];}),@"tagged release cannot retire early physical ownership");
    check([early handleEarly:kCGEventLeftMouseDragged event:drag]==NULL&&earlyTails==1,@"owned early tail reaches the consumer once despite refusal");
    [early handleEarly:kCGEventTapDisabledByTimeout event:NULL];
    check([early handleEarly:kCGEventLeftMouseDragged event:drag]==NULL&&earlyTails==1&&!early.hasEarlyMousePress,@"cancelled early tail stays swallowed without active ownership or logical redelivery");
    check([early handle:kCGEventLeftMouseUp event:up]==NULL&&earlyTails==1,@"annotated fallback suppresses early pair after tap disable");
    check(unchanged(up,^{return [early handleEarly:kCGEventLeftMouseUp event:up];}),@"matching fallback up retires early tombstone");
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL,@"early admission recovers for next physical pair");
    NSUInteger cancellationCount=earlyCancels;
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL&&earlyCancels==cancellationCount+1,@"new down cancels a lost early pair before replacing it");
    [early handleEarly:kCGEventLeftMouseUp event:up];
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL,@"managed chrome owns a fresh pair even when its action may be refused");
    physicalButtons=1;
    NSUInteger companionTails=earlyTails,companionDowns=earlyDowns;
    check([early handleEarly:kCGEventRightMouseDown event:second]==NULL&&earlyTails==companionTails,
        @"an additional button is suppressed before native tracking during owned chrome");
    physicalButtons=2;
    check([early handleEarly:kCGEventRightMouseDragged event:secondDrag]==NULL&&earlyTails==companionTails,
        @"additional chrome button tails cannot start a second consumer gesture");
    check(unchanged(taggedUp,^{return [early handleEarly:kCGEventLeftMouseUp event:taggedUp];}),@"tagged packet cannot retire exclusive chrome ownership");
    [early handleEarly:kCGEventLeftMouseUp event:up];companionTails=earlyTails;
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL&&earlyDowns==companionDowns,
        @"a held companion keeps exclusivity after the primary release");
    check([early handleEarly:kCGEventLeftMouseUp event:up]==NULL&&earlyTails==companionTails,
        @"replacement primary pair stays inert while a companion is held");
    [early handleEarly:kCGEventTapDisabledByTimeout event:NULL];
    check([early handle:kCGEventRightMouseDragged event:secondDrag]==NULL&&earlyTails==companionTails,
        @"annotated fallback preserves companion suppression after early tap cancellation");
    check([early handle:kCGEventRightMouseUp event:secondUp]==NULL&&earlyTails==companionTails,
        @"companion release retires only its own swallowed pair");
    physicalButtons=0;
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL&&earlyDowns==companionDowns+1,
        @"last companion release permits a new chrome gesture");
    [early handleEarly:kCGEventLeftMouseUp event:up];
    check([early handleEarly:kCGEventLeftMouseDown event:down]==NULL,@"primary admission before lost-up recovery");
    [early handleEarly:kCGEventTapDisabledByTimeout event:NULL];physicalButtons=0;
    check(unchanged(second,^{return [early handleEarly:kCGEventRightMouseDown event:second];}),
        @"released primary tombstone cannot swallow a later independent secondary down");
    check([early handleEarly:kCGEventLeftMouseUp event:up]==NULL,@"late primary up remains swallowed after stale primary retirement");
    CGEventRef earlyNativeSecond=packet(kCGEventRightMouseDown,1,foreign);
    [early handle:kCGEventRightMouseDown event:earlyNativeSecond];NSUInteger earlyCount=earlyDowns;
    check(unchanged(down,^{return [early handleEarly:kCGEventLeftMouseDown event:down];})&&earlyDowns==earlyCount,@"a native other-button pair forbids early title admission");
    [early handle:kCGEventRightMouseUp event:secondUp];CFRelease(earlyNativeSecond);[early stop];

    __block __weak DWNativeInput *stoppingWeak;
    DWNativeInput *stopping=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;return NO;}
        earlyConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;[stoppingWeak stop];return YES;}
        ignoreEvent:nil cancelled:^{}];stoppingWeak=stopping;
    check(unchanged(down,^{return [stopping handleEarly:kCGEventLeftMouseDown event:down];})
        &&unchanged(up,^{return [stopping handleEarly:kCGEventLeftMouseUp event:up];}),@"consumer teardown cannot resurrect early ownership");
    __block __weak DWNativeInput *cancellingWeak;__block NSUInteger cancelledTails=0;__block BOOL lateGesture=NO;
    DWNativeInput *cancelling=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;cancelledTails++;return NO;}
        earlyConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;[cancellingWeak handleEarly:kCGEventTapDisabledByTimeout event:NULL];lateGesture=YES;return YES;}
        ignoreEvent:nil cancelled:^{lateGesture=NO;}];cancellingWeak=cancelling;
    check([cancelling handleEarly:kCGEventLeftMouseDown event:down]==NULL
        &&[cancelling handleEarly:kCGEventLeftMouseDragged event:drag]==NULL
        &&[cancelling handleEarly:kCGEventLeftMouseUp event:up]==NULL&&cancelledTails==0&&!lateGesture,@"nested cancellation clears late gesture installation and preserves only an early tombstone");
    [cancelling stop];

    __block NSUInteger admissions=0;
    DWGlobalTrackpadInput *global=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return YES;}
        admitTouches:^BOOL(DWTrackpadTouchFrame *frame){(void)frame;admissions++;return YES;}
        touches:^(DWTrackpadTouchFrame *frame){(void)frame;}
        magnify:^BOOL(NSEvent *event){(void)event;return YES;}
        ignoreEvent:^BOOL(CGEventRef event){return CGEventGetIntegerValueField(event,kCGEventSourceUserData)==771;}
        cancelled:^{}];
    physicalButtons=1;
    check(unchanged(down,^{return [global handleGlobal:kCGEventLeftMouseDown event:down];})&&global.hasNativeMousePress,@"global tap observes native physical down without consuming it");
    CGEventRef dock=dockPacket(kCGGesturePhaseMayBegin);
    check(unchanged(dock,^{return [global handleGlobal:30 event:dock];}),@"new Dock contact cannot take an existing native drag");
    [global handleGlobal:kCGEventLeftMouseUp event:taggedUp];check(global.hasNativeMousePress,@"tagged up cannot release global physical ownership");
    physicalButtons=0;
    check(unchanged(up,^{return [global handleGlobal:kCGEventLeftMouseUp event:up];})&&!global.hasNativeMousePress,@"global physical release clears native admission guard");
    physicalButtons=1;[global handleGlobal:kCGEventLeftMouseDown event:down];[global cancel];
    check(global.hasNativeMousePress,@"logical cancellation does not lend held native button to new contact");
    [global handleGlobal:kCGEventTapDisabledByUserInput event:NULL];
    check(!global.hasNativeMousePress,@"disabled global tap retires stale native reservation");
    physicalButtons=1;[global handleGlobal:kCGEventLeftMouseDown event:down];[global stop];physicalButtons=0;
    check(!global.hasNativeMousePress,@"stopping global tap clears physical reservation");
    // A drag the canvas took over: the application's window drag ends with a tagged release posted ahead of the hardware's, and this tap, in front of the
    // one that swallows the physical tail, may never be shown that release. The press it saw go down is gone with the button all the same.
    physicalButtons=1;[global handleGlobal:kCGEventLeftMouseDown event:down];
    check(global.hasNativeMousePress,@"a native press is held while the hardware has the button down");
    [global handleGlobal:kCGEventLeftMouseDragged event:drag];[global handleGlobal:kCGEventLeftMouseUp event:taggedUp];
    check(global.hasNativeMousePress,@"a tagged release posted by this process does not end it while the button is physically down");
    physicalButtons=0;
    check(!global.hasNativeMousePress,@"the hardware's release ends it though this tap never saw a physical release");
    physicalButtons=2;[global handleGlobal:kCGEventRightMouseDown event:second];physicalButtons=0;
    check(!global.hasNativeMousePress,@"and so for any other button");
    check(DWPhysicalMouseButtons()==0,@"DWPhysicalMouseButtons is the hardware's state: none down");
    physicalButtons=5;check(DWPhysicalMouseButtons()==5,@"and reports each button by its number");physicalButtons=0;
    // Dock control with no touch source delivering: this tap's own rule. Every DockSwipe whose beginning it saw while it owned the touch is its to drop.
    __block DWDockControlVerdict verdict=DWDockControlUndecided;__block NSUInteger asked=0;
    DWGlobalTrackpadInput *shared=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return YES;} admitTouches:^BOOL(DWTrackpadTouchFrame *frame){(void)frame;return NO;}
        touches:^(DWTrackpadTouchFrame *frame){(void)frame;} magnify:^BOOL(NSEvent *event){(void)event;return NO;} ignoreEvent:nil cancelled:^{}];
    shared.dockDecision=^DWDockControlVerdict(CGEventRef event){(void)event;asked++;return verdict;};
    CGEventRef dockBegan=dockPacket(kCGGesturePhaseBegan),dockEnded=dockPacket(kCGGesturePhaseEnded),dockChanged=dockPacket(kCGGesturePhaseChanged);
    // The Dock-control packet of a format this decoder does not know: the shape the owner's Show Desktop and Launchpad pinches may have, unverified.
    CGEventRef dockOther=dockPacket(kCGGesturePhaseChanged);CGEventSetIntegerValueField(dockOther,DWGestureAxis,0);
    check(DWDockControlClassify(dockBegan,NULL,NULL)==DWDockControlBegan&&DWDockControlClassify(dockChanged,NULL,NULL)==DWDockControlChanged
        &&DWDockControlClassify(dockEnded,NULL,NULL)==DWDockControlEnded&&DWDockControlClassify(dockOther,NULL,NULL)==DWDockControlOther,@"Dock-control packets are told by phase, and an unknown axis is `other`");
    if(!NSEvent.pressedMouseButtons){
        check([shared handleGlobal:30 event:dockBegan]==NULL&&asked==1,@"with no touch source a Dock swipe of any finger count is this tap's, and the decision is asked first");
        check([shared handleGlobal:30 event:dockChanged]==NULL,@"the rest of that stream follows");
        check([shared handleGlobal:30 event:dockEnded]==NULL,@"and its end");
        check(unchanged(dockOther,^{return [shared handleGlobal:30 event:dockOther];}),@"a Dock-control packet of another format is not dropped while this tap owns no touch");
        [shared handleGlobal:30 event:dockBegan];
        check([shared handleGlobal:30 event:dockOther]==NULL,@"but is while a stream this tap owns is in progress");
        [shared handleGlobal:30 event:dockEnded];
    }
    // Pass and Drop are final, for any format.
    verdict=DWDockControlPass;
    check(unchanged(dockBegan,^{return [shared handleGlobal:30 event:dockBegan];}),@"a Dock swipe the guard passes is left alone");
    check(unchanged(dockEnded,^{return [shared handleGlobal:30 event:dockEnded];}),@"and so is its end");
    verdict=DWDockControlDrop;
    check([shared handleGlobal:30 event:dockOther]==NULL&&[shared handleGlobal:30 event:dockChanged]==NULL,@"a packet the guard drops is dropped whatever its format, with no touch owned here");
    verdict=DWDockControlUndecided;
    // The touch this tap owns: a three-finger admission that ends leaves a tail in which the end of the system's gesture is still this tap's.
    CGEventRef anyOther=CGEventCreate(NULL);CGEventSetType(anyOther,30);
    check(unchanged(anyOther,^{return [shared handleGlobal:30 event:anyOther];}),@"a type-30 packet with no field at all is not dropped without a touch");
    [shared setValue:@YES forKey:@"ownsTouches"];
    check([shared handleGlobal:30 event:anyOther]==NULL,@"it is while this tap owns an admitted touch");
    [shared setValue:@NO forKey:@"ownsTouches"];
    check(unchanged(anyOther,^{return [shared handleGlobal:30 event:anyOther];}),@"and is not after it");
    [shared setValue:@(CACurrentMediaTime()+DWDockControlTail) forKey:@"dockTail"];
    check([shared handleGlobal:30 event:anyOther]==NULL,@"but is within the tail an ended touch leaves");
    [shared setValue:@(CACurrentMediaTime()-.001) forKey:@"dockTail"];
    check(unchanged(anyOther,^{return [shared handleGlobal:30 event:anyOther];}),@"and not after the tail");
    CFRelease(anyOther);CFRelease(dockOther);CFRelease(dockChanged);

    // Dock control is never handed to AppKit: +[NSEvent eventWithCGEvent:] has no type 30, and AppKit logs "unrecognized type is 30" for each packet that gets there.
    // The conversion is counted for the length of this block, in the one tap that sees every event and the one that sees the Dock's.
    {
        static NSUInteger conversions;static id (*convert)(id,SEL,CGEventRef);
        Method eventMethod=class_getClassMethod(NSEvent.class,@selector(eventWithCGEvent:));check(eventMethod!=NULL,@"the conversion entry point exists");
        convert=(id (*)(id,SEL,CGEventRef))method_getImplementation(eventMethod);
        id (^counted)(id,CGEventRef)=^id(id cls,CGEventRef event){conversions++;return convert(cls,@selector(eventWithCGEvent:),event);};
        IMP counting=imp_implementationWithBlock(counted);IMP real=method_setImplementation(eventMethod,counting);
        CGEventRef probe=CGEventCreate(NULL);CGEventSetType(probe,(CGEventType)NSEventTypeGesture);(void)[NSEvent eventWithCGEvent:probe];
        check(conversions==1,@"the counting substitution sees a conversion");conversions=0;
        CGEventRef decodable=dockPacket(kCGGesturePhaseChanged),undecodable=dockPacket(kCGGesturePhaseChanged);CGEventSetIntegerValueField(undecodable,DWGestureHIDType,8);
        CGEventRef bare=CGEventCreate(NULL);CGEventSetType(bare,30);
        __block NSUInteger seen=0;DWNativeInput *annotated=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;return NO;}
            earlyConsume:nil ignoreEvent:nil cancelled:^{}];
        annotated.dockControl=^(CGEventRef event){(void)event;seen++;};
        DWGlobalTrackpadInput *fresh=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return YES;} admitTouches:^BOOL(DWTrackpadTouchFrame *frame){(void)frame;return NO;}
            touches:^(DWTrackpadTouchFrame *frame){(void)frame;} magnify:^BOOL(NSEvent *event){(void)event;return NO;} ignoreEvent:nil cancelled:^{}];
        for(NSValue *packet in @[[NSValue valueWithPointer:decodable],[NSValue valueWithPointer:undecodable],[NSValue valueWithPointer:bare]]){
            CGEventRef event=packet.pointerValue;
            check([annotated handle:30 event:event]==event,@"the annotated tap returns a Dock-control packet untouched");
            [fresh handleGlobal:30 event:event];
        }
        check(seen==3,@"the annotated tap tells the shell of each packet that reached it");
        check(conversions==0,@"no Dock-control packet, decodable or not, is converted to an NSEvent by either tap");
        method_setImplementation(eventMethod,real);imp_removeBlock(counting);
        CFRelease(probe);CFRelease(decodable);CFRelease(undecodable);CFRelease(bare);
    }
    CFRelease(dockBegan);CFRelease(dockEnded);

    Method decode=class_getClassMethod(DWTrackpadTouchFrame.class,@selector(frameWithEvent:device:));
    check(decode!=NULL,@"decoded touch frame entrypoint exists");
    IMP original=method_setImplementation(decode,(IMP)decodedFrame);
    CGEventRef contact=CGEventCreate(NULL);CGEventSetType(contact,(CGEventType)NSEventTypeGesture);
    check([NSEvent eventWithCGEvent:contact].type==NSEventTypeGesture,@"in-memory generic gesture reaches real NSEvent conversion");
    CGEventRef touchDown=packet(kCGEventLeftMouseDown,0,foreign),touchDrag=packet(kCGEventLeftMouseDragged,0,foreign),touchUp=packet(kCGEventLeftMouseUp,0,foreign);
    for(NSValue *value in @[[NSValue valueWithPointer:touchDown],[NSValue valueWithPointer:touchDrag],[NSValue valueWithPointer:touchUp]])CGEventSetIntegerValueField(value.pointerValue,kCGMouseEventSubtype,NSEventSubtypeTouch);
    check([NSEvent eventWithCGEvent:touchDown].subtype==NSEventSubtypeTouch,@"in-memory mouse packet carries public touch subtype");
    @try {
        policyFrame=[PolicyTouchFrame new];policyFrame.testFingers=3;
        physicalButtons=1;[global handleGlobal:kCGEventLeftMouseDown event:touchDown];
        check([global handleGlobal:(CGEventType)NSEventTypeGesture event:contact]==contact&&!global.ownsTouches&&admissions==0,@"native touch-subtype down before contact cannot lend its drag to global gesture");
        check([global handleGlobal:kCGEventLeftMouseDragged event:touchDrag]==touchDrag,@"unadmitted native touch drag remains original");
        physicalButtons=0;[global handleGlobal:kCGEventLeftMouseUp event:touchUp];policyFrame.testFingers=0;
        [global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];policyFrame.testFingers=3;
        [global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        check(admissions==1&&!global.hasNativeMousePress,@"fresh three-finger contact offers admission after native pair ends");
        // A drag the canvas took over whose physical release this tap never saw: the next contact is still offered for admission, the button being up. While
        // the hardware has the button down it is not offered, which is the guard's whole purpose.
        policyFrame.testFingers=0;[global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        physicalButtons=1;[global handleGlobal:kCGEventLeftMouseDown event:touchDown];[global handleGlobal:kCGEventLeftMouseDragged event:touchDrag];
        policyFrame.testFingers=3;[global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        check(admissions==1,@"a contact begun while the hardware has a native button down is not offered for admission");
        policyFrame.testFingers=0;[global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        physicalButtons=0;policyFrame.testFingers=3;[global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        check(admissions==2&&!global.hasNativeMousePress,@"and the contact after the release this tap never saw is offered, though a press was left open");
        policyFrame.testFingers=0;[global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        // No event tap is installed, so the real handler deliberately will not
        // commit new ownership. Seed the already-admitted-contact precondition
        // solely in this test object to check its generated mouse pair below.
        [global setValue:@YES forKey:@"ownsTouches"];
        check([global handleGlobal:kCGEventLeftMouseDown event:touchDown]==NULL&&!global.hasNativeMousePress,@"admitted touch stream keeps its generated press without becoming native");
        check([global handleGlobal:kCGEventLeftMouseDragged event:touchDrag]==NULL,@"admitted three-finger drag retains canvas ownership");
        policyFrame.testFingers=0;[global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        check([global handleGlobal:kCGEventLeftMouseUp event:touchUp]==NULL&&!global.hasNativeMousePress,@"admitted contact still suppresses generated release after finger end");
    } @finally {method_setImplementation(decode,original);policyFrame=nil;}
    CFRelease(contact);CFRelease(touchDown);CFRelease(touchDrag);CFRelease(touchUp);

    // The volume, brightness, media and keyboard-backlight keys of a Mac arrive system-defined (NX_SYSDEFINED, type 14, subtype 8,
    // data1 = key<<16 | state<<8); with "standard function keys" on, the top row sends F-key events instead. Every tap handler
    // returns such a packet as it came, byte for byte, and no consumer is asked about one. What makes macOS drop these keys is
    // an active annotated tap asking for their type, which no handler can undo, so the mask the tap subscribes to is checked too.
    {
        __block NSUInteger asked=0;
        DWNativeInput *keys=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;asked++;return YES;}
            earlyConsume:^BOOL(CGEventType type,CGEventRef event){(void)type;(void)event;asked++;return YES;} ignoreEvent:nil cancelled:^{}];
        DWGlobalTrackpadInput *pad=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return YES;}
            admitTouches:^BOOL(DWTrackpadTouchFrame *frame){(void)frame;asked++;return YES;} touches:^(DWTrackpadTouchFrame *frame){(void)frame;asked++;}
            magnify:^BOOL(NSEvent *event){(void)event;asked++;return YES;} ignoreEvent:nil cancelled:^{}];
        // NX_KEYTYPE_SOUND_UP, SOUND_DOWN, BRIGHTNESS_UP, BRIGHTNESS_DOWN, MUTE, PLAY, NEXT, PREVIOUS, FAST, REWIND, ILLUMINATION_UP/DOWN/TOGGLE.
        const int auxKeys[]={0,1,2,3,7,16,17,18,19,20,21,22,23};
        NSUInteger auxPackets=0;
        for(size_t i=0;i<sizeof(auxKeys)/sizeof(*auxKeys);i++)for(int pressed=1;pressed>=0;pressed--){
            NSInteger state=pressed?0xa:0xb;
            NSEvent *made=[NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:(NSEventModifierFlags)(state<<8)
                timestamp:0 windowNumber:0 context:nil subtype:8 data1:((NSInteger)auxKeys[i]<<16)|(state<<8) data2:-1];
            CGEventRef aux=made.CGEvent?CGEventCreateCopy(made.CGEvent):NULL;
            check(aux!=NULL&&CGEventGetType(aux)==(CGEventType)NSEventTypeSystemDefined,@"in-memory aux control packet is system-defined");
            CGEventType type=(CGEventType)NSEventTypeSystemDefined;auxPackets++;
            check(unchanged(aux,^{return [keys handle:type event:aux];})&&unchanged(aux,^{return [keys handleEarly:type event:aux];})
                &&unchanged(aux,^{return [pad handleGlobal:type event:aux];}),@"an aux control key passes every tap handler untouched");
            CFRelease(aux);
        }
        // F1..F12 and the Mission Control key, with and without the Fn flag the system adds to them.
        const int functionKeys[]={122,120,99,118,96,97,98,100,101,109,103,111,160};
        NSUInteger keyPackets=0;
        for(size_t i=0;i<sizeof(functionKeys)/sizeof(*functionKeys);i++)for(int fn=0;fn<2;fn++)for(int pressed=1;pressed>=0;pressed--){
            CGEventRef key=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)functionKeys[i],pressed);check(key!=NULL,@"create in-memory F-key packet");
            if(fn)CGEventSetFlags(key,CGEventGetFlags(key)|kCGEventFlagMaskSecondaryFn);
            CGEventType type=pressed?kCGEventKeyDown:kCGEventKeyUp;keyPackets++;
            check(unchanged(key,^{return [keys handle:type event:key];})&&unchanged(key,^{return [keys handleEarly:type event:key];})
                &&unchanged(key,^{return [pad handleGlobal:type event:key];}),@"a function key passes every tap handler untouched");
            CFRelease(key);
        }
        check(asked==0,@"no consumer, admission or magnify callback is asked about a system key");
        // The annotated tap subscribes to the pointer, scroll, tablet and gesture types it acts on and to nothing else: not the
        // system-defined type 14, not the key types 10 to 12, not AppKit-defined 13 (macOS posts it while the volume moves).
        const int wanted[]={1,2,3,4,5,6,7,22,23,24,25,26,27,29,30};
        CGEventMask expected=0,mask=DWNativeInputAnnotatedMask();
        for(size_t i=0;i<sizeof(wanted)/sizeof(*wanted);i++)expected|=(CGEventMask)1<<wanted[i];
        check(mask==expected,@"the annotated tap asks for exactly the pointer, scroll, tablet and gesture types");
        for(int type=10;type<=14;type++)check(!(mask&((CGEventMask)1<<type)),@"the annotated tap never asks for key, system-defined or AppKit-defined events");
        printf("system keys: %lu aux control and %lu function-key packets returned untouched by the annotated, early and global handlers; annotated mask 0x%llx\n",
            (unsigned long)auxPackets,(unsigned long)keyPackets,(unsigned long long)mask);
    }

    for(NSValue *value in @[[NSValue valueWithPointer:down],[NSValue valueWithPointer:drag],[NSValue valueWithPointer:up],[NSValue valueWithPointer:move],[NSValue valueWithPointer:taggedUp],[NSValue valueWithPointer:taggedDown],[NSValue valueWithPointer:second],[NSValue valueWithPointer:secondDrag],[NSValue valueWithPointer:secondUp],[NSValue valueWithPointer:own],[NSValue valueWithPointer:dock]])CFRelease(value.pointerValue);
    [input stop];
    puts("native input policy: original foreign pairs, tagged copies, cancellation, global drag admission and system keys passed; native drag-and-drop delivery unverified");
}return 0;}
