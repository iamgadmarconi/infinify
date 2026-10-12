// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#include <math.h>
#import "protocol.h"
int main(int argc,char **argv) { @autoreleasepool {
    // Trailing flags give the sole protocol v2 server several owned windows;
    // without them the host creates one window. `--activation regular` makes it
    // an application a window manager adopts (a regular one, whose windows have a
    // close, a miniaturize and a resize control) and `--watchdog` gives a longer test
    // its time; neither changes which windows there are or how the helper starts.
    int count=1,v2Queue=-1,watchdog=90,level=NSNormalWindowLevel;double alpha=1;BOOL several=NO,bad=NO,regular=NO,opaque=YES,allSpaces=NO,floating=NO;NSString *family=@"none";
    while(argc>=6 && (!strcmp(argv[argc-2],"--windows") || !strcmp(argv[argc-2],"--v2-queue") || !strcmp(argv[argc-2],"--activation") || !strcmp(argv[argc-2],"--watchdog") || !strcmp(argv[argc-2],"--level") || !strcmp(argv[argc-2],"--alpha") || !strcmp(argv[argc-2],"--opaque") || !strcmp(argv[argc-2],"--all-spaces") || !strcmp(argv[argc-2],"--family") || !strcmp(argv[argc-2],"--floating-panel"))) {
        if(!strcmp(argv[argc-2],"--floating-panel")){if(!strcmp(argv[argc-1],"yes"))floating=YES;else if(!strcmp(argv[argc-1],"no"))floating=NO;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--family")){family=@(argv[argc-1]);if(![@[@"none",@"popup",@"sheet",@"both"]containsObject:family])bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--activation")){if(!strcmp(argv[argc-1],"regular"))regular=YES;else if(strcmp(argv[argc-1],"accessory"))bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--watchdog")){watchdog=atoi(argv[argc-1]);argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--level")){char *end=NULL;long value=strtol(argv[argc-1],&end,10);if(end==argv[argc-1]||*end||value<NSNormalWindowLevel||value>NSFloatingWindowLevel+1)bad=YES;else level=(int)value;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--alpha")){char *end=NULL;double value=strtod(argv[argc-1],&end);if(end==argv[argc-1]||*end||!isfinite(value)||value<0||value>1)bad=YES;else alpha=value;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--opaque")){if(!strcmp(argv[argc-1],"yes"))opaque=YES;else if(!strcmp(argv[argc-1],"no"))opaque=NO;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--all-spaces")){if(!strcmp(argv[argc-1],"yes"))allSpaces=YES;else if(!strcmp(argv[argc-1],"no"))allSpaces=NO;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--windows"))count=atoi(argv[argc-1]);
        else if(!strcmp(argv[argc-1],"own"))v2Queue=0;
        else if(!strcmp(argv[argc-1],"main"))v2Queue=1;
        else bad=YES;
        several=YES;argc-=2;
    }
    BOOL popup=[family isEqual:@"popup"]||[family isEqual:@"both"],sheet=[family isEqual:@"sheet"]||[family isEqual:@"both"];
    if((argc!=4 && argc!=5) || bad || count<1 || count+(popup?1:0)+(sheet?1:0)>16 || watchdog<1 || watchdog>900){fprintf(stderr,"usage: host payload.dylib private-runtime nonce [allowlist.json] [--windows 1..16] [--v2-queue own|main] [--activation accessory|regular] [--watchdog 1..900] [--level 0..4] [--alpha 0..1] [--opaque yes|no] [--all-spaces yes|no] [--family none|popup|sheet|both] [--floating-panel yes|no]\n");return 2;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:regular ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
    NSWindowStyleMask style=regular ? NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable : NSWindowStyleMaskTitled;
    NSMutableArray<NSWindow *> *windows=[NSMutableArray array];
    uint32_t wids[16];
    for(int i=0;i<count;i++) {
        // One window where it always was; several as a grid of small ones.
        NSRect frame=several ? NSMakeRect(80+(i%4)*340,160+(i/4)*240,320,200) : NSMakeRect(80,160,480,320);
        BOOL panel=floating&&i==count-1;
        NSWindow *window=[[(panel?NSPanel.class:NSWindow.class) alloc] initWithContentRect:frame styleMask:style|(panel?NSWindowStyleMaskUtilityWindow:0) backing:NSBackingStoreBuffered defer:NO];
        window.level=panel?NSFloatingWindowLevel:level;
        if(panel){((NSPanel *)window).hidesOnDeactivate=NO;window.title=@"DriftWM disposable independent floating panel";}
        // Set through AppKit before ordering only these newly created windows.
        // The helper's restoration oracle captures this initial alpha afterward.
        window.alphaValue=alpha;
        // Opaque-region diagnosis changes only this owned window before ordering;
        // alpha and the helper's transform/alpha restoration contract stay separate.
        window.opaque=opaque;
        // The controlled performance fixture may remain visible across Spaces.
        // Set only these newly constructed windows; no Space is switched.
        if(allSpaces)window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;
        if(!panel)window.title=several ? [NSString stringWithFormat:@"DriftWM disposable fixture %d",i+1] : @"DriftWM disposable privileged-helper fixture";
        NSTextField *label=[NSTextField labelWithString:@"Disposable helper transport / restoration fixture"];
        label.frame=several ? NSMakeRect(10,80,300,40) : NSMakeRect(20,130,440,40);[window.contentView addSubview:label];[window orderFrontRegardless];
        [windows addObject:window];wids[i]=(uint32_t)window.windowNumber;
    }
    // Optional, explicitly created child windows. Their real WindowServer
    // parent links, rather than these AppKit references, are what the desktop
    // must independently discover. Every child is in the helper's finite list.
    if(popup){NSWindow *root=windows[0];NSPanel *child=[[NSPanel alloc]initWithContentRect:NSMakeRect(root.frame.origin.x-70,NSMaxY(root.frame)-20,190,150) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];child.title=@"DriftWM disposable child popup";child.level=level;child.alphaValue=alpha;child.opaque=opaque;child.hidesOnDeactivate=NO;if(allSpaces)child.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;child.contentView.wantsLayer=YES;child.contentView.layer.backgroundColor=NSColor.systemOrangeColor.CGColor;[root addChildWindow:child ordered:NSWindowAbove];[child orderFrontRegardless];wids[count++]=(uint32_t)child.windowNumber;[windows addObject:child];}
    if(sheet){NSWindow *child=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,220,170) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];child.title=@"DriftWM disposable child sheet";child.alphaValue=alpha;child.opaque=opaque;child.contentView.wantsLayer=YES;child.contentView.layer.backgroundColor=NSColor.systemBlueColor.CGColor;[windows[0]beginSheet:child completionHandler:nil];wids[count++]=(uint32_t)child.windowNumber;[windows addObject:child];}
    [NSApp finishLaunching];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    // An optional allowlist file exercises exact process-scope refusal.
    NSString *allowlist=argc==5 ? [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[4]] encoding:NSUTF8StringEncoding error:NULL] : nil;
    if(argc==5 && !allowlist){fprintf(stderr,"cannot read allowlist file %s\n",argv[4]);return 1;}
    void *handle=dlopen(argv[1],RTLD_LOCAL|RTLD_NOW);
    if(!handle){fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
    int status=-1;
    int (*start)(const char *,const char *,const uint32_t *,uint32_t,const char *,int)=dlsym(handle,popup||sheet?"dw_privileged_fixture_start_family_windows":"dw_privileged_fixture_start_windows");
    if(start)status=start(argv[2],argv[3],wids,(uint32_t)count,allowlist ? allowlist.UTF8String : NULL,v2Queue);
    if(status){fprintf(stderr,"helper fixture start failed: %d\n",status);return 1;}
    printf("READY %d",getpid());for(int i=0;i<count;i++)printf(" %u",wids[i]);printf("\n");fflush(stdout);
    // Watchdog bounds fixture lifetime even if the test runner dies. Payload restores
    // controller disconnect first; closing the process removes its own fixture window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)watchdog*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    [NSApp run];return 0;
} }
