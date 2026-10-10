// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#import "protocol.h"
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=4 && argc!=5){fprintf(stderr,"usage: host payload.dylib private-runtime nonce [allowlist.json]\n");return 2;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,160,480,320) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title=@"DriftWM disposable privileged-helper fixture";
    NSTextField *label=[NSTextField labelWithString:@"Disposable helper transport / restoration fixture"];
    label.frame=NSMakeRect(20,130,440,40);[window.contentView addSubview:label];[window orderFrontRegardless];
    [NSApp finishLaunching];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    // An optional allowlist file lets the cooperative e2e drive the spike refusal.
    NSString *allowlist=argc==5 ? [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[4]] encoding:NSUTF8StringEncoding error:NULL] : nil;
    if(argc==5 && !allowlist){fprintf(stderr,"cannot read allowlist file %s\n",argv[4]);return 1;}
    void *handle=dlopen(argv[1],RTLD_LOCAL|RTLD_NOW);
    if(!handle){fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
    int (*start)(const char *,const char *,uint32_t,const char *)=dlsym(handle,"dw_privileged_fixture_start");
    int status=start ? start(argv[2],argv[3],(uint32_t)window.windowNumber,allowlist ? allowlist.UTF8String : NULL) : -1;
    if(status){fprintf(stderr,"helper fixture start failed: %d\n",status);return 1;}
    printf("READY %d %ld\n",getpid(),(long)window.windowNumber);fflush(stdout);
    // Watchdog bounds fixture lifetime even if the test runner dies. Payload restores
    // controller disconnect first; closing the process removes its own fixture window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    [NSApp run];return 0;
} }
