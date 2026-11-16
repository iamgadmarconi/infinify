// SPDX-License-Identifier: GPL-3.0-or-later
// Physical pairing moved verbatim from DWNativeInput.m at 7d4a6d6.
#import "DWPressPairing.h"
#import "DWNativeInput.h"
#import "DWTrackpadGestures.h"
#import "DWNativeTabletRouter.h"
#import <AppKit/AppKit.h>
#include <unistd.h>
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
@implementation DWPressPairing {
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
- (void)detachConsumer { _cancelled=nil; }
- (void)started { _stopped=NO;_lifecycleEpoch++; }
- (CGEventRef)handleEarly:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        _cancellationEpoch++;
        if(_earlyCaptured)_earlyCancelled=YES;
        if(_capturedMagnify)_magnifyCancelled=YES;
        void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
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
- (void)beginStop { _stopped=YES;_lifecycleEpoch++; }
- (void)discardPairs {
    [_capturedButtons removeAllIndexes];
    [_earlyCompanionButtons removeAllIndexes];
    BOOL native=_nativeButtons.count!=0;[_nativeButtons removeAllIndexes];if(native)[self notifyNativeMouse:NULL];
    _capturedMagnify=NO;_magnifyDecided=NO;_magnifyCancelled=NO;
    _earlyCaptured=NO;_earlyCancelled=NO;
    void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
}
- (void)dealloc { _cancelled=nil;[self beginStop];[self discardPairs]; }
@end
