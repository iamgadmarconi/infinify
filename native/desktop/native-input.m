// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-input.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "trackpad-gestures.h"
#import "native-tablet.h"
#include <unistd.h>

@interface DWNativeInput ()
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event;
- (CGEventRef)handleEarly:(CGEventType)type event:(CGEventRef)event;
@end

// DockSwipe field/type/phase decoding (adapted from joshuarli/iss, ISC) lives in dock-control.h, with its notice in full.
// Vertical/pinch axis values are documented in the original Mac Mouse Fix
// TouchSimulator.m at 3c10736888c51926d70392ac1eb5c7cb98f6e231 (no code copied):
// https://github.com/noah-nuebling/mac-mouse-fix/blob/3c10736888c51926d70392ac1eb5c7cb98f6e231/Helper/Core/Touch/TouchSimulator.m
// These are event fields, not linked private functions. Neither a successful tap
// nor these source references establishes runtime suppression on a future ABI.

@interface DWGlobalTrackpadInput ()
- (CGEventRef)handleGlobal:(CGEventType)type event:(CGEventRef)event;
@end
static CGEventRef globalTrackpadInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;
    @autoreleasepool { return [(__bridge DWGlobalTrackpadInput *)context handleGlobal:type event:event]; }
}
@implementation DWGlobalTrackpadInput {
    CFMachPortRef _tap;CFRunLoopSourceRef _source;
    BOOL (^_enabled)(void);BOOL (^_admitTouches)(DWTrackpadTouchFrame *);void (^_touches)(DWTrackpadTouchFrame *);
    BOOL (^_magnify)(NSEvent *);BOOL (^_ignoreEvent)(CGEventRef);void (^_cancelled)(void);
    id _device;BOOL _ownsTouches,_touchCancelled;
    BOOL _magnifyOwned,_magnifyDecided,_magnifyCancelled,_dockOwned;
    BOOL _scrollOwned,_handling,_notifyingCancel;
    NSMutableIndexSet *_buttons,*_nativeButtons;
    NSUInteger _epoch;
    NSTimeInterval _dockTail; // Dock control is still this tap's until then: the end of an admitted touch
}
- (instancetype)initWithEnabled:(BOOL (^)(void))enabled admitTouches:(BOOL (^)(DWTrackpadTouchFrame *))admitTouches touches:(void (^)(DWTrackpadTouchFrame *))touches magnify:(BOOL (^)(NSEvent *))magnify ignoreEvent:(BOOL (^)(CGEventRef))ignoreEvent cancelled:(void (^)(void))cancelled {
    if((self=[super init])){_enabled=[enabled copy];_admitTouches=[admitTouches copy];_touches=[touches copy];_magnify=[magnify copy];_ignoreEvent=[ignoreEvent copy];_cancelled=[cancelled copy];_buttons=[NSMutableIndexSet indexSet];_nativeButtons=[NSMutableIndexSet indexSet];}return self;
}
- (BOOL)running { return _tap&&CFMachPortIsValid(_tap)&&CGEventTapIsEnabled(_tap); }
- (BOOL)ownsTouches { return _ownsTouches; }
- (BOOL)hasNativeMousePress { return _nativeButtons.count!=0; }
- (BOOL)start {
    if(_tap)return self.running;
    if(!AXIsProcessTrusted())return NO;
    // Session interception precedes Dock handling. Keep the existing native
    // mouse bridge annotated; it still needs the actual destination window.
    // NSEventTypeGesture (29) carries generic touches AND AppKit magnify events;
    // DockControl (30) has a different, explicitly checked private payload.
    CGEventMask mask=NSEventMaskGesture|CGEventMaskBit(30)|CGEventMaskBit(kCGEventScrollWheel)
        |CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventLeftMouseDragged)
        |CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventRightMouseDragged)
        |CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventOtherMouseDragged)|CGEventMaskBit(kCGEventMouseMoved);
    _tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,globalTrackpadInput,(__bridge void *)self);
    if(!_tap)return NO;
    _source=CFMachPortCreateRunLoopSource(NULL,_tap,0);
    if(!_source){CFMachPortInvalidate(_tap);CFRelease(_tap);_tap=NULL;return NO;}
    CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);return YES;
}
- (void)cancel {
    BOOL notify=(_ownsTouches&&!_touchCancelled)||(_magnifyOwned&&!_magnifyCancelled);
    if(_ownsTouches)_touchCancelled=YES;if(_magnifyOwned)_magnifyCancelled=YES;
    if(notify)_epoch++;
    if(notify&&!_notifyingCancel){_notifyingCancel=YES;void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();_notifyingCancel=NO;}
}
- (CGEventRef)handleGlobal:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        [_nativeButtons removeAllIndexes];
        [self cancel];
        if(_tap&&AXIsProcessTrusted())CGEventTapEnable(_tap,true);
        return event;
    }
    if(!event||_handling)return event;
    BOOL (^ignore)(CGEventRef)=_ignoreEvent;if(ignore&&ignore(event))return event;
    _handling=YES;CGEventRef result=event;
    @try {
        BOOL enabled=_enabled&&_enabled();if(!enabled)[self cancel];
        // Dock control is never handed to AppKit: +[NSEvent eventWithCGEvent:] has no type 30 (AppKit logs "unrecognized type is 30" for each
        // packet), and CGEventType 30 is also the number of NSEventTypeMagnify, which is how the conversion below was once reached.
        if(type==DWDockControlType)return [self dockControl:event enabled:enabled];
        if(DWNativeTabletEvent(event))return event;
        BOOL down=DWMouseDown(type);
        BOOL up=DWMouseUp(type);
        BOOL drag=DWMouseDragged(type);
        if(down||up||drag||type==kCGEventMouseMoved){
            // Public AppKit subtype identifies mouse packets generated by a
            // touch sequence. Separate mouse/tablet input remains native.
            NSEvent *appkit=[NSEvent eventWithCGEvent:event];BOOL touch=appkit&&appkit.subtype==NSEventSubtypeTouch;
            NSInteger button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);BOOL valid=button>=0&&button<32;
            if(down&&valid){[_buttons removeIndex:(NSUInteger)button];[_nativeButtons removeIndex:(NSUInteger)button];}
            BOOL paired=touch&&(up||drag)&&valid&&[_buttons containsIndex:(NSUInteger)button];
            BOOL taken=touch&&_ownsTouches&&(down||type==kCGEventMouseMoved);
            if(down&&taken&&valid)[_buttons addIndex:(NSUInteger)button];
            // Observe the original stream, before AppKit or the annotated
            // adapter. An app-held drag must not lend its button to a new
            // global contact after crossing the canvas. Our posted copies have
            // already bypassed this method through the lifetime-tag predicate.
            if(down&&!taken&&valid&&CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)!=getpid())[_nativeButtons addIndex:(NSUInteger)button];
            if(up&&valid)[_nativeButtons removeIndex:(NSUInteger)button];
            if(up&&paired)[_buttons removeIndex:(NSUInteger)button];
            return paired||taken?NULL:event;
        }
        if(type==kCGEventScrollWheel){
            NSEvent *appkit=[NSEvent eventWithCGEvent:event];if(!appkit||!CGEventGetIntegerValueField(event,kCGScrollWheelEventIsContinuous))return event;
            NSEventPhase phase=appkit.phase,momentum=appkit.momentumPhase;
            // A new physical scroll can reclaim admission after a cancelled
            // three-finger contact. Finger-end alone does not end its momentum.
            if((phase&NSEventPhaseBegan)&&!_ownsTouches)_scrollOwned=NO;
            BOOL phased=phase!=NSEventPhaseNone||momentum!=NSEventPhaseNone;
            if(!phased)return event; // No evidence this smooth-scroll packet is an owned tail.
            BOOL taken=_ownsTouches&&phased,owned=_scrollOwned;
            if(taken)_scrollOwned=YES;
            BOOL terminal=(momentum&(NSEventPhaseEnded|NSEventPhaseCancelled))||(phase&NSEventPhaseCancelled);
            if(terminal)_scrollOwned=NO;
            return taken||owned?NULL:event;
        }
        // Only gesture-envelope packets can carry the touch/magnify data. A
        // pressure or Touch Bar packet in the same envelope is left untouched.
        if(type!=(CGEventType)NSEventTypeGesture&&type!=(CGEventType)NSEventTypeMagnify)return event;
        NSEvent *appkit=[NSEvent eventWithCGEvent:event];if(!appkit)return event;
        if(appkit.type==NSEventTypeGesture){
            DWTrackpadTouchFrame *frame=[DWTrackpadTouchFrame frameWithEvent:appkit device:_device];
            if(frame){
                if(!_device&&frame.fingers>=3){
                    // Retire the previous pinch before the new contact's
                    // admission epoch. Its cancelled physical tails stay owned.
                    if(_magnifyOwned&&!_magnifyCancelled)[self cancel];
                    _device=frame.device;
                    NSUInteger epoch=_epoch;BOOL (^admit)(DWTrackpadTouchFrame *)=_admitTouches;
                    BOOL taken=enabled&&!self.hasNativeMousePress&&!NSEvent.pressedMouseButtons&&admit&&admit(frame);
                    if(epoch==_epoch&&_tap){_ownsTouches=taken;_touchCancelled=NO;}
                }
                BOOL owned=_ownsTouches;NSUInteger epoch=_epoch;
                void (^touches)(DWTrackpadTouchFrame *)=_touches;if(owned&&!_touchCancelled&&touches)touches(frame);
                if(!frame.fingers&&epoch==_epoch){if(_ownsTouches)_dockTail=CACurrentMediaTime()+DWDockControlTail;_device=nil;_ownsTouches=NO;_touchCancelled=NO;}
                if(owned)result=NULL;
            }
            if(_dockOwned||_ownsTouches)result=NULL;
            return result;
        }
        if(appkit.type==NSEventTypeMagnify){
            NSEventPhase phase=appkit.phase;BOOL terminal=(phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0||phase==NSEventPhaseNone;
            if(_ownsTouches||_dockOwned){
                _magnifyDecided=YES;
                if(terminal){_magnifyOwned=NO;_magnifyDecided=NO;_magnifyCancelled=NO;}
                return NULL;
            }
            if(phase&NSEventPhaseBegan){_magnifyOwned=NO;_magnifyDecided=NO;_magnifyCancelled=NO;}
            if(phase&NSEventPhaseMayBegin)return event;
            BOOL owned=_magnifyOwned;
            if(!_magnifyDecided&&(!(phase&(NSEventPhaseEnded|NSEventPhaseCancelled)))){_magnifyDecided=YES;NSUInteger epoch=_epoch;
                BOOL (^magnify)(NSEvent *)=_magnify;BOOL taken=enabled&&!self.hasNativeMousePress&&!NSEvent.pressedMouseButtons&&magnify&&magnify(appkit);
                if(epoch==_epoch&&_tap)_magnifyOwned=taken;
            }else if(owned&&!_magnifyCancelled){BOOL (^magnify)(NSEvent *)=_magnify;if(magnify)magnify(appkit);}
            BOOL taken=_magnifyOwned;
            if(terminal){_magnifyOwned=NO;_magnifyDecided=NO;_magnifyCancelled=NO;}
            return owned||taken?NULL:event;
        }
        return (_ownsTouches||_dockOwned)&&(appkit.type==NSEventTypeSwipe||appkit.type==NSEventTypeRotate||appkit.type==NSEventTypeSmartMagnify)?NULL:event;
    } @finally { _handling=NO; }
}
// A Dock-control packet. When a touch source holds the system's gestures back (the multitouch source's guard), its verdict is the whole answer, for
// every finger count and for packets of a format this file cannot decode as well as DockSwipes. With none delivering this tap's own rule applies: a
// DockSwipe whose beginning it saw while it owned the touch is dropped to its end, and, since nothing here can tell what another packet is, so is any
// other Dock-control packet while it owns an admitted touch of three or more fingers and for a moment after. Nothing is converted to an NSEvent.
- (CGEventRef)dockControl:(CGEventRef)event enabled:(BOOL)enabled {
    NSInteger axis=0,dockPhase=0;DWDockControlKind kind=DWDockControlClassify(event,&axis,&dockPhase);
    DWDockControlVerdict (^decision)(CGEventRef)=_dockDecision;
    DWDockControlVerdict verdict=decision?decision(event):DWDockControlUndecided;
    if(verdict!=DWDockControlUndecided){_dockOwned=NO;return verdict==DWDockControlDrop?NULL:event;}
    NSTimeInterval now=CACurrentMediaTime();BOOL owned;const char *reason;
    if(kind!=DWDockControlOther){
        if(dockPhase==kCGGesturePhaseBegan||dockPhase==kCGGesturePhaseMayBegin)_dockOwned=enabled&&!self.hasNativeMousePress&&(!NSEvent.pressedMouseButtons||_ownsTouches);
        owned=_dockOwned;reason=owned?"dock swipe began while this tap owned the touch":"dock swipe did not begin while this tap owned the touch";
        if(dockPhase==kCGGesturePhaseEnded||dockPhase==kCGGesturePhaseCancelled)_dockOwned=NO;
    }else{
        // An observed midstream packet cannot authorize stealing a gesture whose beginning already reached Dock.
        owned=enabled&&!self.hasNativeMousePress&&(_dockOwned||_ownsTouches||now<_dockTail);reason=owned?"packet of another format while this tap owns a touch":"packet of another format, no touch owned";
    }
    if(DWDebugTrace()){char detail[128];snprintf(detail,sizeof detail,"owns_touches=%d dock_owned=%d native_press=%d",(int)_ownsTouches,(int)_dockOwned,(int)self.hasNativeMousePress);DWDockControlTrace("global-tap",event,kind,owned?DWDockControlDrop:DWDockControlPass,reason,detail);}
    return owned?NULL:event;
}
- (void)stop {
    [self cancel];_epoch++;
    if(_tap){CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);}
    if(_source){CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CFRelease(_source);_source=NULL;}
    if(_tap){CFRelease(_tap);_tap=NULL;}
    _device=nil;_ownsTouches=_touchCancelled=NO;
    _magnifyOwned=_magnifyDecided=_magnifyCancelled=_dockOwned=_scrollOwned=NO;_dockTail=0;[_buttons removeAllIndexes];[_nativeButtons removeAllIndexes];
}
- (void)dealloc { _cancelled=nil;[self stop]; }
@end
static CGEventRef nativeInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;
    DWNativeInput *input=(__bridge DWNativeInput *)context;
    return [input handle:type event:event];
}
static CGEventRef nativeEarlyInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;
    return [(__bridge DWNativeInput *)context handleEarly:type event:event];
}
// A native-recipient decision only authorizes leaving the original packet
// alone. It never grants scope or permission to post to that process/window.
// Our own panel's unclaimed down must still reach AppKit: AppKit may then admit
// a captured pointer grab whose tails belong to the existing consumer.
static BOOL DWForeignMouseRecipient(CGEventRef event) {
    if(CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)==getpid())return NO;
    int64_t window=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!window)window=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    if(window>0&&window<=INT32_MAX)return [NSApp windowWithWindowNumber:(NSInteger)window]==nil;
    int64_t pid=CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID);
    return pid>0&&pid!=getpid();
}
// What the annotated tap asks for is exactly what -handle:event: acts on: the pointer buttons and motion, scroll, tablet
// packets and the gesture envelope that carries a magnify (the global trackpad tap's types). Nothing else, because an ACTIVE
// tap at the annotated location disturbs the volume, mute, brightness and media keys, however fast it returns and even when
// it returns every event untouched. Those keys are no key events on a Mac: they arrive system-defined (NX_SYSDEFINED, type
// 14, subtype 8, an aux control button). Measured on the guest (macOS 27.0.1, keys posted at the HID tap, bare pass-through
// taps in a throwaway probe, volume read back from 50):
//   - type 14 alone: volume up x3, down x2 and mute did nothing at all, every time; the same tap at the plain session or
//     the HID location did not do that, nor did an annotated one on the key types;
//   - every type but 14 and the keys: one burst of three presses in three or four lost a step. Bisected to type 13,
//     NSEventTypeAppKitDefined, which macOS itself posts as the volume moves: type 13 alone lost a step in 4 of 16 bursts, the
//     types 15, 16 and 17 and the three other groups of the remaining types lost none, and this mask lost none in 12.
CGEventMask DWNativeInputAnnotatedMask(void) {
    return CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventLeftMouseDragged)
        |CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventRightMouseDragged)
        |CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventOtherMouseDragged)
        |CGEventMaskBit(kCGEventMouseMoved)|CGEventMaskBit(kCGEventScrollWheel)
        |CGEventMaskBit(kCGEventTabletPointer)|CGEventMaskBit(kCGEventTabletProximity)|NSEventMaskGesture|NSEventMaskMagnify;
}
@implementation DWNativeInput {
    CFMachPortRef _tap,_earlyTap;
    CFRunLoopSourceRef _source,_earlySource;
    BOOL (^_consume)(CGEventType,CGEventRef);
    BOOL (^_earlyConsume)(CGEventType,CGEventRef);
    BOOL (^_ignoreEvent)(CGEventRef);
    void (^_cancelled)(void);
    NSMutableIndexSet *_capturedButtons,*_nativeButtons,*_earlyCompanionButtons;
    BOOL _capturedMagnify,_magnifyDecided,_magnifyCancelled;
    BOOL _earlyCaptured,_earlyCancelled,_earlyHandling,_stopped;
    NSUInteger _lifecycleEpoch,_cancellationEpoch;
    NSTimeInterval _earlyLastPacket;
}
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume earlyConsume:(BOOL (^)(CGEventType,CGEventRef))earlyConsume ignoreEvent:(BOOL (^)(CGEventRef))ignoreEvent cancelled:(void (^)(void))cancelled {
    if((self=[super init])){_consume=[consume copy];_earlyConsume=[earlyConsume copy];_ignoreEvent=[ignoreEvent copy];_cancelled=[cancelled copy];_capturedButtons=[NSMutableIndexSet indexSet];_nativeButtons=[NSMutableIndexSet indexSet];_earlyCompanionButtons=[NSMutableIndexSet indexSet];}
    return self;
}
- (BOOL)hasEarlyMousePress { return _earlyCaptured&&!_earlyCancelled&&!_stopped; }
// A chrome grab is exclusive. Secondary buttons get no native down and no
// controller action; their own tails remain swallowed after the primary lifts.
// A fresh down may retire a lost same-button release. Released other buttons
// retain tombstones but cannot permanently block a later independent gesture.
- (BOOL)consumeEarlyCompanion:(CGEventType)type event:(CGEventRef)event {
    if(!event)return NO;
    BOOL down=DWMouseDown(type);
    BOOL up=DWMouseUp(type);
    BOOL drag=DWMouseDragged(type);
    NSInteger button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);if(button<0||button>=32)return NO;
    if(down){
        NSUInteger lifecycle=_lifecycleEpoch;
        BOOL primaryHeld=_earlyCaptured&&CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft);
        if(button!=0&&_earlyCaptured&&!primaryHeld&&!_earlyCancelled){
            _earlyCancelled=YES;_cancellationEpoch++;void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
            if(_stopped||_lifecycleEpoch!=lifecycle)return NO;
        }
        BOOL held=NO;for(NSUInteger other=_earlyCompanionButtons.firstIndex;other!=NSNotFound;other=[_earlyCompanionButtons indexGreaterThanIndex:other])
            if(other!=(NSUInteger)button&&CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,(CGMouseButton)other)){held=YES;break;}
        if((primaryHeld&&button!=0)||held){
            if(button==0&&_earlyCaptured){_earlyCaptured=NO;_earlyCancelled=NO;void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();}
            if(_stopped||_lifecycleEpoch!=lifecycle)return NO;
            [_earlyCompanionButtons addIndex:(NSUInteger)button];return YES;
        }
        [_earlyCompanionButtons removeIndex:(NSUInteger)button];
    }else if((up||drag)&&[_earlyCompanionButtons containsIndex:(NSUInteger)button]){
        if(up)[_earlyCompanionButtons removeIndex:(NSUInteger)button];return YES;
    }
    return NO;
}
// Moves a held native button's ownership to the canvas, only from within nativeMouseOwnershipChanged. The application already has
// the press (and, if it began a window drag, the packets before this one); the consumer ends that with its own tagged release.
- (BOOL)takeNativeButton:(NSUInteger)button {
    if(_stopped||![_nativeButtons containsIndex:button])return NO;
    [_nativeButtons removeIndex:button];[_capturedButtons addIndex:button];return YES;
}
- (BOOL)holdsCapturedButton:(NSUInteger)button { return !_stopped&&[_capturedButtons containsIndex:button]; }
- (void)notifyNativeMouse:(CGEventRef)event {
    void (^changed)(CGEventRef,NSIndexSet *)=self.nativeMouseOwnershipChanged;
    if(changed)changed(event,_nativeButtons.copy);
}
- (void)cancelIdleEarlyMousePress {
    if(!self.hasEarlyMousePress||NSProcessInfo.processInfo.systemUptime-_earlyLastPacket<30
        ||CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft))return;
    _earlyCancelled=YES;_cancellationEpoch++;
    void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
}
- (BOOL)start {
    if(_tap)return YES;
    if(!AXIsProcessTrusted())return NO;
    // AppKit magnify events have no public CGEventType constant: they come in the
    // gesture envelope types (NSEventMaskGesture, NSEventMaskMagnify) and are
    // classified through NSEvent, as in the global tap. No other type is asked
    // for (DWNativeInputAnnotatedMask says why).
    CGEventMask mask=DWNativeInputAnnotatedMask();
    // The annotated location supplies the actual destination window. A canvas hit
    // alone could belong to a managed tile covered by an unrelated app or a menu.
    _tap=CGEventTapCreate(kCGAnnotatedSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,nativeInput,(__bridge void *)self);
    if(!_tap)return NO;
    _source=CFMachPortCreateRunLoopSource(NULL,_tap,0);
    if(!_source){CFMachPortInvalidate(_tap);CFRelease(_tap);_tap=NULL;return NO;}
    CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);
    // The annotated tap is too late to prevent WindowServer's native title
    // tracking from rebasing an already transformed window. Managed title,
    // green-control and qualified resize presses use the early chrome route;
    // unrecognized content keeps its annotated route.
    // Created last at the head, this also precedes the global trackpad tap.
    CGEventMask earlyMask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventLeftMouseUp)
        |CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseDragged)|CGEventMaskBit(kCGEventRightMouseUp)
        |CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseDragged)|CGEventMaskBit(kCGEventOtherMouseUp);
    _earlyTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,earlyMask,nativeEarlyInput,(__bridge void *)self);
    if(!_earlyTap){[self stop];return NO;}
    _earlySource=CFMachPortCreateRunLoopSource(NULL,_earlyTap,0);
    if(!_earlySource){[self stop];return NO;}
    CFRunLoopAddSource(CFRunLoopGetMain(),_earlySource,kCFRunLoopCommonModes);
    _stopped=NO;_lifecycleEpoch++;
    return YES;
}
- (CGEventRef)handleEarly:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        _cancellationEpoch++;
        if(_earlyCaptured)_earlyCancelled=YES;
        if(_capturedMagnify)_magnifyCancelled=YES;
        void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
        if(_earlyTap&&AXIsProcessTrusted())CGEventTapEnable(_earlyTap,true);
        return event;
    }
    if(!event||_earlyHandling||_stopped)return event;
    BOOL (^ignore)(CGEventRef)=_ignoreEvent;if(ignore&&ignore(event))return event;
    if([self consumeEarlyCompanion:type event:event])return NULL;
    BOOL down=type==kCGEventLeftMouseDown,tail=type==kCGEventLeftMouseDragged||type==kCGEventLeftMouseUp;
    if((!down&&!tail)||CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber)!=0)return event;
    _earlyHandling=YES;
    @try {
        if(down){
            // A new physical down retires a lost same-button release. Other
            // native/canvas pairs still reserve their original interaction.
            NSUInteger lifecycle=_lifecycleEpoch,cancellation=_cancellationEpoch;
            BOOL replaced=_earlyCaptured||[_capturedButtons containsIndex:0];
            _earlyCaptured=NO;_earlyCancelled=NO;
            [_capturedButtons removeIndex:0];BOOL native=[_nativeButtons containsIndex:0];[_nativeButtons removeIndex:0];
            if(native)[self notifyNativeMouse:NULL];
            if(replaced){void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();}
            if(_lifecycleEpoch!=lifecycle||_cancellationEpoch!=cancellation||_stopped)return event;
            if(_capturedButtons.count||_nativeButtons.count||_capturedMagnify)return event;
            BOOL (^earlyConsume)(CGEventType,CGEventRef)=_earlyConsume;
            BOOL taken=earlyConsume&&earlyConsume(type,event);
            // A synchronous consumer may stop this adapter or encounter a tap
            // cancellation. Teardown cannot resurrect ownership; cancellation
            // keeps only a tombstone for a down which was actually claimed.
            if(_lifecycleEpoch!=lifecycle||_stopped)return event;
            _earlyCaptured=taken;_earlyCancelled=taken&&_cancellationEpoch!=cancellation;
            if(taken)_earlyLastPacket=NSProcessInfo.processInfo.systemUptime;
            // A nested cancellation may precede the consumer's final gesture
            // installation. Cancel that final state as well as owning its tails.
            if(_earlyCancelled){void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();}
            return taken?NULL:event;
        }
        if(!_earlyCaptured)return event;
        // Logical cancellation never gives an app a tail without its down.
        // Tagged synthetic packets cannot retire this physical reservation.
        if(!_earlyCancelled){_earlyLastPacket=NSProcessInfo.processInfo.systemUptime;BOOL (^consume)(CGEventType,CGEventRef)=_consume;if(consume)consume(type,event);}
        if(type==kCGEventLeftMouseUp){_earlyCaptured=NO;_earlyCancelled=NO;}
        return NULL;
    } @finally {_earlyHandling=NO;}
}
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        _cancellationEpoch++;
        BOOL native=_nativeButtons.count!=0;
        // A disabled tap is not a physical release. Keep held native buttons
        // reserved so a second button cannot begin a competing canvas action.
        for(NSUInteger button=_nativeButtons.firstIndex;button!=NSNotFound;){
            NSUInteger next=[_nativeButtons indexGreaterThanIndex:button];
            if(!CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,(CGMouseButton)button))[_nativeButtons removeIndex:button];
            button=next;
        }
        if(native)[self notifyNativeMouse:NULL];
        if(_earlyCaptured)_earlyCancelled=YES;
        if(_capturedMagnify)_magnifyCancelled=YES;
        void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
        if(_tap&&AXIsProcessTrusted())CGEventTapEnable(_tap,true);
        return event;
    }
    // Not subscribed to (DWNativeInputAnnotatedMask), and never looked at if one arrives: they are macOS's own.
    if(type==(CGEventType)NSEventTypeSystemDefined)return event;
    // A Dock-control packet that reaches this tap has passed both session taps. It is not converted to an NSEvent (there is no type 30 to convert to,
    // and AppKit logs a line per packet) and is not touched; the shell may only note that it arrived.
    if(type==DWDockControlType){void (^seen)(CGEventRef)=_dockControl;if(seen&&event)seen(event);return event;}
    BOOL (^ignoreEvent)(CGEventRef)=_ignoreEvent;if(ignoreEvent&&ignoreEvent(event))return event;
    if([self consumeEarlyCompanion:type event:event])return NULL;
    BOOL (^consume)(CGEventType,CGEventRef)=_consume;
    if(type==kCGEventKeyDown||type==kCGEventKeyUp||type==kCGEventFlagsChanged)return event;
    if(type==kCGEventTabletPointer||type==kCGEventTabletProximity)return consume&&consume(type,event)?NULL:event;
    BOOL down=DWMouseDown(type);
    BOOL up=DWMouseUp(type);
    BOOL drag=DWMouseDragged(type);
    if(!down&&!up&&!drag&&type!=kCGEventScrollWheel&&type!=kCGEventMouseMoved){
        NSEvent *appkit=[NSEvent eventWithCGEvent:event];if(appkit.type!=NSEventTypeMagnify)return event;
        NSEventPhase phase=appkit.phase;
        if(phase&(NSEventPhaseBegan|NSEventPhaseMayBegin)){_capturedMagnify=NO;_magnifyDecided=NO;_magnifyCancelled=NO;}
        if(phase&NSEventPhaseMayBegin)return event;
        BOOL captured=_capturedMagnify;
        NSUInteger lifecycle=_lifecycleEpoch,cancellation=_cancellationEpoch;
        // A disabled tap cancelled the logical pinch. Its already claimed
        // physical tail stays swallowed, but cannot begin another pinch in the
        // consumer after that consumer has cleared its gesture state.
        BOOL taken=!_magnifyCancelled&&(!_magnifyDecided||captured)&&consume&&consume(type,event);
        if(_lifecycleEpoch!=lifecycle||_stopped)return captured||taken?NULL:event;
        _magnifyDecided=YES;
        if(taken)_capturedMagnify=YES;
        if(_cancellationEpoch!=cancellation&&_capturedMagnify){
            _magnifyCancelled=YES;
            // A nested cancellation may precede final gesture installation.
            void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
        }
        if(phase==NSEventPhaseNone||(phase&(NSEventPhaseEnded|NSEventPhaseCancelled))){_capturedMagnify=NO;_magnifyDecided=NO;_magnifyCancelled=NO;}
        return captured||taken?NULL:event;
    }
    NSInteger button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
    BOOL validButton=button>=0&&button<32;
    // If the earlier tap was disabled, its swallowed down still owns this pair.
    // Cancel logical delivery and suppress the late-stage tail exactly once.
    if(validButton&&button==0&&_earlyCaptured&&(down||drag||up)){
        if(!_earlyCancelled){_earlyCancelled=YES;void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();}
        if(down||up){_earlyCaptured=NO;_earlyCancelled=NO;}
        if(!down)return NULL;
    }
    // A fresh press proves an earlier release was lost. It starts its own pair.
    if(down&&validButton){[_capturedButtons removeIndex:(NSUInteger)button];BOOL native=[_nativeButtons containsIndex:(NSUInteger)button];[_nativeButtons removeIndex:(NSUInteger)button];if(native)[self notifyNativeMouse:NULL];}
    BOOL captured=(drag||up)&&validButton&&[_capturedButtons containsIndex:(NSUInteger)button];
    BOOL nativePair=(drag||up)&&validButton&&[_nativeButtons containsIndex:(NSUInteger)button];
    // Leave an unclaimed native press and its physical tails untouched. The
    // destination may change during an AppKit drag, but button ownership must
    // not change with the window now under the pointer. A second button cannot
    // begin a canvas action inside that native drag either.
    if(!captured&&(nativePair||(_nativeButtons.count&&down)||(_nativeButtons.count&&type==kCGEventMouseMoved))){
        if(down&&validButton)[_nativeButtons addIndex:(NSUInteger)button];
        if(up&&validButton)[_nativeButtons removeIndex:(NSUInteger)button];
        if(down||up||drag)[self notifyNativeMouse:event];
        // The consumer may take a held native drag over from inside that callback (-takeNativeButton:). This packet and the rest
        // of the physical pair are then the canvas's: swallowed here, delivered through consume like any owned tail.
        if(drag&&validButton&&[_capturedButtons containsIndex:(NSUInteger)button]&&![_nativeButtons containsIndex:(NSUInteger)button])return NULL;
        return event;
    }
    BOOL taken=consume&&consume(type,event);
    if(down&&taken&&validButton)[_capturedButtons addIndex:(NSUInteger)button];
    if(down&&!taken&&validButton&&DWForeignMouseRecipient(event)){[_nativeButtons addIndex:(NSUInteger)button];[self notifyNativeMouse:event];}
    if(up&&captured)[_capturedButtons removeIndex:(NSUInteger)button];
    // Cancellation may have ended the canvas grab while the physical button was
    // still down. Its remaining drag/release must not start input in an app which
    // never received the press. Keep each cancelled pair until its own release,
    // even if a second button has started another canvas gesture meanwhile.
    return taken||captured?NULL:event;
}
- (void)stop {
    _stopped=YES;_lifecycleEpoch++;
    if(_earlyTap){CGEventTapEnable(_earlyTap,false);CFMachPortInvalidate(_earlyTap);}
    if(_earlySource){CFRunLoopRemoveSource(CFRunLoopGetMain(),_earlySource,kCFRunLoopCommonModes);CFRelease(_earlySource);_earlySource=NULL;}
    if(_earlyTap){CFRelease(_earlyTap);_earlyTap=NULL;}
    if(_tap){CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);}
    if(_source){CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CFRelease(_source);_source=NULL;}
    if(_tap){CFRelease(_tap);_tap=NULL;}
    [_capturedButtons removeAllIndexes];
    [_earlyCompanionButtons removeAllIndexes];
    BOOL native=_nativeButtons.count!=0;[_nativeButtons removeAllIndexes];if(native)[self notifyNativeMouse:NULL];
    _capturedMagnify=NO;_magnifyDecided=NO;_magnifyCancelled=NO;
    _earlyCaptured=NO;_earlyCancelled=NO;
    void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
}
- (void)dealloc {
    // The desktop stops this before releasing its views. No callback into its
    // consumer is needed while deallocating the bridge.
    _cancelled=nil;[self stop];
}
@end
