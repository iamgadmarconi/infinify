// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation. The two Allow requests are the permission window's (DWOnboarding.m); the launch daemon's steps are
// those of `native-desktop enable` (DWNativeDesktopCLI.m), taken one click at a time.
#import "DWSetupAssistant.h"
#import "DWSetupButton.h"
#import "DWDockReloader.h"
#import "DWLoginItem.h"
#import "DWNativeDesktopCLI.h"
#import "DWOwnerFile.h"
#import "DWUninstall.h"
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#include <signal.h>
#include <sys/file.h>

static const CGFloat kWidth=520,kHeight=480,kInset=32,kTextWidth=kWidth-2*kInset;
static NSString *const kLoginItemsWait=@"Waiting for you to allow Infinify under System Settings › General › Login Items & Extensions.";

// Ego's text: one family, 12 points on 18 for everything, 11 for secondary lines, the wordmark at 22.
static NSTextField *text(NSString *string,CGFloat size,BOOL medium,NSColor *color) {
    NSTextField *field=[NSTextField wrappingLabelWithString:@""];
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];CGFloat line=size>=20?28:size>=12?18:16;
    style.minimumLineHeight=line;style.maximumLineHeight=line;
    field.attributedStringValue=[[NSAttributedString alloc]initWithString:string attributes:@{NSFontAttributeName:DWSetupFont(size,medium),NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
    field.selectable=NO;field.preferredMaxLayoutWidth=kTextWidth;field.translatesAutoresizingMaskIntoConstraints=NO;
    return field;
}
static NSTextField *body(NSString *string) { return text(string,12,NO,DWSetupTextColor()); }
static NSTextField *quiet(NSString *string) { return text(string,11,NO,DWSetupSecondaryTextColor()); }
// Commands on the raised surface with the shared radius, in Menlo, selectable so they can be copied.
static NSView *code(NSString *string) {
    NSBox *box=[NSBox new];box.boxType=NSBoxCustom;box.borderWidth=0;box.cornerRadius=12;box.titlePosition=NSNoTitle;
    box.fillColor=DWSetupRaisedColor();box.contentViewMargins=NSZeroSize;box.translatesAutoresizingMaskIntoConstraints=NO;
    NSTextField *field=[NSTextField labelWithString:string];
    field.font=[NSFont fontWithName:@"Menlo" size:11]?:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    field.textColor=DWSetupTextColor();field.selectable=YES;field.translatesAutoresizingMaskIntoConstraints=NO;
    [box.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[[box.widthAnchor constraintEqualToConstant:kTextWidth],
        [field.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],[field.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14],
        [field.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],[field.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8]]];
    return box;
}
// A name on the left and its state or its action on the right, across the text column.
static NSView *row(NSString *name,NSView *trailing) {
    NSStackView *stack=[NSStackView new];stack.orientation=NSUserInterfaceLayoutOrientationHorizontal;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [stack addView:body(name) inGravity:NSStackViewGravityLeading];[stack addView:trailing inGravity:NSStackViewGravityTrailing];
    [stack.widthAnchor constraintEqualToConstant:kTextWidth].active=YES;
    return stack;
}

@interface DWSetupAssistant () <NSWindowDelegate>
@end
@implementation DWSetupAssistant {
    NSString *_support,*_signature,*_status;
    NSWindow *_window;
    NSTimer *_timer;
    BOOL _busy,_askedRecording,_waitingLogin,_waitingDaemon,_retireFailed,_demoNeedsRecording;
}
@synthesize pane=_pane;
- (instancetype)initWithSupportDirectory:(NSString *)supportDirectory {
    if(!(self=[super init]))return nil;
    _support=supportDirectory.copy;
    _accessibility=^BOOL{return AXIsProcessTrusted();};
    _screenRecording=^BOOL{return CGPreflightScreenCaptureAccess();};
    _policy=^DWSetupPolicy{return DWSetupReadPolicy();};
    _daemonState=^DWLoaderState{return [DWLoaderService state];};
    _loginItemStatus=^NSInteger{return [SMAppService agentServiceWithPlistName:DWLoginItemAgentPlist].status;};
    _compositorAtLogin=^BOOL{return DWNativeLoginIsCompositor();};
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    _otherCopies=^NSArray<NSString *> *{return DWSetupOtherCopies(bundle,DWSetupCopyCandidates());};
    return self;
}
- (DWSetupMode)mode { return DWSetupModeAt(_support,self.compositorAtLogin()); }
- (NSWindow *)window {
    if(_window)return _window;
    _window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,kWidth,kHeight) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"Infinify";_window.titleVisibility=NSWindowTitleHidden;_window.titlebarAppearsTransparent=YES;
    _window.movableByWindowBackground=YES;_window.releasedWhenClosed=NO;_window.delegate=self;
    _window.backgroundColor=DWSetupCanvasColor();_window.level=NSFloatingWindowLevel+1;
    return _window;
}
// What a pane was built from: when it reads differently a second later, the pane is built again.
- (NSString *)signatureFor:(DWSetupPane)pane {
    switch(pane){
        case DWSetupPanePermissions:return [NSString stringWithFormat:@"%d%d",self.accessibility(),self.screenRecording()];
        case DWSetupPaneLogin:return [NSString stringWithFormat:@"%ld",(long)self.loginItemStatus()];
        case DWSetupPaneCompositor:{DWSetupPolicy p=self.policy();return [NSString stringWithFormat:@"%d%d%d%ld%d",p.known,p.sipRelaxed,p.bootArgument,(long)self.daemonState(),self.compositorAtLogin()];}
        default:return @"";
    }
}
- (DWSetupButton *)button:(NSString *)title role:(DWSetupButtonRole)role action:(SEL)action {
    return [DWSetupButton buttonWithTitle:title role:role target:self action:action];
}

