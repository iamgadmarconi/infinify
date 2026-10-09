// SPDX-License-Identifier: GPL-3.0-or-later
// Semantics adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (Action::SwitchLayout: next and prev wrap, an index out of
// range is reported and ignored, the active layout's name is what is published).
// The list itself is Text Input Sources', new code.
#import "input-sources.h"
#import <Carbon/Carbon.h>

static id typed(id value,Class type) { return [value isKindOfClass:type]?value:nil; }
static NSArray *sources(void) {
    NSDictionary *wanted=@{(__bridge NSString *)kTISPropertyInputSourceCategory:(__bridge NSString *)kTISCategoryKeyboardInputSource,(__bridge NSString *)kTISPropertyInputSourceIsSelectCapable:@YES};
    return CFBridgingRelease(TISCreateInputSourceList((__bridge CFDictionaryRef)wanted,false))?:@[];
}
static id property(id source,CFStringRef key) { return (__bridge id)TISGetInputSourceProperty((__bridge TISInputSourceRef)source,key); }
// Where the selected keyboard input source is in the list, -1 when it is not there.
static NSInteger selected(NSArray *list) {
    TISInputSourceRef current=TISCopyCurrentKeyboardInputSource();if(!current)return -1;
    NSString *identifier=typed((__bridge id)TISGetInputSourceProperty(current,kTISPropertyInputSourceID),NSString.class);NSInteger index=-1;
    for(NSUInteger i=0;identifier&&i<list.count&&index<0;i++)if([property(list[i],kTISPropertyInputSourceID)isEqual:identifier])index=(NSInteger)i;
    CFRelease(current);return index;
}
NSDictionary *DWCurrentLayout(void) {
    NSArray *list=sources();NSInteger index=selected(list);if(index<0)return nil;
    NSString *name=typed(property(list[index],kTISPropertyLocalizedName),NSString.class),*identifier=typed(property(list[index],kTISPropertyInputSourceID),NSString.class);
    NSString *language=typed([typed(property(list[index],kTISPropertyInputSourceLanguages),NSArray.class)firstObject],NSString.class);
    NSString *code=language.length?language:[identifier componentsSeparatedByString:@"."].lastObject;
    return @{@"name":name?:identifier?:@"",@"short":code.length?code:name?:@"",@"index":@(index),@"count":@(list.count)};
}
NSString *DWSwitchLayout(NSDictionary *effect) {
    NSArray *list=sources();NSInteger count=(NSInteger)list.count,current=selected(list),index;
    NSString *target=typed(effect[@"target"],NSString.class);NSNumber *number=typed(effect[@"index"],NSNumber.class);
    if(!count)return @"switch-layout: no keyboard input source is enabled";
    if([target isEqual:@"index"]&&number){
        index=number.integerValue;
        if(index<0||index>=count)return [NSString stringWithFormat:@"switch-layout: index %ld out of range (%ld layouts)",(long)index,(long)count];
    }
    else if([target isEqual:@"next"])index=current<0?0:(current+1)%count;
    else if([target isEqual:@"prev"])index=current<0?count-1:(current+count-1)%count;
    else return @"switch-layout: no target";
    if(index==current)return nil;
    OSStatus status=TISSelectInputSource((__bridge TISInputSourceRef)list[index]);
    return status==noErr?nil:[NSString stringWithFormat:@"switch-layout: macOS refused the input source (%d)",(int)status];
}
