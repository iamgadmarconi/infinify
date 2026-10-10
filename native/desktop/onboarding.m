// SPDX-License-Identifier: GPL-3.0-or-later
#import "onboarding.h"
#import <ApplicationServices/ApplicationServices.h>

BOOL DWStageManagerOn(void) {
    CFStringRef domain=CFSTR("com.apple.WindowManager");CFPreferencesAppSynchronize(domain);
    Boolean known=false,on=CFPreferencesGetAppBooleanValue(CFSTR("GloballyEnabled"),domain,&known);return known&&on;
}
NSString *const DWStageManagerNote=@"Stage Manager is on: every window outside the current stage is a thumbnail in its strip, so it shows here blurred and still and cannot be clicked. Turn it off in Control Centre or in System Settings under Desktop & Dock.";
static NSTextField *text(NSView *view,NSRect frame,NSFont *font) {
    NSTextField *field=[NSTextField wrappingLabelWithString:@""];field.frame=frame;field.font=font;field.selectable=NO;[view addSubview:field];return field;
}
@interface DWOnboarding () <NSWindowDelegate>
@end
@implementation DWOnboarding {
    void (^_proceed)(void),(^_relaunch)(void),(^_quit)(void);
    NSWindow *_window;
    NSTextField *_headline,*_capture,*_input,*_stage,*_note;
    NSButton *_allowCapture,*_allowInput,*_openStage,*_again;
    NSTimer *_timer;
}
- (instancetype)initWithProceed:(void (^)(void))proceed relaunch:(void (^)(void))relaunch quit:(void (^)(void))quit {
    if((self=[super init])){_proceed=[proceed copy];_relaunch=[relaunch copy];_quit=[quit copy];}
    return self;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button=[NSButton buttonWithTitle:title target:self action:action];button.frame=frame;[_window.contentView addSubview:button];return button;
}
- (void)build {
    // Roomy on purpose: every text has a line to spare at the system font.
    _window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,362) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"Infinify";_window.releasedWhenClosed=NO;_window.level=NSFloatingWindowLevel+1;_window.delegate=self;
    NSView *view=_window.contentView;NSFont *body=[NSFont systemFontOfSize:NSFont.systemFontSize];
    _headline=text(view,NSMakeRect(20,318,600,24),[NSFont boldSystemFontOfSize:14]);
    _capture=text(view,NSMakeRect(20,254,410,52),body);_allowCapture=[self button:@"Allow screen recording…" action:@selector(allowCapture:) frame:NSMakeRect(440,266,180,30)];
    _input=text(view,NSMakeRect(20,194,410,52),body);_allowInput=[self button:@"Allow input…" action:@selector(allowInput:) frame:NSMakeRect(440,206,180,30)];
    _stage=text(view,NSMakeRect(20,102,410,84),body);_openStage=[self button:@"Open Desktop & Dock…" action:@selector(openStage:) frame:NSMakeRect(440,130,180,30)];
    _note=text(view,NSMakeRect(20,52,600,42),[NSFont systemFontOfSize:NSFont.smallSystemFontSize]);_note.textColor=NSColor.secondaryLabelColor;
    _again=[self button:@"Relaunch" action:@selector(again:) frame:NSMakeRect(430,12,100,30)];
    [self button:@"Quit" action:@selector(quit:) frame:NSMakeRect(540,12,80,30)];
}
- (void)show:(NSString *)error {
    if(!_window)[self build];
    [_timer invalidate];_timer=nil;
    if(error){
        _headline.stringValue=@"Infinify cannot start";_capture.frame=NSMakeRect(20,52,600,254);_capture.stringValue=error;_capture.selectable=YES;
        _input.hidden=_stage.hidden=_note.hidden=_allowCapture.hidden=_allowInput.hidden=_openStage.hidden=_again.hidden=YES;
    }else{
        _headline.stringValue=@"Infinify is the desktop: it needs two permissions, and Stage Manager off";
        // Accessibility is seen as soon as it is granted, and Stage Manager as soon as it is switched; so is Screen Recording wherever macOS lets a running process see it.
        __weak DWOnboarding *weak=self;_timer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){(void)timer;[weak look];}];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
        if([self look])return;
    }
    [_window center];[_window makeKeyAndOrderFront:nil];[NSApp activate];
}
// What is granted and how Stage Manager is set now. YES when nothing is in the way: the window has closed and the canvas was asked for.
- (BOOL)look {
    BOOL capture=CGPreflightScreenCaptureAccess(),input=AXIsProcessTrusted(),stage=DWStageManagerOn();
    if(capture&&input&&!stage){void (^proceed)(void)=_proceed;[self close];if(proceed)proceed();return YES;}
    _capture.stringValue=capture?@"Screen Recording: granted.":@"Screen Recording is missing: without it no application window can be shown on the canvas.";
    _input.stringValue=input?@"Accessibility: granted.":@"Accessibility is missing: without it a click cannot reach a window on the canvas, and no window can be focused or closed from it.";
    _stage.stringValue=stage?@"Stage Manager is on: macOS shrinks every window outside the current stage into its strip, and such a window would show on the canvas blurred and still, out of reach of a click. Turn it off in Control Centre or under Desktop & Dock.":@"Stage Manager: off.";
    _allowCapture.hidden=capture;_allowInput.hidden=input;_openStage.hidden=!stage;_again.hidden=capture;
    _note.stringValue=capture?(input?@"The canvas opens by itself as soon as Stage Manager is off.":stage?@"The canvas opens by itself as soon as Accessibility is granted and Stage Manager is off.":@"The canvas opens by itself as soon as Accessibility is granted."):@"macOS gives Screen Recording only to an app started after it was granted. Enable Infinify under Screen & System Audio Recording, then click Relaunch.";
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
// The pane the setting is in. It is switched there, or in Control Centre, by the user alone.
- (void)openStage:(id)sender {
    (void)sender;[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Desktop-Settings.extension"]];
}
- (void)again:(id)sender { (void)sender;if(_relaunch)_relaunch(); }
- (void)quit:(id)sender { (void)sender;if(_quit)_quit(); }
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;if(_quit)_quit();return YES; }
- (void)close { [_timer invalidate];_timer=nil;_window.delegate=nil;[_window close];_window=nil; }
- (void)dealloc { [_timer invalidate]; }
@end