// Views that belong together (a step and its command) sit closer than the stack's spacing.
static NSString *const kCloseBelow=@"DWSetupCloseBelow";
static NSView *closeBelow(NSView *view) { view.identifier=kCloseBelow;return view; }
- (void)buildPane:(DWSetupPane)pane {
    if(pane==DWSetupPaneReady&&self.mode==DWSetupIncomplete)pane=DWSetupPaneCompositor;
    if(pane!=_pane)_status=nil;
    _pane=pane;_signature=[self signatureFor:pane];
    NSMutableArray<NSView *> *views=[NSMutableArray array];NSMutableArray<DWSetupButton *> *actions=[NSMutableArray array];
    switch(pane){
        case DWSetupPaneWelcome:[self welcome:views actions:actions];break;
        case DWSetupPanePermissions:[self permissions:views actions:actions];break;
        case DWSetupPaneLogin:[self login:views actions:actions];break;
        case DWSetupPaneCompositor:[self compositor:views actions:actions];break;
        case DWSetupPaneReady:[self ready:views actions:actions];break;
    }
    if(_status.length)[views addObject:quiet(_status)];
    NSView *content=[[NSView alloc]initWithFrame:NSMakeRect(0,0,kWidth,kHeight)];
    NSStackView *stack=[NSStackView stackViewWithViews:views];
    stack.orientation=NSUserInterfaceLayoutOrientationVertical;stack.alignment=NSLayoutAttributeLeading;stack.spacing=12;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    for(NSView *view in views)if([view.identifier isEqual:kCloseBelow])[stack setCustomSpacing:6 afterView:view];
    NSStackView *footer=[NSStackView new];footer.orientation=NSUserInterfaceLayoutOrientationHorizontal;footer.spacing=8;footer.translatesAutoresizingMaskIntoConstraints=NO;
    [footer addView:text([NSString stringWithFormat:@"%ld of %ld",(long)pane+1,(long)DWSetupPaneCount],11,NO,DWSetupTertiaryTextColor()) inGravity:NSStackViewGravityLeading];
    for(DWSetupButton *action in actions)[footer addView:action inGravity:NSStackViewGravityTrailing];
    // Return presses the pane's one Primary, which sits last, on the trailing edge.
    DWSetupButton *primary=actions.lastObject;if(primary.role==DWSetupButtonPrimary&&primary.enabled)primary.keyEquivalent=@"\r";
    [content addSubview:stack];[content addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:56],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kInset],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-kInset],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:footer.topAnchor constant:-20],
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kInset],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-kInset],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24]]];
    self.window.contentView=content;
}

