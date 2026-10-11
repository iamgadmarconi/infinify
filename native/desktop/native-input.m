// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-input.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@interface DWNativeInput ()
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event;
@end
static CGEventRef nativeInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;
    DWNativeInput *input=(__bridge DWNativeInput *)context;
    return [input handle:type event:event];
}
@implementation DWNativeInput {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    BOOL (^_consume)(CGEventType,CGEventRef);
    void (^_cancelled)(void);
    NSMutableIndexSet *_capturedButtons;
    BOOL _capturedMagnify,_magnifyDecided;
}
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume cancelled:(void (^)(void))cancelled {
    if((self=[super init])){_consume=[consume copy];_cancelled=[cancelled copy];_capturedButtons=[NSMutableIndexSet indexSet];}
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
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
        if(_tap&&AXIsProcessTrusted())CGEventTapEnable(_tap,true);
        return event;
    }
    BOOL (^consume)(CGEventType,CGEventRef)=_consume;
    if(type==kCGEventKeyDown||type==kCGEventKeyUp||type==kCGEventFlagsChanged)return event;
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
    // A fresh press proves an earlier release was lost. It starts its own pair.
    if(down&&validButton)[_capturedButtons removeIndex:(NSUInteger)button];
    BOOL captured=(drag||up)&&validButton&&[_capturedButtons containsIndex:(NSUInteger)button];
    BOOL taken=consume&&consume(type,event);
    if(down&&taken&&validButton)[_capturedButtons addIndex:(NSUInteger)button];
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
    _capturedMagnify=NO;_magnifyDecided=NO;
    void (^cancelled)(void)=_cancelled;if(cancelled)cancelled();
}
- (void)dealloc {
    // The desktop stops this before releasing its views. No callback into its
    // consumer is needed while deallocating the bridge.
    _cancelled=nil;[self stop];
}
@end
