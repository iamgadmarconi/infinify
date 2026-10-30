// SPDX-License-Identifier: GPL-3.0-or-later
#import "onboarding.h"
#import <ApplicationServices/ApplicationServices.h>

static NSTextField *text(NSView *view,NSRect frame,NSFont *font) {
    NSTextField *field=[NSTextField wrappingLabelWithString:@""];field.frame=frame;field.font=font;field.selectable=NO;[view addSubview:field];return field;
}
@interface DWOnboarding () <NSWindowDelegate>
@end
@implementation DWOnboarding {
    void (^_proceed)(void),(^_relaunch)(void),(^_quit)(void);
    NSWindow *_window;
    NSTextField *_headline,*_capture,*_input,*_note;
    NSButton *_allowCapture,*_allowInput,*_again;
    NSTimer *_timer;
    BOOL _requiresScreenCapture;
}
- (instancetype)initWithProceed:(void (^)(void))proceed relaunch:(void (^)(void))relaunch quit:(void (^)(void))quit requiresScreenCapture:(BOOL)requiresScreenCapture {
    if((self=[super init])){_proceed=[proceed copy];_relaunch=[relaunch copy];_quit=[quit copy];_requiresScreenCapture=requiresScreenCapture;}
    return self;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button=[NSButton buttonWithTitle:title target:self action:action];button.frame=frame;[_window.contentView addSubview:button];return button;
}
- (void)build {
    // Roomy on purpose: every text has a line to spare at the system font.
    _window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,270) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"Infinify";_window.releasedWhenClosed=NO;_window.level=NSFloatingWindowLevel+1;_window.delegate=self;
    NSView *view=_window.contentView;NSFont *body=[NSFont systemFontOfSize:NSFont.systemFontSize];
    _headline=text(view,NSMakeRect(20,226,600,24),[NSFont boldSystemFontOfSize:14]);
    _capture=text(view,NSMakeRect(20,162,410,52),body);_allowCapture=[self button:@"Allow screen recording…" action:@selector(allowCapture:) frame:NSMakeRect(440,174,180,30)];
    _input=text(view,NSMakeRect(20,102,410,52),body);_allowInput=[self button:@"Allow input…" action:@selector(allowInput:) frame:NSMakeRect(440,114,180,30)];
    _note=text(view,NSMakeRect(20,52,600,42),[NSFont systemFontOfSize:NSFont.smallSystemFontSize]);_note.textColor=NSColor.secondaryLabelColor;
    _again=[self button:@"Relaunch" action:@selector(again:) frame:NSMakeRect(430,12,100,30)];
    [self button:@"Quit" action:@selector(quit:) frame:NSMakeRect(540,12,80,30)];
}
- (void)show:(NSString *)error {
    if(!_window)[self build];
    [_timer invalidate];_timer=nil;
    if(error){
        _headline.stringValue=@"Infinify cannot start";_capture.frame=NSMakeRect(20,52,600,162);_capture.stringValue=error;_capture.selectable=YES;
        _input.hidden=_note.hidden=_allowCapture.hidden=_allowInput.hidden=_again.hidden=YES;
    }else{
        _headline.stringValue=_requiresScreenCapture?@"Infinify is the desktop: it needs two permissions":@"Native desktop needs Accessibility";
        // Accessibility is seen as soon as it is granted; so is Screen Recording wherever macOS lets a running process see it.
        __weak DWOnboarding *weak=self;_timer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){(void)timer;[weak look];}];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
        if([self look])return;
    }
    [_window center];[_window makeKeyAndOrderFront:nil];[NSApp activate];
}
// What is granted now. YES when nothing is in the way: the window has closed and the canvas was asked for.
- (BOOL)look {
    BOOL capture=CGPreflightScreenCaptureAccess(),input=AXIsProcessTrusted();
    if(DWDesktopAccessReady(_requiresScreenCapture,capture,input)){void (^proceed)(void)=_proceed;[self close];if(proceed)proceed();return YES;}
    _capture.stringValue=capture?@"Screen Recording: granted.":_requiresScreenCapture?@"Screen Recording is missing: without it no application window can be shown on the canvas.":@"Screen Recording is optional for native primary windows. Additional display views need it for captured copies.";
    _input.stringValue=input?@"Accessibility: granted.":@"Accessibility is missing: without it a click cannot reach a window on the canvas, and no window can be focused or closed from it.";
    _allowCapture.hidden=capture||!_requiresScreenCapture;_allowInput.hidden=input;_again.hidden=capture||!_requiresScreenCapture;
    _note.stringValue=!_requiresScreenCapture?@"Native windows appear as soon as Accessibility is granted.":capture?@"The canvas opens by itself as soon as Accessibility is granted.":@"macOS gives Screen Recording only to an app started after it was granted. Enable Infinify under Screen & System Audio Recording, then click Relaunch.";
    return NO;
}
// The same two requests as the chooser's Allow button, one button each: the request to macOS, then the pane it is switched on in.
- (void)allowCapture:(id)sender {
    (void)sender;CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (void)allowInput:(id)sender {
    (void)sender;AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)again:(id)sender { (void)sender;if(_relaunch)_relaunch(); }
- (void)quit:(id)sender { (void)sender;if(_quit)_quit(); }
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;if(_quit)_quit();return YES; }
- (void)close { [_timer invalidate];_timer=nil;_window.delegate=nil;[_window close];_window=nil; }
- (void)dealloc { [_timer invalidate]; }
@end