- (void)welcome:(NSMutableArray<NSView *> *)views actions:(NSMutableArray<DWSetupButton *> *)actions {
    NSImageView *icon=[NSImageView imageViewWithImage:NSApp.applicationIconImage?:[NSImage imageNamed:NSImageNameApplicationIcon]];
    icon.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:72],[icon.heightAnchor constraintEqualToConstant:72]]];
    [views addObject:icon];
    [views addObject:text(@"Infinify",22,YES,DWSetupTextColor())];
    [views addObject:body(@"Your desktop becomes one canvas you pan and zoom, and your windows live on it. Setup takes a few minutes, and a restart into Recovery if your Mac still keeps the Dock helper out.")];
    NSArray<NSString *> *others=self.otherCopies();
    if(others.count&&!_retireFailed)[views addObject:quiet([NSString stringWithFormat:@"Another copy of Infinify is at %@. Setup removes it first, with its login item and launch daemon.",[others componentsJoinedByString:@" and "]])];
    [actions addObject:[self button:_retireFailed?@"Continue":@"Set up" role:DWSetupButtonPrimary action:@selector(setUp:)]];
    if(_busy)actions.lastObject.enabled=NO;
}
- (void)permissions:(NSMutableArray<NSView *> *)views actions:(NSMutableArray<DWSetupButton *> *)actions {
    BOOL input=self.accessibility(),capture=self.screenRecording();
    [views addObject:text(@"Permissions",12,YES,DWSetupTextColor())];
    [views addObject:body(@"Accessibility lets Infinify move, focus and click your windows, and it is required. Screen Recording shows them on extra displays and in the demo.")];
    [views addObject:row(@"Accessibility",input?quiet(@"Allowed"):[self button:@"Allow" role:DWSetupButtonSecondary action:@selector(allowInput:)])];
    [views addObject:row(@"Screen Recording",capture?quiet(@"Allowed"):_askedRecording?quiet(@"Restart Infinify once it is on"):[self button:@"Allow" role:DWSetupButtonSecondary action:@selector(allowCapture:)])];
    [views addObject:quiet(_demoNeedsRecording&&!capture?@"The demo shows copies of your windows, so it needs Screen Recording.":@"macOS gives Screen Recording only to an app started after it was allowed, so Infinify restarts itself for it.")];
    if(_askedRecording&&!capture)[actions addObject:[self button:@"Restart Infinify" role:DWSetupButtonSecondary action:@selector(restart:)]];
    DWSetupButton *next=[self button:@"Continue" role:DWSetupButtonPrimary action:@selector(toLogin:)];next.enabled=input;[actions addObject:next];
}
- (void)login:(NSMutableArray<NSView *> *)views actions:(NSMutableArray<DWSetupButton *> *)actions {
    NSInteger status=self.loginItemStatus();
    [views addObject:text(@"Start at login",12,YES,DWSetupTextColor())];
    [views addObject:body(@"Infinify starts when you log in, and again if it ever crashes. It stops only when you quit it.")];
    [views addObject:body(@"While it runs, Infinify turns off the macOS window settings that would fight it, such as Stage Manager and edge tiling. Your settings come back when it quits.")];
    if(status==SMAppServiceStatusEnabled)[views addObject:quiet(@"The login item is on.")];
    else if(status==SMAppServiceStatusRequiresApproval||_waitingLogin)[views addObject:quiet(kLoginItemsWait)];
    if(status==SMAppServiceStatusRequiresApproval)[actions addObject:[self button:@"Open Login Items" role:DWSetupButtonSecondary action:@selector(openLoginItems:)]];
    [actions addObject:[self button:status==SMAppServiceStatusEnabled?@"Continue":@"Turn on" role:DWSetupButtonPrimary action:@selector(turnOnLogin:)]];
}
- (void)compositor:(NSMutableArray<NSView *> *)views actions:(NSMutableArray<DWSetupButton *> *)actions {
    DWSetupPolicy policy=self.policy();DWLoaderState daemon=self.daemonState();BOOL on=self.compositorAtLogin();
    [views addObject:text(@"Compositor mode",12,YES,DWSetupTextColor())];
    if(on&&daemon==DWLoaderEnabled){
        [views addObject:body(self.refusal.length?@"Compositor mode is set up, but it did not start this time.":@"Compositor mode is on. At every login the launch daemon loads the helper into the Dock, and the window server moves and scales your real windows.")];
        if(self.refusal.length){
            [views addObject:quiet([@"Why: " stringByAppendingString:self.refusal])];
            [actions addObject:[self button:@"Try the demo" role:DWSetupButtonSecondary action:@selector(tryDemo:)]];
            [actions addObject:[self button:@"Try again" role:DWSetupButtonPrimary action:@selector(tryAgain:)]];
        }else [actions addObject:[self button:@"Continue" role:DWSetupButtonPrimary action:@selector(toReady:)]];
        return;
    }
    if(self.refusal.length)[views addObject:quiet([@"Compositor mode did not start: " stringByAppendingString:self.refusal])];
    if(!DWSetupPolicyAllows(policy)){
        [views addObject:body(@"Infinify moves and scales your real windows through a helper in the Dock. macOS lets it in once System Integrity Protection is partly relaxed, which you do once, in Recovery.")];
        [views addObject:quiet(policy.known?[NSString stringWithFormat:@"Now: SIP %@, boot argument %@.",policy.sipRelaxed?@"relaxed":@"on",policy.bootArgument?@"set":@"not set"]:@"Now: SIP could not be read.")];
        [views addObject:body(@"1   Shut down. Hold the power button until Options appears, then Continue.")];
        [views addObject:closeBelow(body(@"2   Open Utilities › Terminal and run:"))];
        [views addObject:code(@"csrutil enable --without fs --without debug --without nvram")];
        [views addObject:closeBelow(body(@"3   Restart, then run in Terminal:"))];
        [views addObject:code(@"sudo nvram boot-args=-arm64e_preview_abi")];
        [views addObject:body(@"4   Restart again. Setup opens here.")];
        [views addObject:quiet(@"To undo: csrutil enable in Recovery, and sudo nvram -d boot-args. Until then the demo shows copies of your windows.")];
        [actions addObject:[self button:@"Try the demo" role:DWSetupButtonSecondary action:@selector(tryDemo:)]];
        [actions addObject:[self button:@"Check again" role:DWSetupButtonPrimary action:@selector(checkAgain:)]];
        return;
    }
    if(daemon==DWLoaderUnavailable){
        [views addObject:body(@"Your Mac lets the helper in, but this copy of Infinify is signed ad hoc, and macOS runs its launch daemon only from a build signed with a Developer ID.")];
        [actions addObject:[self button:@"Try the demo" role:DWSetupButtonPrimary action:@selector(tryDemo:)]];
        return;
    }
    [views addObject:body(@"Your Mac lets the helper in. Infinify's launch daemon loads it into the Dock at every login, with no password, and macOS asks you once to allow it.")];
    if(daemon==DWLoaderNeedsApproval||_waitingDaemon)[views addObject:quiet(kLoginItemsWait)];
    if(daemon==DWLoaderNeedsApproval)[actions addObject:[self button:@"Open Login Items" role:DWSetupButtonSecondary action:@selector(openLoginItems:)]];
    DWSetupButton *enable=[self button:_busy?@"Checking…":@"Turn on" role:DWSetupButtonPrimary action:@selector(enableCompositor:)];enable.enabled=!_busy;[actions addObject:enable];
}
- (void)ready:(NSMutableArray<NSView *> *)views actions:(NSMutableArray<DWSetupButton *> *)actions {
    BOOL compositor=self.mode==DWSetupCompositor;
    [views addObject:text(compositor?@"Infinify is your desktop":@"The demo",12,YES,DWSetupTextColor())];
    if(!compositor)[views addObject:body(@"Infinify shows live copies of your windows on the canvas. Clicks and typing reach them, but menus and popups open where the real window is. Once SIP is relaxed, open Infinify again to finish compositor mode.")];
    for(NSArray<NSString *> *key in @[@[@"Pan",@"Drag empty canvas, or ⌃⌥-drag anywhere"],@[@"Zoom",@"⌃⌥-scroll"],@[@"Switch windows",@"⌥Tab"],@[@"Go home",@"⌃⌥A"],@[@"Quit Infinify",@"⌃⌥⌘⇧Q"]])
        [views addObject:row(key[0],quiet(key[1]))];
    [views addObject:quiet(@"Bindings and settings are in ~/.config/infinify/config.toml. Open Infinify again to see this window.")];
    BOOL running=self.canvasMode==self.mode;
    [actions addObject:[self button:running?@"Done":compositor?@"Start Infinify":@"Start the demo" role:DWSetupButtonPrimary action:@selector(start:)]];
}

