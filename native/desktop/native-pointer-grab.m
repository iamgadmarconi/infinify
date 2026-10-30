// SPDX-License-Identifier: GPL-3.0-or-later
// Original adapter-only mouse delivery state. CoreGraphics packet copies retain
// deltas, flags, click state and pressure fields; the caller applies native
// addressing/tagging to the copy. No private ABI or native mutation is used here.
#import "native-pointer-grab.h"
#import "native-tablet.h"
#include <math.h>

static BOOL pointerMouse(CGEventRef event) {
    if(!event||DWNativeTabletEvent(event))return NO;CGEventType type=CGEventGetType(event);
    return DWMouseForwardable(type);
}
// Copy nested target dictionaries too: a caller's mutable native_bounds or
// identity must not silently alter the already-admitted recipient.
static id pointerFreeze(id value,NSUInteger depth) {
    if(!value||depth>16)return nil;
    if([value isKindOfClass:NSDictionary.class]){
        if([value count]>128)return nil;NSMutableDictionary *copy=[NSMutableDictionary dictionary];
        for(id key in value){if(![key isKindOfClass:NSString.class])return nil;id item=pointerFreeze(value[key],depth+1);if(!item)return nil;copy[[key copy]]=item;}
        return copy.copy;
    }
    if([value isKindOfClass:NSArray.class]){
        if([value count]>128)return nil;NSMutableArray *copy=[NSMutableArray array];
        for(id item in value){id frozen=pointerFreeze(item,depth+1);if(!frozen)return nil;[copy addObject:frozen];}return copy.copy;
    }
    if([value isKindOfClass:NSString.class]||[value isKindOfClass:NSNumber.class])return [value copy];
    return value==NSNull.null?value:nil;
}
static BOOL pointerInteger(id value,uint64_t maximum,BOOL nonzero) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;
    double number=[value doubleValue];
    return isfinite(number)&&floor(number)==number&&[value compare:@(nonzero?1:0)]!=NSOrderedAscending&&[value compare:@(maximum)]!=NSOrderedDescending;
}
static BOOL pointerIdentity(id identity) {
    return [identity isKindOfClass:NSDictionary.class]&&pointerInteger(identity[@"pid"],INT32_MAX,YES)
        &&pointerInteger(identity[@"wid"],UINT32_MAX,YES)&&pointerInteger(identity[@"birth_sec"],UINT64_MAX,NO)&&pointerInteger(identity[@"birth_usec"],999999,NO);
}
static NSDictionary *pointerKey(NSDictionary *target) {
    if(![target isKindOfClass:NSDictionary.class])return nil;NSDictionary *identity=target[@"identity"],*root=target[@"root_identity"]?:identity;
    if(!pointerIdentity(identity)||!pointerIdentity(root)||!pointerInteger(target[@"generation"],UINT64_MAX,NO)
        ||!pointerInteger(target[@"window"],UINT64_MAX,NO)||!pointerInteger(target[@"output"],UINT64_MAX,NO))return nil;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec"])if(![identity[key]isEqual:root[key]])return nil;
    if(target[@"native_member"]&&![target[@"native_member"]isKindOfClass:NSNumber.class])return nil;
    return @{@"identity":identity,@"root_identity":root,@"generation":target[@"generation"],@"window":target[@"window"],@"output":target[@"output"],@"native_member":@([target[@"native_member"]boolValue])};
}
static BOOL pointerLocal(id value,CGPoint *out) {
    if(![value isKindOfClass:NSDictionary.class]||![value[@"x"]isKindOfClass:NSNumber.class]||![value[@"y"]isKindOfClass:NSNumber.class])return NO;
    CGPoint p=CGPointMake([value[@"x"]doubleValue],[value[@"y"]doubleValue]);if(!isfinite(p.x)||!isfinite(p.y))return NO;*out=p;return YES;
}

@interface DWPointerButton : NSObject { @public CGEventRef down; }
@property BOOL paired,inFlight,releaseRequested;
@end
@implementation DWPointerButton
- (void)dealloc { if(down)CFRelease(down); }
@end
@interface DWPointerRecipient : NSObject
@property NSDictionary *target,*key;
@property CGPoint local;
@property NSMutableDictionary<NSNumber *,DWPointerButton *> *buttons;
@property BOOL cancelled;
@property(copy) DWNativePointerValidate validate;
@property(copy) DWNativePointerPost post;
@end
@implementation DWPointerRecipient
- (instancetype)init { if((self=[super init]))_buttons=[NSMutableDictionary dictionary];return self; }
@end

