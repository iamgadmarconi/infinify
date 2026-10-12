// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-input.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "trackpad-gestures.h"
#import "native-tablet.h"
#include <unistd.h>

@interface DWNativeInput ()
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event;
@end

// DockSwipe field/type/phase decoding adapted from joshuarli/iss, commit
// 493b008f2ea8e9215877c39700e8ea3add800e97, iss.c (cb, lines 436-515):
// https://github.com/joshuarli/iss/blob/493b008f2ea8e9215877c39700e8ea3add800e97/iss.c
// Copyright (c) 2026 joshuarli
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted.
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
// OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.
// Vertical/pinch axis values are documented in the original Mac Mouse Fix
// TouchSimulator.m at 3c10736888c51926d70392ac1eb5c7cb98f6e231 (no code copied):
// https://github.com/noah-nuebling/mac-mouse-fix/blob/3c10736888c51926d70392ac1eb5c7cb98f6e231/Helper/Core/Touch/TouchSimulator.m
// These are event fields, not linked private functions. Neither a successful tap
// nor these source references establishes runtime suppression on a future ABI.
static const CGEventField DWGestureRealType=55,DWGestureHIDType=110,DWGestureAxis=123,DWGesturePhase=132;
static BOOL DWDockSwipe(CGEventRef event,NSInteger *phase) {
    if(CGEventGetIntegerValueField(event,DWGestureRealType)!=30||CGEventGetIntegerValueField(event,DWGestureHIDType)!=23)return NO;
    NSInteger axis=(NSInteger)CGEventGetIntegerValueField(event,DWGestureAxis),p=(NSInteger)CGEventGetIntegerValueField(event,DWGesturePhase);
    if(axis<1||axis>3||!(p==kCGGesturePhaseBegan||p==kCGGesturePhaseChanged||p==kCGGesturePhaseEnded||p==kCGGesturePhaseCancelled||p==kCGGesturePhaseMayBegin))return NO;
    *phase=p;return YES;
}

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
        NSInteger dockPhase=0;
        if(DWDockSwipe(event,&dockPhase)){
            if(dockPhase==kCGGesturePhaseBegan||dockPhase==kCGGesturePhaseMayBegin)_dockOwned=enabled&&!self.hasNativeMousePress&&(!NSEvent.pressedMouseButtons||_ownsTouches);
            BOOL owned=_dockOwned;
            if(dockPhase==kCGGesturePhaseEnded||dockPhase==kCGGesturePhaseCancelled)_dockOwned=NO;
            // An observed midstream packet cannot authorize stealing a gesture
            // whose beginning already reached Dock. Raw touch evidence supplies
            // actions; the Dock packet supplies cancellation authority only.
            if(owned)result=NULL;
            return result;
        }
        if(DWNativeTabletEvent(event))return event;
        BOOL down=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
        BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
        BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
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
                if(!frame.fingers&&epoch==_epoch){_device=nil;_ownsTouches=NO;_touchCancelled=NO;}
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
- (void)stop {
    [self cancel];_epoch++;
    if(_tap){CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);}
    if(_source){CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CFRelease(_source);_source=NULL;}
    if(_tap){CFRelease(_tap);_tap=NULL;}
    _device=nil;_ownsTouches=_touchCancelled=NO;
    _magnifyOwned=_magnifyDecided=_magnifyCancelled=_dockOwned=_scrollOwned=NO;[_buttons removeAllIndexes];[_nativeButtons removeAllIndexes];
}
- (void)dealloc { _cancelled=nil;[self stop]; }
@end
static CGEventRef nativeInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;
    DWNativeInput *input=(__bridge DWNativeInput *)context;
    return [input handle:type event:event];
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
@implementation DWNativeInput {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    BOOL (^_consume)(CGEventType,CGEventRef);
    BOOL (^_ignoreEvent)(CGEventRef);
    void (^_cancelled)(void);
    NSMutableIndexSet *_capturedButtons,*_nativeButtons;
    BOOL _capturedMagnify,_magnifyDecided;
}
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume cancelled:(void (^)(void))cancelled {
    return [self initWithConsume:consume ignoreEvent:nil cancelled:cancelled];
}
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume ignoreEvent:(BOOL (^)(CGEventRef))ignoreEvent cancelled:(void (^)(void))cancelled {
    if((self=[super init])){_consume=[consume copy];_ignoreEvent=[ignoreEvent copy];_cancelled=[cancelled copy];_capturedButtons=[NSMutableIndexSet indexSet];_nativeButtons=[NSMutableIndexSet indexSet];}
    return self;
}
- (BOOL)start {
    if(_tap)return YES;
    if(!AXIsProcessTrusted())return NO;
    // AppKit magnify events have no public CGEventType constant. Ask for the
    // public all-events mask and classify through NSEvent, without inventing a
    // private event number. Keys and unrelated events are returned untouched.
    CGEventMask mask=kCGEventMaskForAllEvents;
    // The annotated location supplies the actual destination window. A canvas hit
    // alone could belong to a managed tile covered by an unrelated app or a menu.
    _tap=CGEventTapCreate(kCGAnnotatedSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,nativeInput,(__bridge void *)self);
    if(!_tap)return NO;
    _source=CFMachPortCreateRunLoopSource(NULL,_tap,0);
    if(!_source){CFMachPortInvalidate(_tap);CFRelease(_tap);_tap=NULL;return NO;}
    CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);
    return YES;
}
- (void)observeNativeMouse:(CGEventType)type event:(CGEventRef)event {
    void (^observe)(CGEventType,CGPoint,uint32_t)=self.nativeMouse;if(!observe)return;
    uint32_t buttons=0;for(NSUInteger i=_nativeButtons.firstIndex;i!=NSNotFound;i=[_nativeButtons indexGreaterThanIndex:i])buttons|=UINT32_C(1)<<i;
    observe(type,CGEventGetLocation(event),buttons);
}
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        [_nativeButtons removeAllIndexes];
        void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
        if(_tap&&AXIsProcessTrusted())CGEventTapEnable(_tap,true);
        return event;
    }
    BOOL (^ignoreEvent)(CGEventRef)=_ignoreEvent;if(ignoreEvent&&ignoreEvent(event))return event;
    BOOL (^consume)(CGEventType,CGEventRef)=_consume;
    if(type==kCGEventKeyDown||type==kCGEventKeyUp||type==kCGEventFlagsChanged)return event;
    if(type==kCGEventTabletPointer||type==kCGEventTabletProximity)return consume&&consume(type,event)?NULL:event;
    BOOL down=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    if(!down&&!up&&!drag&&type!=kCGEventScrollWheel&&type!=kCGEventMouseMoved){
        NSEvent *appkit=[NSEvent eventWithCGEvent:event];if(appkit.type!=NSEventTypeMagnify)return event;
        NSEventPhase phase=appkit.phase;
        if(phase&(NSEventPhaseBegan|NSEventPhaseMayBegin)){_capturedMagnify=NO;_magnifyDecided=NO;}
        if(phase&NSEventPhaseMayBegin)return event;
        BOOL captured=_capturedMagnify,taken=(!_magnifyDecided||captured)&&consume&&consume(type,event);
        _magnifyDecided=YES;
        if(taken)_capturedMagnify=YES;
        if(phase==NSEventPhaseNone||(phase&(NSEventPhaseEnded|NSEventPhaseCancelled))){_capturedMagnify=NO;_magnifyDecided=NO;}
        return captured||taken?NULL:event;
    }
    NSInteger button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
    BOOL validButton=button>=0&&button<32;
    BOOL replacedNative=down&&validButton&&[_nativeButtons containsIndex:(NSUInteger)button];
    // A fresh press proves an earlier release was lost. It starts its own pair.
    if(down&&validButton){[_capturedButtons removeIndex:(NSUInteger)button];[_nativeButtons removeIndex:(NSUInteger)button];}
    BOOL captured=(drag||up)&&validButton&&[_capturedButtons containsIndex:(NSUInteger)button];
    BOOL nativePair=(drag||up)&&validButton&&[_nativeButtons containsIndex:(NSUInteger)button];
    // Leave an unclaimed native press and its physical tails untouched. The
    // destination may change during an AppKit drag, but button ownership must
    // not change with the window now under the pointer. A second button cannot
    // begin a canvas action inside that native drag either.
    if(!captured&&(nativePair||(_nativeButtons.count&&down)||(_nativeButtons.count&&type==kCGEventMouseMoved))){
        if(down&&validButton)[_nativeButtons addIndex:(NSUInteger)button];
        if(up&&validButton)[_nativeButtons removeIndex:(NSUInteger)button];
        [self observeNativeMouse:type event:event];
        return event;
    }
    BOOL taken=consume&&consume(type,event);
    if(down&&taken&&validButton)[_capturedButtons addIndex:(NSUInteger)button];
    if(down&&!taken&&validButton&&DWForeignMouseRecipient(event)){[_nativeButtons addIndex:(NSUInteger)button];[self observeNativeMouse:type event:event];}
    else if(replacedNative)[self observeNativeMouse:type event:event];
    if(up&&captured)[_capturedButtons removeIndex:(NSUInteger)button];
    // Cancellation may have ended the canvas grab while the physical button was
    // still down. Its remaining drag/release must not start input in an app which
    // never received the press. Keep each cancelled pair until its own release,
    // even if a second button has started another canvas gesture meanwhile.
    return taken||captured?NULL:event;
}
- (void)stop {
    if(_tap){CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);}
    if(_source){CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CFRelease(_source);_source=NULL;}
    if(_tap){CFRelease(_tap);_tap=NULL;}
    [_capturedButtons removeAllIndexes];
    [_nativeButtons removeAllIndexes];
    _capturedMagnify=NO;_magnifyDecided=NO;
    void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
}
- (void)dealloc {
    // The desktop stops this before releasing its views. No callback into its
    // consumer is needed while deallocating the bridge.
    _cancelled=nil;[self stop];
}
@end