- (void)setUp:(id)sender {
    (void)sender;NSArray<NSString *> *others=_retireFailed?@[]:self.otherCopies();
    if(!others.count){[self showPane:DWSetupPanePermissions];return;}
    _busy=YES;_status=@"Removing the other copy…";[self buildPane:_pane];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableArray<NSString *> *failures=[NSMutableArray array];
        for(NSString *other in others){NSString *why=nil;if(!DWUninstallRetireCopy(other,&why))[failures addObject:why?:other];}
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy=NO;
            if(failures.count){self->_retireFailed=YES;self->_status=[[failures componentsJoinedByString:@" "] stringByAppendingString:@" Remove it by hand, or continue with both."];[self buildPane:self->_pane];}
            else [self showPane:DWSetupPanePermissions];
        });
    });
}
- (void)allowInput:(id)sender {
    (void)sender;AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)allowCapture:(id)sender {
    (void)sender;CGRequestScreenCaptureAccess();_askedRecording=YES;[self buildPane:_pane];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (void)restart:(id)sender { (void)sender;if(_onRelaunch)_onRelaunch(); }
- (void)toLogin:(id)sender { (void)sender;[self showPane:DWSetupPaneLogin]; }
- (void)toReady:(id)sender { (void)sender;[self showPane:DWSetupPaneReady]; }
- (void)openLoginItems:(id)sender { (void)sender;[SMAppService openSystemSettingsLoginItems]; }
- (void)checkAgain:(id)sender { (void)sender;_status=nil;[self buildPane:_pane]; }
// Registering starts the login item at once; while setup is not done its run finds this one's lock and ends by itself.
- (void)turnOnLogin:(id)sender {
    (void)sender;
    if(self.loginItemStatus()==SMAppServiceStatusEnabled){[self showPane:DWSetupPaneCompositor];return;}
    DWLoginItemWarnIfOutsideApplications("setup");
    SMAppService *agent=[SMAppService agentServiceWithPlistName:DWLoginItemAgentPlist];NSError *error=nil;
    BOOL registered=[agent registerAndReturnError:&error];
    if(agent.status==SMAppServiceStatusEnabled){[self showPane:DWSetupPaneCompositor];return;}
    if(agent.status==SMAppServiceStatusRequiresApproval){_waitingLogin=YES;_status=nil;[SMAppService openSystemSettingsLoginItems];}
    else _status=[NSString stringWithFormat:@"macOS did not turn the login item on%@",registered?@".":[@": " stringByAppendingString:error.localizedDescription?:@"it gave no reason."]];
    [self buildPane:_pane];
}
- (void)enableCompositor:(id)sender {
    (void)sender;DWLoaderState state=self.daemonState();
    if(state==DWLoaderNotRegistered||state==DWLoaderNeedsApproval)state=[DWLoaderService registerDaemon];
    if(state==DWLoaderNeedsApproval){_waitingDaemon=YES;_status=nil;[self buildPane:_pane];return;}
    if(state!=DWLoaderEnabled){_status=[NSString stringWithFormat:@"The launch daemon is %@.",[DWLoaderService describe:state]];[self buildPane:_pane];return;}
    [self confirmDaemon];
}
// As `native-desktop enable` does: the daemon must answer this app before compositor mode becomes the login default.
- (void)confirmDaemon {
    _busy=YES;_status=@"Checking that the launch daemon answers…";[self buildPane:_pane];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *reply=nil;int answered=[DWLoaderService pingWithin:20 output:&reply];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy=NO;
            if(answered!=0){self->_status=[NSString stringWithFormat:@"The launch daemon does not answer this copy of Infinify: %@",[reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"no reply"];[self buildPane:self->_pane];return;}
            NSString *directory=DWDockReloadStateDirectory();
            if(!DWNativeWriteLoginRecord(directory,NO)){self->_status=@"Could not write the login-mode record.";[self buildPane:self->_pane];return;}
            DWDockReloadResume(directory);self->_status=nil;self.refusal=nil;
            [self showPane:DWSetupPaneReady];
        });
    });
}
// The demo: remembered for the login item, or, where compositor mode is already the default and only failed to start, run once.
- (void)tryDemo:(id)sender {
    (void)sender;
    if(!self.screenRecording()){_demoNeedsRecording=YES;[self showPane:DWSetupPanePermissions];return;}
    if(self.compositorAtLogin()){[self close];if(_onDemo)_onDemo();return;}
    DWSetupRecordDemo(_support);[self showPane:DWSetupPaneReady];
}
- (void)tryAgain:(id)sender { (void)sender;[self close];if(_onCompositor)_onCompositor(); }
- (void)start:(id)sender {
    (void)sender;DWSetupMode mode=self.mode;
    [self close];
    if(mode==self.canvasMode){if(_onQuit)_onQuit();}
    else if(mode==DWSetupCompositor){if(_onCompositor)_onCompositor();}
    else if(_onDemo)_onDemo();
}

