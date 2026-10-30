// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// The private SkyLight route to one process's window (per-window input router).
#import "Router.h"
#import <dlfcn.h>
#import "DWDesktopSupport.h"
// New implementation. Private signatures/routing fields referenced from Cantrip
// 4da10af479701c8007074c65f9eb6a2db03c8ffc, macos/skylight.rs; no code copied.
// Source: https://github.com/ArcaneArts/Cantrip/blob/4da10af479701c8007074c65f9eb6a2db03c8ffc/cantrip_cua/src/macos/skylight.rs
@implementation Router
- (BOOL)loadPrivate {
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW);
    self.privatePost=sky?dlsym(sky,"SLEventPostToPid"):NULL;
    self.privateField=sky?dlsym(sky,"SLEventSetIntegerValueField"):NULL;
    self.privateLocation=dlsym(RTLD_DEFAULT,"CGEventSetWindowLocation");
    return self.privatePost&&self.privateField&&self.privateLocation;
}
- (BOOL)valid {
    NSDictionary *w=windowInfo(self.wid);
    return [birth(self.pid) isEqual:self.processBirth] && [w[(id)kCGWindowOwnerPID] intValue]==self.pid &&
           [w[(id)kCGWindowBounds] isEqual:self.bounds];
}
- (BOOL)post:(CGEventRef)e at:(CGPoint)p {
    if (!e || ![self valid] || DWStopSignal) return NO;
    CGEventSetSource(e,self.eventSource);
    CGEventSetIntegerValueField(e,kCGEventSourceUserData,self.tag);
    CGEventSetIntegerValueField(e,(CGEventField)91,self.wid); CGEventSetIntegerValueField(e,(CGEventField)92,self.wid);
    CGRect bounds; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)self.bounds,&bounds);
    CGEventSetLocation(e,CGPointMake(bounds.origin.x+p.x,bounds.origin.y+p.y));
    if (!self.privatePost || !self.privateLocation || !self.privateField) return NO;
    self.privateLocation(e,p);
    self.privateField(e,40,self.pid); self.privateField(e,51,self.wid); self.privateField(e,58,self.tag);
    self.privateField(e,91,self.wid); self.privateField(e,92,self.wid);
    if (CGEventGetType(e)==kCGEventLeftMouseDown || CGEventGetType(e)==kCGEventLeftMouseUp || CGEventGetType(e)==kCGEventLeftMouseDragged)
        self.privateField(e,7,3);
    self.privatePost(self.pid,e);
    return YES;
}
@end

