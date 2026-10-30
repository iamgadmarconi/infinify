// SPDX-License-Identifier: GPL-3.0-or-later
#import "hotkeys.h"
#import "typed-value.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

static const UInt32 chordModifiers=cmdKey|shiftKey|optionKey|controlKey;
NSNumber *DWChord(uint32_t keyCode,uint32_t carbonModifiers) { return @((keyCode<<16)|(carbonModifiers&chordModifiers)); }
NSString *DWModifierGlyphs(uint32_t m) { return [NSString stringWithFormat:@"%@%@%@%@",m&controlKey?@"⌃":@"",m&optionKey?@"⌥":@"",m&shiftKey?@"⇧":@"",m&cmdKey?@"⌘":@""]; }
static UInt32 heldModifiers(void) { NSEventModifierFlags f=NSEvent.modifierFlags;return (f&NSEventModifierFlagControl?controlKey:0)|(f&NSEventModifierFlagOption?optionKey:0)|(f&NSEventModifierFlagShift?shiftKey:0)|(f&NSEventModifierFlagCommand?cmdKey:0); }
// ANSI keypad positions keep their identity: keypad 1 is never the key that types "1".
static BOOL keypad(UInt32 code) { return code==65||code==67||code==69||code==71||code==75||code==76||code==78||(code>=81&&code<=92&&code!=90); }
static NSString *keyName(UInt32 code) {
    static NSDictionary<NSNumber *,NSString *> *names;static dispatch_once_t once;
    dispatch_once(&once,^{names=@{@36:@"↩",@48:@"⇥",@49:@"Space",@51:@"⌫",@53:@"Esc",@117:@"⌦",@115:@"↖",@119:@"↘",@116:@"⇞",@121:@"⇟",@123:@"←",@124:@"→",@125:@"↓",@126:@"↑",@114:@"Help",@71:@"Clear",@76:@"⌤",
        @122:@"F1",@120:@"F2",@99:@"F3",@118:@"F4",@96:@"F5",@97:@"F6",@98:@"F7",@100:@"F8",@101:@"F9",@109:@"F10",@103:@"F11",@111:@"F12",@105:@"F13",@107:@"F14",@113:@"F15",@106:@"F16",@64:@"F17",@79:@"F18",@80:@"F19",@90:@"F20"};});
    return names[@(code)];
}
// The current layout's translation table; nil when no input source publishes one.
static NSData *keyboardLayout(void) {
    TISInputSourceRef sources[]={TISCopyCurrentKeyboardLayoutInputSource(),TISCopyCurrentASCIICapableKeyboardLayoutInputSource()};NSData *layout=nil;
    for(int i=0;i<2;i++){CFDataRef data=sources[i]&&!layout?(CFDataRef)TISGetInputSourceProperty(sources[i],kTISPropertyUnicodeKeyLayoutData):NULL;if(data)layout=[(__bridge NSData *)data copy];if(sources[i])CFRelease(sources[i]);}
    return layout;
}
// What a key types with or without Shift; nil for control, blank and untranslated output.
static NSString *keyCharacter(NSData *layout,UInt32 code,BOOL shift) {
    UInt32 dead=0;UniChar characters[4];UniCharCount length=0;
    if(!layout||UCKeyTranslate(layout.bytes,(UInt16)code,kUCKeyActionDisplay,shift?shiftKey>>8:0,LMGetKbdType(),kUCKeyTranslateNoDeadKeysMask,&dead,4,&length,characters)!=noErr||!length||characters[0]<=' '||characters[0]==0x7F)return nil;
    return [NSString stringWithCharacters:characters length:length];
}
// The key that types `character`: the binding's own ANSI position while it still
// does, else the lowest other key. Unshifted, and only for a chord that holds Shift
// with Shift as well: upstream's combo carries Shift, so a character that needs it
// never lands on a chord without it.
static NSNumber *keyTyping(NSData *layout,NSString *character,NSNumber *own,BOOL shifted) {
    NSString *wanted=character.lowercaseString;
    for(int shift=0;shift<=(shifted?1:0);shift++){
        if(own&&[keyCharacter(layout,own.unsignedIntValue,shift).lowercaseString isEqual:wanted])return own;
        for(UInt32 code=0;code<128;code++)if(!keypad(code)&&[keyCharacter(layout,code,shift).lowercaseString isEqual:wanted])return @(code);
    }
    return nil;
}
@interface DWHotKeys ()
- (void)pressed:(UInt32)identifier;
- (void)released:(UInt32)identifier;
- (CGEventRef)filterKey:(CGEventType)type event:(CGEventRef)event;
@end
static OSStatus hotKeyEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(key.signature!='InfB')return eventNotHandledErr;
    DWHotKeys *keys=(__bridge DWHotKeys *)context;
    if(GetEventKind(event)==kEventHotKeyReleased)[keys released:key.id];else [keys pressed:key.id];
    return noErr;
}
static CGEventRef reservedKeyEvent(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;return [(__bridge DWHotKeys *)context filterKey:type event:event];
}
@implementation DWHotKeys {
    void (^_fire)(NSString *);
    NSDictionary *_bindings;
    EventHandlerRef _handler;
    NSMutableArray<NSValue *> *_registered;
    CFMachPortRef _keyTap;
    CFRunLoopSourceRef _keySource;
    NSMutableIndexSet *_tapKeys;
    NSMutableDictionary<NSNumber *,NSNumber *> *_suppressedKeys;
    NSTimer *_timer;
    UInt32 _repeating; // hot key id whose repeat timer is armed, 0 for none
    NSUInteger _generation;
    BOOL _passAll; // pass_keys = true
    NSSet<NSString *> *_passed; // pass_keys' combos
    NSSet<NSString *> *_passedNativeTerminals; // explicit terminal keys; modifiers are controller-owned
    NSNumber *_nativeFullscreenKey; // the current layout's unshifted F, or nil
    NSNumber *_nativeRestoreKey,*_nativeCenterKey; // the current layout's unshifted R/C, or nil
    NSMutableIndexSet *_withheld; // keys of _keys left unregistered because they are passed
    UInt32 _down; // hot key id Carbon reported pressed and not yet released, 0 for none
}
- (instancetype)initWithFire:(void (^)(NSString *))fire {
    if((self=[super init])){_fire=[fire copy];_keys=@[];_notes=@[];
        // The accessory app is rarely active, and a suspended delivery would leave stale chords registered.
        [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(inputSourceChanged:) name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];}
    return self;
}
- (void)inputSourceChanged:(NSNotification *)notification { (void)notification;if(self.changed)self.changed(); }
- (void)setBindings:(NSDictionary *)bindings {
    [self stop];_bindings=DWTyped(bindings,NSDictionary.class);
    // Upstream looks the active layout's keysym up first in both modes (keyboard.rs: modified_sym, then Config::lookup);
    // layout_independent, its default and what absent means here, only adds a fallback: here the ANSI position.
    NSNumber *independent=DWTyped(_bindings[@"layout_independent"],NSNumber.class);NSData *layout=keyboardLayout();BOOL fallback=!independent||independent.boolValue;
    _nativeFullscreenKey=keyTyping(layout,@"f",@3,NO);
    _nativeRestoreKey=keyTyping(layout,@"r",@15,NO);_nativeCenterKey=keyTyping(layout,@"c",@8,NO);
    NSMutableArray *keys=[NSMutableArray array],*notes=[NSMutableArray array],*deferred=[NSMutableArray array];NSMutableSet *taken=[NSMutableSet set];
    // Upstream tries the fallback only once the layout's own keysym has found no binding: keys the layout resolves take their chords first.
    for(int pass=0;pass<2;pass++)for(id entry in pass?deferred:DWTyped(_bindings[@"keys"],NSArray.class)){
        NSDictionary *key=DWTyped(entry,NSDictionary.class);NSString *action=DWTyped(key[@"action"],NSString.class),*combo=DWTyped(key[@"combo"],NSString.class)?:action,*character=DWTyped(key[@"character"],NSString.class);
        NSNumber *position=DWTyped(key[@"key_code"],NSNumber.class),*code=position;if(!action)continue;
        // A chord whose action cannot run here stays with the native applications.
        BOOL inert=[DWTyped(key[@"implemented"],NSNumber.class)isEqual:@NO];
        NSDictionary<NSString *,NSNumber *> *held=DWTyped(key[@"modifiers"],NSDictionary.class);
        if(layout&&character.length&&!(position&&keypad(position.unsignedIntValue))){code=keyTyping(layout,character,position,[DWTyped(held[@"shift"],NSNumber.class)boolValue]);if(!code&&fallback){if(!pass){[deferred addObject:entry];continue;}code=position;}}
        if(!code||code.unsignedIntValue>127){if(!inert)[notes addObject:[NSString stringWithFormat:@"%@ (%@) has no key on this keyboard",combo,action]];continue;}
        UInt32 c=code.unsignedIntValue,modifiers=([DWTyped(held[@"control"],NSNumber.class)boolValue]?controlKey:0)|([DWTyped(held[@"option"],NSNumber.class)boolValue]?optionKey:0)|([DWTyped(held[@"shift"],NSNumber.class)boolValue]?shiftKey:0)|([DWTyped(held[@"command"],NSNumber.class)boolValue]?cmdKey:0);
        NSString *name=keyName(c)?:(keypad(c)?[@"Keypad " stringByAppendingString:keyCharacter(layout,c,NO)?:@"key"]:nil)?:keyCharacter(layout,c,NO).uppercaseString?:character.uppercaseString?:[NSString stringWithFormat:@"key %u",c];
        NSNumber *chord=DWChord(c,modifiers);NSString *label=[DWModifierGlyphs(modifiers) stringByAppendingString:name];
        if(inert)continue;
        if([taken containsObject:chord]){[notes addObject:[NSString stringWithFormat:@"%@ (%@) is already bound",label,action]];continue;}
        [taken addObject:chord];[keys addObject:@{@"action":action,@"combo":combo,@"chord":chord,@"modifiers":DWModifierGlyphs(modifiers),@"key":name,@"repeat":@([DWTyped(key[@"repeat"],NSNumber.class)boolValue]),@"passable":@([DWTyped(key[@"passable"],NSNumber.class)boolValue])}];
    }
    _keys=keys;_notes=notes;
}
- (BOOL)holds:(NSNumber *)chord { for(NSDictionary *key in _keys)if([key[@"chord"]isEqual:chord])return YES;return NO; }
- (NSArray<NSString *> *)chords:(NSString *)action {
    NSMutableArray *chords=[NSMutableArray array];for(NSDictionary *key in _keys)if([key[@"action"]isEqual:action])[chords addObject:[key[@"modifiers"] stringByAppendingString:key[@"key"]]];return chords;
}
- (NSArray<NSString *> *)start {
    if(_handler)return @[];
    EventTypeSpec types[]={{kEventClassKeyboard,kEventHotKeyPressed},{kEventClassKeyboard,kEventHotKeyReleased}};
    if(InstallApplicationEventHandler(hotKeyEvent,2,types,(__bridge void *)self,&_handler)!=noErr){_handler=NULL;return _keys.count?@[@"every key binding (no hot key handler)"]:@[];}
    NSMutableArray *refused=[NSMutableArray array];_generation++;_registered=[NSMutableArray array];_withheld=[NSMutableIndexSet indexSet];
    _tapKeys=[NSMutableIndexSet indexSet];_suppressedKeys=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<_keys.count;i++){
        UInt32 chord=[_keys[i][@"chord"]unsignedIntValue],code=chord>>16;
        if(code==99||(code==48&&(chord&cmdKey)))[_tapKeys addIndex:i];
    }
    // Carbon cannot reliably take system-owned Command-Tab or Mission Control.
    // A session filter owns their physical down/up pair while the desktop is open.
    // No global shortcut preferences are modified, and stopping removes the tap.
    if((_tapKeys.count||self.standinEnter||self.nativeWindowControl)&&AXIsProcessTrusted()){
        _keyTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,
            CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|CGEventMaskBit(kCGEventFlagsChanged),reservedKeyEvent,(__bridge void *)self);
        if(_keyTap){_keySource=CFMachPortCreateRunLoopSource(NULL,_keyTap,0);
            if(_keySource)CFRunLoopAddSource(CFRunLoopGetMain(),_keySource,kCFRunLoopCommonModes);
            else {CFMachPortInvalidate(_keyTap);CFRelease(_keyTap);_keyTap=NULL;}}
    }
    if(_tapKeys.count&&!_keyTap)[refused addObject:@"System shortcut interception unavailable; Command-Tab and Mission Control may remain with macOS"];
    for(NSUInteger i=0;i<_keys.count;i++){
        // A key the focused window is passed is not registered at all: see -pass:.
        BOOL passed=[self passes:_keys[i]];if(passed)[_withheld addIndex:i];
        [_registered addObject:[NSValue valueWithPointer:passed?NULL:[self hotKey:i refused:refused]]];
    }
    return refused;
}
// One key's Carbon hot key, its id the key's place in _keys + 1; NULL, and a line in `refused`, when macOS will not have the chord.
- (EventHotKeyRef)hotKey:(NSUInteger)i refused:(NSMutableArray<NSString *> *)refused {
    if(_keyTap&&[_tapKeys containsIndex:i])return NULL;
    NSDictionary *key=_keys[i];UInt32 chord=[key[@"chord"]unsignedIntValue];EventHotKeyID identifier={'InfB',(UInt32)i+1};EventHotKeyRef reference=NULL;
    if(RegisterEventHotKey(chord>>16,chord&chordModifiers,identifier,GetApplicationEventTarget(),0,&reference)!=noErr){reference=NULL;[refused addObject:[NSString stringWithFormat:@"%@%@ (%@)",key[@"modifiers"],key[@"key"],key[@"action"]]];}
    return reference;
}
- (BOOL)registered:(NSUInteger)i {
    return i<_registered.count&&(_registered[i].pointerValue||(_keyTap&&[_tapKeys containsIndex:i]&&![_withheld containsIndex:i]));
}
- (CGEventRef)filterKey:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        [self endRepeat];[self lift];if(_keyTap&&AXIsProcessTrusted())CGEventTapEnable(_keyTap,true);return event;
    }
    if(type==kCGEventFlagsChanged){
        if(_down&&_down<=_keys.count){UInt32 modifiers=[_keys[_down-1][@"chord"]unsignedIntValue]&chordModifiers;
            CGEventFlags f=CGEventGetFlags(event);UInt32 held=(f&kCGEventFlagMaskControl?controlKey:0)|(f&kCGEventFlagMaskAlternate?optionKey:0)|(f&kCGEventFlagMaskShift?shiftKey:0)|(f&kCGEventFlagMaskCommand?cmdKey:0);
            if((held&modifiers)!=modifiers){[self endRepeat];[self lift];}}
        return event;
    }
    if(type!=kCGEventKeyDown&&type!=kCGEventKeyUp)return event;
    NSNumber *physical=@(CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode));
    NSNumber *owned=_suppressedKeys[physical];NSUInteger generation=_generation;__weak DWHotKeys *weak=self;
    if(type==kCGEventKeyUp){
        if(!owned)return event;[_suppressedKeys removeObjectForKey:physical];
        dispatch_async(dispatch_get_main_queue(),^{DWHotKeys *keys=weak;if(keys&&keys->_generation==generation)[keys released:owned.unsignedIntValue];});return NULL;
    }
    if(owned)return NULL; // one toggle per physical press, including auto-repeat
    if(CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat))return event;
    UInt32 code=physical.unsignedIntValue;
    // Apple top-row Mission Control emits 160 when F3 emits 99 in function mode.
    // Mapping evidence: tauri-plugin-macos-input-monitor 0.1.0, keycode reference
    // https://docs.rs/crate/tauri-plugin-macos-input-monitor/0.1.0
    if(code==160)code=99;
    CGEventFlags f=CGEventGetFlags(event);UInt32 modifiers=(f&kCGEventFlagMaskControl?controlKey:0)|(f&kCGEventFlagMaskAlternate?optionKey:0)|(f&kCGEventFlagMaskShift?shiftKey:0)|(f&kCGEventFlagMaskCommand?cmdKey:0);
    NSNumber *chord=DWChord(code,modifiers);
    for(NSUInteger i=_tapKeys.firstIndex;i!=NSNotFound;i=[_tapKeys indexGreaterThanIndex:i]){
        if(![self registered:i]||[self passes:_keys[i]]||![_keys[i][@"chord"]isEqual:chord])continue;
        NSNumber *identifier=@(i+1);_suppressedKeys[physical]=identifier;
        // The action may resize/focus an app; keep that work outside the tap callback.
        dispatch_async(dispatch_get_main_queue(),^{DWHotKeys *keys=weak;if(keys&&keys->_generation==generation)[keys pressed:identifier.unsignedIntValue];});return NULL;
    }
    // keyboard.rs at 352333a8: bindings precede the focused stand-in's Enter.
    // A binding registered with Carbon still owns its chord; do not swallow it.
    if((code==36||code==76)&&modifiers==0&&![self holds:chord]&&self.standinEnter){
        dispatch_block_t launch=self.standinEnter();
        if(launch){_suppressedKeys[physical]=@0;
            dispatch_async(dispatch_get_main_queue(),^{DWHotKeys *keys=weak;if(keys&&keys->_generation==generation)launch();});return NULL;}
    }
    // Apple macOS 26/27 window controls (individual corners have no default key):
    // https://support.apple.com/guide/mac-help/mchl9674d0b0/26/mac/26
    // https://support.apple.com/guide/mac-help/mchl9674d0b0/27/mac/27
    // Fn is absent from Carbon chords, so authored bindings still take precedence.
    // Ordinary Fn-arrow navigation and unsupported modifier combinations stay native.
    BOOL function=(f&kCGEventFlagMaskSecondaryFn)!=0;
    DWNativeWindowControl action=DWNativeWindowControlToggleFullscreen;NSString *terminal=nil;
    if(_nativeFullscreenKey&&code==_nativeFullscreenKey.unsignedIntValue
        &&(function?modifiers==0:modifiers==(controlKey|cmdKey)))terminal=@"f";
    else if(function&&modifiers==controlKey){
        if(_nativeFullscreenKey&&code==_nativeFullscreenKey.unsignedIntValue){terminal=@"f";action=DWNativeWindowControlFill;}
        else if(_nativeRestoreKey&&code==_nativeRestoreKey.unsignedIntValue){terminal=@"r";action=DWNativeWindowControlRestore;}
        else if(_nativeCenterKey&&code==_nativeCenterKey.unsignedIntValue){terminal=@"c";action=DWNativeWindowControlCenter;}
    }
    if(!terminal&&function&&(modifiers==controlKey||modifiers==(controlKey|shiftKey)||modifiers==(controlKey|optionKey|shiftKey))){
        switch(code){case 123:terminal=@"left";break;case 124:terminal=@"right";break;case 125:terminal=@"down";break;case 126:terminal=@"up";break;default:break;}
        action=DWNativeWindowControlSuppressTiling;
    }
    if(terminal&&!_passAll&&![_passedNativeTerminals containsObject:terminal]&&![self holds:chord]&&self.nativeWindowControl){
        dispatch_block_t control=self.nativeWindowControl(action);
        if(control){_suppressedKeys[physical]=@0;
            dispatch_async(dispatch_get_main_queue(),^{DWHotKeys *keys=weak;if(keys&&keys->_generation==generation)control();});return NULL;}
    }
    return event;
}
// Adapted from DriftWM, repository https://github.com/malbiruk/driftwm, commit 352333a8fa1b22171492d4b71a54102045c9a19d, src/input/keyboard.rs (the pass_keys
// arm of the key filter: a combo the focused window's rule allows is forwarded to its client before any binding is
// looked up). Upstream handles its VT switch ahead of that arm, so that pass_keys = true can never lock the user out
// of the TTYs. The ways out of this canvas are the exit chord and quit: neither is ever passed, whatever the
// controller's "passable" says of it, and a key the reply does not mark passable is not passed either.
- (BOOL)passes:(NSDictionary *)key {
    if(![key[@"passable"]boolValue]||[key[@"chord"]isEqual:self.kept]||[key[@"action"]isEqual:@"quit"])return NO;
    return _passAll||[_passed containsObject:key[@"combo"]];
}
// A passed key stops being a hot key.
- (void)withhold:(NSUInteger)i {
    EventHotKeyRef reference=_registered[i].pointerValue;
    if(!reference&&!(_keyTap&&[_tapKeys containsIndex:i]))return;
    if(reference)UnregisterEventHotKey(reference);_registered[i]=[NSValue valueWithPointer:NULL];[_withheld addIndex:i];
}
// The key Carbon reported down is up, or its chord is over: if it became the window's while it was held, it stops being a hot key now.
- (void)lift {
    NSUInteger identifier=_down;_down=0;
    if(!identifier||!_handler||identifier>_keys.count||![self passes:_keys[identifier-1]])return;
    if(_repeating==identifier)[self endRepeat];
    [self withhold:identifier-1];
}
- (NSArray<NSString *> *)pass:(id)passKeys {
    BOOL all=[DWTyped(passKeys,NSNumber.class)isEqual:@YES];NSMutableSet<NSString *> *combos=[NSMutableSet set];
    if(!all)for(id combo in DWTyped(passKeys,NSArray.class))if(DWTyped(combo,NSString.class))[combos addObject:combo];
    // Carbon reports the held key's release; a chord whose modifiers are gone is over even if that report never came.
    if(_down&&_down<=_keys.count){UInt32 modifiers=[_keys[_down-1][@"chord"]unsignedIntValue]&chordModifiers;if((heldModifiers()&modifiers)!=modifiers)[self lift];}
    if(all==_passAll&&[combos isEqual:_passed?:[NSSet set]])return @[];
    _passAll=all;_passed=combos;NSMutableSet<NSString *> *terminals=[NSMutableSet set];
    // The controller exports upstream combo text, not physical chords for
    // unbound pass entries. Conservatively leave native controls alone for any
    // explicit matching terminal key rather than duplicate its modifier mapping.
    for(NSString *combo in combos)[terminals addObject:[combo componentsSeparatedByString:@"+"].lastObject.lowercaseString];
    _passedNativeTerminals=terminals;
    NSMutableArray<NSString *> *refused=[NSMutableArray array];
    // Not started: -start registers by what is passed then.
    if(!_handler)return refused;
    for(NSUInteger i=0;i<_keys.count;i++){
        // Upstream decides press by press, and a key whose press it intercepted is the compositor's until its release
        // (keyboard.rs, suppressed_keys). The key that is down now was pressed as a binding: it stays a hot key, and
        // goes on repeating, until it is let go (-lift), so none of that hold reaches the window.
        if([self passes:_keys[i]]){if(_down!=i+1)[self withhold:i];}
        // Only a key this left out comes back: one macOS refused at -start stays refused until the next -start.
        else if([_withheld containsIndex:i]){[_withheld removeIndex:i];_registered[i]=[NSValue valueWithPointer:[self hotKey:i refused:refused]];}
    }
    return refused;
}
- (void)endRepeat { [_timer invalidate];_timer=nil;_repeating=0; }
- (void)pressed:(UInt32)identifier {
    // Another press ends the one before it, whether or not Carbon reported that release.
    [self endRepeat];[self lift];if(identifier<1||identifier>_keys.count)return;
    // A press already on its way when its key was passed to the window runs nothing.
    if(![self registered:identifier-1])return;
    NSDictionary *key=_keys[identifier-1];NSString *action=key[@"action"];NSUInteger generation=_generation;_down=identifier;
    _fire(action);
    double delay=[DWTyped(_bindings[@"repeat_delay_ms"],NSNumber.class)doubleValue]/1000,rate=[DWTyped(_bindings[@"repeat_rate_hz"],NSNumber.class)doubleValue];
    // The action may have stopped or replaced the registration it was fired from, or the key may have been passed and let go meanwhile.
    if(generation!=_generation||!_handler||![self registered:identifier-1]||![key[@"repeat"]boolValue]||!(rate>0)||!(delay>=0))return;
    UInt32 modifiers=[key[@"chord"]unsignedIntValue]&chordModifiers;__weak DWHotKeys *weak=self;_repeating=identifier;
    _timer=[[NSTimer alloc]initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:delay] interval:1/rate repeats:YES block:^(NSTimer *timer){
        DWHotKeys *keys=weak;if(!keys||keys->_timer!=timer){[timer invalidate];return;}
        // Carbon reports the release; a chord whose modifiers are gone has ended even if that report never came.
        if((heldModifiers()&modifiers)!=modifiers){[keys endRepeat];return;}
        keys->_fire(action);
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)released:(UInt32)identifier { if(identifier==_repeating)[self endRepeat];if(identifier==_down)[self lift]; }
- (void)stop {
    [self endRepeat];_generation++;_down=0;
    if(_keyTap){CGEventTapEnable(_keyTap,false);CFMachPortInvalidate(_keyTap);}
    if(_keySource){CFRunLoopRemoveSource(CFRunLoopGetMain(),_keySource,kCFRunLoopCommonModes);CFRelease(_keySource);_keySource=NULL;}
    if(_keyTap){CFRelease(_keyTap);_keyTap=NULL;}_tapKeys=nil;_suppressedKeys=nil;
    for(NSValue *reference in _registered)if(reference.pointerValue)UnregisterEventHotKey(reference.pointerValue);
    _registered=nil;_withheld=nil;if(_handler){RemoveEventHandler(_handler);_handler=NULL;}
}
- (void)invalidate { [self stop];self.changed=nil;self.standinEnter=nil;self.nativeWindowControl=nil;[NSDistributedNotificationCenter.defaultCenter removeObserver:self]; }
- (void)dealloc { [self stop];[NSDistributedNotificationCenter.defaultCenter removeObserver:self]; }
@end