@implementation DWNativePointerGrab {
    DWPointerRecipient *_recipient;
    uint32_t _physical;
    NSMutableSet<NSNumber *> *_unsupportedPhysical;
    NSMutableArray<DWPointerRecipient *> *_cancelled;
    uint64_t _revision;
    BOOL _busy;
}
- (instancetype)init {
    if((self=[super init])){_unsupportedPhysical=[NSMutableSet set];_cancelled=[NSMutableArray array];}return self;
}
- (NSDictionary *)target { return _recipient.target; }
- (BOOL)active { return _recipient!=nil; }
- (BOOL)suppressed { return !_recipient&&(_physical||_unsupportedPhysical.count); }
- (BOOL)ownsEvent:(CGEventRef)event { return NSThread.isMainThread&&pointerMouse(event)&&(_physical||_unsupportedPhysical.count||_busy); }
- (BOOL)admitEvent:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local {
    if(!NSThread.isMainThread||_busy||_recipient||_physical||_unsupportedPhysical.count||!pointerMouse(event)||!DWMouseDown(CGEventGetType(event))||!isfinite(local.x)||!isfinite(local.y))return NO;
    int64_t button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);if(button<0||button>=32)return NO;
    NSDictionary *frozen=pointerFreeze(target,0),*key=pointerKey(frozen);if(!key)return NO;
    DWPointerButton *packet=[DWPointerButton new];packet->down=CGEventCreateCopy(event);if(!packet->down)return NO;packet.paired=YES;
    DWPointerRecipient *recipient=[DWPointerRecipient new];recipient.target=frozen;recipient.key=key;recipient.local=local;recipient.buttons[@(button)]=packet;
    ++_revision;_physical=1u<<(uint32_t)button;_recipient=recipient;return YES;
}
- (void)observePhysical:(CGEventRef)event {
    CGEventType type=CGEventGetType(event);if(!DWMouseDown(type)&&!DWMouseUp(type))return;
    int64_t button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
    if(button>=0&&button<32){uint32_t bit=1u<<(uint32_t)button;if(DWMouseDown(type))_physical|=bit;else _physical&=~bit;}
    else if(DWMouseDown(type))[_unsupportedPhysical addObject:@(button)];else [_unsupportedPhysical removeObject:@(button)];
}
- (void)queueCancellation:(DWPointerRecipient *)recipient validate:(DWNativePointerValidate)validate post:(DWNativePointerPost)post {
    if(!recipient||recipient.cancelled)return;
    recipient.cancelled=YES;recipient.validate=validate;recipient.post=post;
    for(DWPointerButton *button in recipient.buttons.objectEnumerator)button.releaseRequested=YES;
    [_cancelled addObject:recipient];
}
- (void)drainCancellations {
    if(_busy)return;_busy=YES;
    @try {
        while(_cancelled.count){
            DWPointerRecipient *recipient=_cancelled.firstObject;[_cancelled removeObjectAtIndex:0];
            for(NSNumber *number in [recipient.buttons.allKeys sortedArrayUsingSelector:@selector(compare:)]){
                DWPointerButton *button=recipient.buttons[number];
                // An in-flight down/up is resolved before this drain runs. A
                // successful up already paired the press; a failed up still
                // needs this release. An unposted down authorizes no release.
                if(!button.paired||button.inFlight||!button.releaseRequested||!button->down)continue;
                button.paired=NO;uint64_t revision=_revision;
                CGEventRef up=NULL;
                @try {
                    if(!recipient.validate||!recipient.post||!recipient.validate(recipient.target)||revision!=_revision)continue;
                    up=CGEventCreateCopy(button->down);if(!up)continue;uint32_t index=number.unsignedIntValue;
                    CGEventSetType(up,index==kCGMouseButtonLeft?kCGEventLeftMouseUp:index==kCGMouseButtonRight?kCGEventRightMouseUp:kCGEventOtherMouseUp);
                    CGEventSetIntegerValueField(up,kCGMouseEventButtonNumber,index);CGEventSetDoubleValueField(up,kCGMouseEventPressure,0);
                    CGEventSetTimestamp(up,(CGEventTimestamp)(NSProcessInfo.processInfo.systemUptime*1.e9));
                    recipient.post(up,recipient.target,recipient.local);
                } @catch(NSException *exception) {
                    // One failed callback cannot skip releases owed to other
                    // buttons. Never retry a post that may already have sent.
                    (void)exception;
                } @finally {if(up)CFRelease(up);}
            }
        }
    } @finally {_busy=NO;}
}
- (void)cancelWithValidate:(DWNativePointerValidate)validate post:(DWNativePointerPost)post {
    if(!NSThread.isMainThread)return;++_revision;DWPointerRecipient *recipient=_recipient;_recipient=nil;
    // Keep _physical unchanged. Synthetic ups release the application, not the
    // physical mouse; its remaining tails cannot enter another source.
    [self queueCancellation:recipient validate:validate post:post];[self drainCancellations];
}
- (BOOL)forwardEvent:(CGEventRef)event screen:(CGPoint)screen resolve:(DWNativePointerResolve)resolve validate:(DWNativePointerValidate)validate post:(DWNativePointerPost)post {
    if(![self ownsEvent:event])return NO;
    if(_busy){
        // A callback can run a nested event loop. Consume and remember real
        // physical transitions, but never recursively post or start a new grab.
        [self observePhysical:event];
        // A detached cancellation already owes its validated releases. Merely
        // observing a nested physical tail must not invalidate those callbacks;
        // explicit caller cancellation/reset still advances the revision.
        if(_recipient)[self cancelWithValidate:validate post:post];return NO;
    }
    uint32_t before=_physical;[self observePhysical:event];DWPointerRecipient *recipient=_recipient;
    if(!recipient)return NO;uint64_t revision=++_revision;_busy=YES;BOOL sent=NO;CGEventRef copy=NULL;
    DWPointerButton *packet=nil;CGEventType type=CGEventGetType(event);int64_t index=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
    @try {
        BOOL buttonEvent=DWMouseDown(type)||DWMouseUp(type)||DWMouseDragged(type);
        if(buttonEvent&&(index<0||index>=32)){[self cancelWithValidate:validate post:post];return NO;}
        uint32_t bit=buttonEvent?1u<<(uint32_t)index:0;
        // A second physical down for an already-held button means a release
        // was lost. Pair the old recipient and suppress this new press's tails;
        // it must never inherit an old application press or select a new one.
        if(DWMouseDown(type)&&(before&bit)){[self cancelWithValidate:validate post:post];return NO;}
        // No up/drag half of a press owned elsewhere.
        if((DWMouseUp(type)||DWMouseDragged(type))&&!(before&bit))return NO;
        if(!resolve||!validate||!post||!isfinite(screen.x)||!isfinite(screen.y)){[self cancelWithValidate:validate post:post];return NO;}
        NSDictionary *result=resolve(recipient.target,screen);
        if(revision!=_revision||_recipient!=recipient)return NO;
        NSDictionary *target=[result isKindOfClass:NSDictionary.class]?pointerFreeze(result[@"target"],0):nil;CGPoint local=CGPointZero;
        if(![pointerKey(target)isEqual:recipient.key]||!pointerLocal(result[@"local"],&local)){
            [self cancelWithValidate:validate post:post];return NO;
        }
        BOOL valid=validate(target);if(revision!=_revision||_recipient!=recipient)return NO;
        if(!valid){[self cancelWithValidate:validate post:post];return NO;}
        copy=CGEventCreateCopy(event);if(!copy){[self cancelWithValidate:validate post:post];return NO;}
        if(DWMouseDown(type)){
            packet=[DWPointerButton new];packet->down=CGEventCreateCopy(event);
            if(!packet->down){[self cancelWithValidate:validate post:post];return NO;}recipient.buttons[@(index)]=packet;
        }else if(DWMouseUp(type))packet=recipient.buttons[@(index)];
        if(packet)packet.inFlight=YES;
        sent=post(copy,target,local);
        if(packet){packet.inFlight=NO;if(sent&&DWMouseDown(type))packet.paired=YES;else if(sent&&DWMouseUp(type))packet.paired=NO;}
        if(sent){recipient.target=target;recipient.local=local;}
        if(revision!=_revision||_recipient!=recipient){
            // Cancellation/reset inside post must also pair a down that post
            // admitted only after the callback had detached this recipient.
            if(sent&&!recipient.cancelled)[self queueCancellation:recipient validate:validate post:post];return sent;
        }
        if(!sent){[self cancelWithValidate:validate post:post];return NO;}
        if(DWMouseUp(type))[recipient.buttons removeObjectForKey:@(index)];
        if(!_physical&&!_unsupportedPhysical.count)_recipient=nil;
        return sent;
    } @catch(NSException *exception) {
        // An exception from post does not prove that the down was never sent.
        // Close that uncertain pair through the same validated recipient too.
        (void)exception;if(packet){if(packet.inFlight&&DWMouseDown(type))packet.paired=YES;packet.inFlight=NO;}
        [self cancelWithValidate:validate post:post];return NO;
    } @finally {
        if(copy)CFRelease(copy);_busy=NO;[self drainCancellations];
    }
}
- (void)reset {
    if(!NSThread.isMainThread)return;++_revision;_recipient=nil;_physical=0;[_unsupportedPhysical removeAllObjects];
    // Explicit cancellation queued during a callback still owes its pairing.
    // Its detached recipient never becomes active again after this reset.
    if(!_busy)[_cancelled removeAllObjects];
}
@end