- (void)show { [self showPane:self.refusal.length?DWSetupPaneCompositor:DWSetupResumePaneAt(_support)]; }
- (void)showPane:(DWSetupPane)pane {
    [self buildPane:pane];DWSetupRecordPane(_support,_pane);
    if(!self.window.visible)[self.window center];
    [self.window makeKeyAndOrderFront:nil];[NSApp activate];
    if(!_timer){
        __weak DWSetupAssistant *weak=self;
        _timer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){(void)timer;[weak look];}];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}
// Once a second: an approval given in System Settings moves setup on; anything else that changed rebuilds the pane.
- (void)look {
    if(_busy)return;
    if(_pane==DWSetupPaneLogin&&_waitingLogin&&self.loginItemStatus()==SMAppServiceStatusEnabled){_waitingLogin=NO;[self showPane:DWSetupPaneCompositor];return;}
    if(_pane==DWSetupPaneCompositor&&_waitingDaemon&&self.daemonState()==DWLoaderEnabled){_waitingDaemon=NO;[self confirmDaemon];return;}
    if(![[self signatureFor:_pane] isEqual:_signature])[self buildPane:_pane];
}
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;[self close];if(_onQuit)_onQuit();return NO; }
- (void)close { [_timer invalidate];_timer=nil;_window.delegate=nil;[_window orderOut:nil];[_window close];_window=nil; }
- (void)dealloc { [_timer invalidate]; }
@end

