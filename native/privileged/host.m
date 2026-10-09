// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#import "protocol.h"
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=4){fprintf(stderr,"usage: host payload.dylib private-runtime nonce\n");return 2;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,160,480,320) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title=@"DriftWM disposable privileged-helper fixture";
    NSTextField *label=[NSTextField labelWithString:@"Disposable helper transport / restoration fixture"];
    label.frame=NSMakeRect(20,130,440,40);[window.contentView addSubview:label];[window orderFrontRegardless];
    [NSApp finishLaunching];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    void *handle=dlopen(argv[1],RTLD_LOCAL|RTLD_NOW);
    if(!handle){fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
    int (*start)(const char *,const char *,uint32_t)=dlsym(handle,"dw_privileged_fixture_start");
    int status=start ? start(argv[2],argv[3],(uint32_t)window.windowNumber) : -1;
    if(status){fprintf(stderr,"helper fixture start failed: %d\n",status);return 1;}
    printf("READY %d %ld\n",getpid(),(long)window.windowNumber);fflush(stdout);
    // Watchdog bounds fixture lifetime even if the test runner dies. Payload restores
    // controller disconnect first; closing the process removes its own fixture window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    [NSApp run];return 0;
} }
