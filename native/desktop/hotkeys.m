// SPDX-License-Identifier: GPL-3.0-or-later
#import "hotkeys.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

static const UInt32 chordModifiers=cmdKey|shiftKey|optionKey|controlKey;
NSNumber *DWChord(uint32_t keyCode,uint32_t carbonModifiers) { return @((keyCode<<16)|(carbonModifiers&chordModifiers)); }
NSString *DWModifierGlyphs(uint32_t m) { return [NSString stringWithFormat:@"%@%@%@%@",m&controlKey?@"⌃":@"",m&optionKey?@"⌥":@"",m&shiftKey?@"⇧":@"",m&cmdKey?@"⌘":@""]; }
static id typed(id value,Class type) { return [value isKindOfClass:type]?value:nil; }
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
@end
static OSStatus hotKeyEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(key.signature!='InfB')return eventNotHandledErr;
    DWHotKeys *keys=(__bridge DWHotKeys *)context;
    if(GetEventKind(event)==kEventHotKeyReleased)[keys released:key.id];else [keys pressed:key.id];
    return noErr;
}
@implementation DWHotKeys {
    void (^_fire)(NSString *);
    NSDictionary *_bindings;
    EventHandlerRef _handler;
    NSMutableArray<NSValue *> *_registered;
    NSTimer *_timer;
    UInt32 _repeating; // hot key id whose repeat timer is armed, 0 for none
    NSUInteger _generation;
}
- (instancetype)initWithFire:(void (^)(NSString *))fire {
    if((self=[super init])){_fire=[fire copy];_keys=@[];_notes=@[];
        // The accessory app is rarely active, and a suspended delivery would leave stale chords registered.
        [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(inputSourceChanged:) name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];}
    return self;
}
- (void)inputSourceChanged:(NSNotification *)notification { (void)notification;if(self.changed)self.changed(); }
- (void)setBindings:(NSDictionary *)bindings reserved:(NSDictionary<NSNumber *,NSString *> *)reserved {
    [self stop];_bindings=typed(bindings,NSDictionary.class);
    // Upstream looks the active layout's keysym up first in both modes (keyboard.rs: modified_sym, then Config::lookup);
    // layout_independent, its default and what absent means here, only adds a fallback: here the ANSI position.
    NSNumber *independent=typed(_bindings[@"layout_independent"],NSNumber.class);NSData *layout=keyboardLayout();BOOL fallback=!independent||independent.boolValue;
    NSMutableArray *keys=[NSMutableArray array],*notes=[NSMutableArray array],*deferred=[NSMutableArray array];NSMutableSet *taken=[NSMutableSet set];
    // Upstream tries the fallback only once the layout's own keysym has found no binding: keys the layout resolves take their chords first.
    for(int pass=0;pass<2;pass++)for(id entry in pass?deferred:typed(_bindings[@"keys"],NSArray.class)){
        NSDictionary *key=typed(entry,NSDictionary.class);NSString *action=typed(key[@"action"],NSString.class),*combo=typed(key[@"combo"],NSString.class)?:action,*character=typed(key[@"character"],NSString.class);
        NSNumber *position=typed(key[@"key_code"],NSNumber.class),*code=position;if(!action)continue;
        // A chord whose action cannot run here stays with the native applications.
        BOOL inert=[typed(key[@"implemented"],NSNumber.class)isEqual:@NO];
        NSDictionary<NSString *,NSNumber *> *held=typed(key[@"modifiers"],NSDictionary.class);
        if(layout&&character.length&&!(position&&keypad(position.unsignedIntValue))){code=keyTyping(layout,character,position,[typed(held[@"shift"],NSNumber.class)boolValue]);if(!code&&fallback){if(!pass){[deferred addObject:entry];continue;}code=position;}}
        if(!code||code.unsignedIntValue>127){if(!inert)[notes addObject:[NSString stringWithFormat:@"%@ (%@) has no key on this keyboard",combo,action]];continue;}
        UInt32 c=code.unsignedIntValue,modifiers=([typed(held[@"control"],NSNumber.class)boolValue]?controlKey:0)|([typed(held[@"option"],NSNumber.class)boolValue]?optionKey:0)|([typed(held[@"shift"],NSNumber.class)boolValue]?shiftKey:0)|([typed(held[@"command"],NSNumber.class)boolValue]?cmdKey:0);
        NSString *name=keyName(c)?:(keypad(c)?[@"Keypad " stringByAppendingString:keyCharacter(layout,c,NO)?:@"key"]:nil)?:keyCharacter(layout,c,NO).uppercaseString?:character.uppercaseString?:[NSString stringWithFormat:@"key %u",c];
        NSNumber *chord=DWChord(c,modifiers);NSString *label=[DWModifierGlyphs(modifiers) stringByAppendingString:name];
        if(reserved[chord]){[notes addObject:[NSString stringWithFormat:@"%@ (%@) stays with %@",label,action,reserved[chord]]];continue;}
        if(inert)continue;
        if([taken containsObject:chord]){[notes addObject:[NSString stringWithFormat:@"%@ (%@) is already bound",label,action]];continue;}
        [taken addObject:chord];[keys addObject:@{@"action":action,@"combo":combo,@"chord":chord,@"modifiers":DWModifierGlyphs(modifiers),@"key":name,@"repeat":@([typed(key[@"repeat"],NSNumber.class)boolValue])}];
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
    NSMutableArray *refused=[NSMutableArray array];_generation++;_registered=[NSMutableArray array];
    for(NSUInteger i=0;i<_keys.count;i++){
        NSDictionary *key=_keys[i];UInt32 chord=[key[@"chord"]unsignedIntValue];EventHotKeyID identifier={'InfB',(UInt32)i+1};EventHotKeyRef reference=NULL;
        if(RegisterEventHotKey(chord>>16,chord&chordModifiers,identifier,GetApplicationEventTarget(),0,&reference)!=noErr){reference=NULL;[refused addObject:[NSString stringWithFormat:@"%@%@ (%@)",key[@"modifiers"],key[@"key"],key[@"action"]]];}
        [_registered addObject:[NSValue valueWithPointer:reference]];
    }
    return refused;
}
- (void)endRepeat { [_timer invalidate];_timer=nil;_repeating=0; }
- (void)pressed:(UInt32)identifier {
    [self endRepeat];if(identifier<1||identifier>_keys.count)return;
    NSDictionary *key=_keys[identifier-1];NSString *action=key[@"action"];NSUInteger generation=_generation;
    _fire(action);
    double delay=[typed(_bindings[@"repeat_delay_ms"],NSNumber.class)doubleValue]/1000,rate=[typed(_bindings[@"repeat_rate_hz"],NSNumber.class)doubleValue];
    // The action may have stopped or replaced the registration it was fired from.
    if(generation!=_generation||!_handler||![key[@"repeat"]boolValue]||!(rate>0)||!(delay>=0))return;
    UInt32 modifiers=[key[@"chord"]unsignedIntValue]&chordModifiers;__weak DWHotKeys *weak=self;_repeating=identifier;
    _timer=[[NSTimer alloc]initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:delay] interval:1/rate repeats:YES block:^(NSTimer *timer){
        DWHotKeys *keys=weak;if(!keys||keys->_timer!=timer){[timer invalidate];return;}
        // Carbon reports the release; a chord whose modifiers are gone has ended even if that report never came.
        if((heldModifiers()&modifiers)!=modifiers){[keys endRepeat];return;}
        keys->_fire(action);
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)released:(UInt32)identifier { if(identifier==_repeating)[self endRepeat]; }
- (void)stop {
    [self endRepeat];_generation++;
    for(NSValue *reference in _registered)if(reference.pointerValue)UnregisterEventHotKey(reference.pointerValue);
    _registered=nil;if(_handler){RemoveEventHandler(_handler);_handler=NULL;}
}
- (void)invalidate { [self stop];self.changed=nil;[NSDistributedNotificationCenter.defaultCenter removeObserver:self]; }
- (void)dealloc { [self stop];[NSDistributedNotificationCenter.defaultCenter removeObserver:self]; }
@end