typedef NS_ENUM(NSInteger,DWSetupNext) { DWSetupNextQuit, DWSetupNextCompositor, DWSetupNextDemo, DWSetupNextRelaunch };
// SIGTERM (uninstall, a hand-over, the removal of this copy), SIGINT and SIGHUP end the assistant as its close button does,
// with status 0: an end by signal would be a failure to launchd, which starts the login item's job again after one.
static volatile sig_atomic_t setupSignal;
static void setupStop(int signal) { setupSignal=signal; }
int DWSetupRun(int argc,const char **argv) { @autoreleasepool {
    NSString *refusal=nil;
    if(argc==2&&!strcmp(argv[0],"--refused"))refusal=@(argv[1]);
    else if(argc!=0){fputs("usage: Infinify setup [--refused REASON]\n",stderr);return 64;}
    NSString *support=DWSupportDirectory();
    if(![NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]){fputs("Infinify: cannot create the support directory\n",stderr);return 73;}
    // One assistant at a time: the login item that setup registers starts at once, and finds this lock.
    int lock=open([support stringByAppendingPathComponent:@"setup.lock"].fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)!=0){if(lock>=0)close(lock);return 0;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    DWSetupAssistant *assistant=[[DWSetupAssistant alloc]initWithSupportDirectory:support];
    assistant.refusal=refusal;
    // A canvas of this bundle that is already running (the assistant was opened from Finder over it), taken to be in the mode setup recorded.
    NSString *executable=NSBundle.mainBundle.executablePath;
    BOOL canvas=NO;
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier?:@"com.marengox.infinify"])
        if(app.processIdentifier!=getpid()&&[app.executableURL.path.stringByResolvingSymlinksInPath isEqual:executable.stringByResolvingSymlinksInPath])canvas=YES;
    if(canvas)assistant.canvasMode=DWSetupModeAt(support,DWNativeLoginIsCompositor());
    __block DWSetupNext next=DWSetupNextQuit;__block BOOL done=NO;
    assistant.onQuit=^{done=YES;};
    assistant.onCompositor=^{next=DWSetupNextCompositor;done=YES;};
    assistant.onDemo=^{next=DWSetupNextDemo;done=YES;};
    assistant.onRelaunch=^{next=DWSetupNextRelaunch;done=YES;};
    signal(SIGTERM,setupStop);signal(SIGINT,setupStop);signal(SIGHUP,setupStop);
    [assistant show];
    while(!done&&!setupSignal){@autoreleasepool{
        NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.25] inMode:NSDefaultRunLoopMode dequeue:YES];
        if(event)[NSApp sendEvent:event];
    }}
    [assistant close];
    close(lock);
    if(setupSignal||next==DWSetupNextQuit)return 0;
    // A canvas of this bundle ends first (orderly: SIGTERM puts its windows and settings back), so that the launcher, or the
    // demo's own run, finds no Infinify holding the desktop.
    if(next!=DWSetupNextRelaunch&&!DWUninstallStopInstances(DWUninstallInstances(executable),10)){fputs("Infinify: a running Infinify did not quit; quit it and open Infinify again.\n",stderr);return 1;}
    if(next==DWSetupNextCompositor)return DWSetupHandOverToCompositor(refusal!=nil);
    char *again[]={(char *)executable.fileSystemRepresentation,next==DWSetupNextDemo?"--demo":"setup",NULL};
    execv(again[0],again);perror("Infinify: relaunch");return 69;
} }
