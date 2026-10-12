// SPDX-License-Identifier: GPL-3.0-or-later
// Adapter policy only: call the real tap handlers with in-memory packets. No
// tap, NSApplication, window, file promise, event posting or native drag session
// is created. Passing does not prove third-party drag-and-drop delivery.
#import "native-input.m"
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
        ignoreEvent:^BOOL(CGEventRef event){return CGEventGetIntegerValueField(event,kCGEventSourceUserData)==771;}
        cancelled:^{cancelled++;}];
    __block NSUInteger observations=0;__block uint32_t observedButtons=0;__block CGPoint observedPoint=CGPointZero;
    input.nativeMouse=^(CGEventType type,CGPoint point,uint32_t buttons){(void)type;observations++;observedPoint=point;observedButtons=buttons;};
    const int64_t foreign=(int64_t)getpid()+100000;
    CGEventRef down=packet(kCGEventLeftMouseDown,0,foreign),drag=packet(kCGEventLeftMouseDragged,0,getpid()),up=packet(kCGEventLeftMouseUp,0,getpid()),move=packet(kCGEventMouseMoved,0,getpid());
    CGEventRef taggedUp=packet(kCGEventLeftMouseUp,0,getpid()),taggedDown=packet(kCGEventLeftMouseDown,0,foreign);
    CGEventSetIntegerValueField(taggedUp,kCGEventSourceUserData,771);CGEventSetIntegerValueField(taggedDown,kCGEventSourceUserData,771);
    check(unchanged(down,^{return [input handle:kCGEventLeftMouseDown event:down];})&&consumed==1,@"native down reaches consumer once and remains original");
    check(observations==1&&observedButtons==1&&CGPointEqualToPoint(observedPoint,CGEventGetLocation(down)),@"native observation supplies only current point and original held mask");
    take=YES;
    check(unchanged(drag,^{return [input handle:kCGEventLeftMouseDragged event:drag];})&&consumed==1,@"foreign drag crossing own canvas bypasses consumer with exact payload");
    check(unchanged(move,^{return [input handle:kCGEventMouseMoved event:move];})&&consumed==1,@"native tracking motion retains location, deltas, flags and pressure");
    check(unchanged(taggedUp,^{return [input handle:kCGEventLeftMouseUp event:taggedUp];})&&consumed==1,@"tagged synthetic release cannot end native physical pair");
    check(observations==3&&observedButtons==1,@"tagged copies never notify native observation");
    check([input handle:kCGEventLeftMouseDragged event:drag]==drag&&consumed==1,@"native pair survives tagged release");
    check(unchanged(up,^{return [input handle:kCGEventLeftMouseUp event:up];})&&consumed==1,@"physical native release remains original");
    check([input handle:kCGEventMouseMoved event:move]==NULL&&consumed==2,@"physical release ends native reservation");
    check(observations==5&&observedButtons==0,@"original release ends observation and canvas motion does not restart it");

    take=NO;[input handle:kCGEventLeftMouseDown event:down];NSUInteger before=consumed;take=YES;
    CGEventRef second=packet(kCGEventRightMouseDown,1,getpid()),secondDrag=packet(kCGEventRightMouseDragged,1,getpid()),secondUp=packet(kCGEventRightMouseUp,1,getpid());
    check([input handle:kCGEventRightMouseDown event:second]==second&&consumed==before,@"additional native button cannot begin canvas action during drag");
    check(observedButtons==3,@"observer tracks both native buttons without claiming either");
    [input handle:kCGEventLeftMouseUp event:up];
    check(observedButtons==2,@"one release leaves the other original pair observed");
    check([input handle:kCGEventRightMouseDragged event:secondDrag]==secondDrag&&consumed==before,@"each native button retains its own physical pair");
    [input handle:kCGEventRightMouseUp event:secondUp];
    check([input handle:kCGEventMouseMoved event:move]==NULL&&consumed==before+1,@"last native release retires reservation");

    take=NO;[input handle:kCGEventLeftMouseDown event:down];before=consumed;take=YES;
    CGEventRef own=packet(kCGEventLeftMouseDown,0,getpid());
    check([input handle:kCGEventLeftMouseDown event:own]==NULL&&consumed==before+1,@"fresh same-button down retires lost native release");
    check(observedButtons==0,@"superseding canvas press retires stale native observation");
    take=NO;check([input handle:kCGEventLeftMouseUp event:up]==NULL,@"captured press keeps its matching up even when consumer declines");
    take=NO;[input handle:kCGEventLeftMouseDown event:down];before=consumed;
    [input handle:kCGEventTapDisabledByTimeout event:NULL];take=YES;
    check(cancelled==1&&[input handle:kCGEventMouseMoved event:move]==NULL&&consumed==before+1,@"tap disable discards stale native reservation");
    [input handle:kCGEventLeftMouseDown event:own];take=NO;
    [input handle:kCGEventTapDisabledByUserInput event:NULL];
    check(cancelled==2&&[input handle:kCGEventLeftMouseUp event:up]==NULL,@"tap cancellation retains suppression for an already captured down");

    before=consumed;NSUInteger observedBefore=observations;
    check([input handle:kCGEventLeftMouseDown event:taggedDown]==taggedDown&&consumed==before,@"tagged down bypasses physical bookkeeping");
    take=YES;check([input handle:kCGEventMouseMoved event:move]==NULL,@"tagged down creates no native reservation");
    check(observations==observedBefore,@"tagged down and canvas-owned input create no observation");

    __block NSUInteger admissions=0;
    DWGlobalTrackpadInput *global=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return YES;}
        admitTouches:^BOOL(DWTrackpadTouchFrame *frame){(void)frame;admissions++;return YES;}
        touches:^(DWTrackpadTouchFrame *frame){(void)frame;}
        magnify:^BOOL(NSEvent *event){(void)event;return YES;}
        ignoreEvent:^BOOL(CGEventRef event){return CGEventGetIntegerValueField(event,kCGEventSourceUserData)==771;}
        cancelled:^{}];
    check(unchanged(down,^{return [global handleGlobal:kCGEventLeftMouseDown event:down];})&&global.hasNativeMousePress,@"global tap observes native physical down without consuming it");
    CGEventRef dock=dockPacket(kCGGesturePhaseMayBegin);
    check(unchanged(dock,^{return [global handleGlobal:30 event:dock];}),@"new Dock contact cannot take an existing native drag");
    [global handleGlobal:kCGEventLeftMouseUp event:taggedUp];check(global.hasNativeMousePress,@"tagged up cannot release global physical ownership");
    check(unchanged(up,^{return [global handleGlobal:kCGEventLeftMouseUp event:up];})&&!global.hasNativeMousePress,@"global physical release clears native admission guard");
    [global handleGlobal:kCGEventLeftMouseDown event:down];[global cancel];
    check(global.hasNativeMousePress,@"logical cancellation does not lend held native button to new contact");
    [global handleGlobal:kCGEventTapDisabledByUserInput event:NULL];
    check(!global.hasNativeMousePress,@"disabled global tap retires stale native reservation");
    [global handleGlobal:kCGEventLeftMouseDown event:down];[global stop];
    check(!global.hasNativeMousePress,@"stopping global tap clears physical reservation");

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
        [global handleGlobal:kCGEventLeftMouseDown event:touchDown];
        check([global handleGlobal:(CGEventType)NSEventTypeGesture event:contact]==contact&&!global.ownsTouches&&admissions==0,@"native touch-subtype down before contact cannot lend its drag to global gesture");
        check([global handleGlobal:kCGEventLeftMouseDragged event:touchDrag]==touchDrag,@"unadmitted native touch drag remains original");
        [global handleGlobal:kCGEventLeftMouseUp event:touchUp];policyFrame.testFingers=0;
        [global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];policyFrame.testFingers=3;
        [global handleGlobal:(CGEventType)NSEventTypeGesture event:contact];
        check(admissions==1&&!global.hasNativeMousePress,@"fresh three-finger contact offers admission after native pair ends");
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

    for(NSValue *value in @[[NSValue valueWithPointer:down],[NSValue valueWithPointer:drag],[NSValue valueWithPointer:up],[NSValue valueWithPointer:move],[NSValue valueWithPointer:taggedUp],[NSValue valueWithPointer:taggedDown],[NSValue valueWithPointer:second],[NSValue valueWithPointer:secondDrag],[NSValue valueWithPointer:secondUp],[NSValue valueWithPointer:own],[NSValue valueWithPointer:dock]])CFRelease(value.pointerValue);
    [input stop];
    puts("native input policy: original foreign pairs, tagged copies, cancellation and global drag admission passed; native drag-and-drop delivery unverified");
}return 0;}
