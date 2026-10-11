// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#import "protocol.h"
int main(int argc,char **argv) { @autoreleasepool {
    // Trailing flags give protocol v2 several windows to place; without them the
    // host is exactly the one-window fixture it was.
    int count=1,v2Queue=-1;BOOL several=NO,bad=NO;
    while(argc>=6 && (!strcmp(argv[argc-2],"--windows") || !strcmp(argv[argc-2],"--v2-queue"))) {
        if(!strcmp(argv[argc-2],"--windows"))count=atoi(argv[argc-1]);
        else if(!strcmp(argv[argc-1],"own"))v2Queue=0;
        else if(!strcmp(argv[argc-1],"main"))v2Queue=1;
        else bad=YES;
        several=YES;argc-=2;
    }
    if((argc!=4 && argc!=5) || bad || count<1 || count>16){fprintf(stderr,"usage: host payload.dylib private-runtime nonce [allowlist.json] [--windows 1..16] [--v2-queue own|main]\n");return 2;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSMutableArray<NSWindow *> *windows=[NSMutableArray array];
    uint32_t wids[16];
    for(int i=0;i<count;i++) {
        // One window where it always was; several as a grid of small ones.
        NSRect frame=several ? NSMakeRect(80+(i%4)*340,160+(i/4)*240,320,200) : NSMakeRect(80,160,480,320);
        NSWindow *window=[[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title=several ? [NSString stringWithFormat:@"DriftWM disposable fixture %d",i+1] : @"DriftWM disposable privileged-helper fixture";
        NSTextField *label=[NSTextField labelWithString:@"Disposable helper transport / restoration fixture"];
        label.frame=several ? NSMakeRect(10,80,300,40) : NSMakeRect(20,130,440,40);[window.contentView addSubview:label];[window orderFrontRegardless];
        [windows addObject:window];wids[i]=(uint32_t)window.windowNumber;
    }
    [NSApp finishLaunching];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    // An optional allowlist file lets the cooperative e2e drive the spike refusal.
    NSString *allowlist=argc==5 ? [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[4]] encoding:NSUTF8StringEncoding error:NULL] : nil;
    if(argc==5 && !allowlist){fprintf(stderr,"cannot read allowlist file %s\n",argv[4]);return 1;}
    void *handle=dlopen(argv[1],RTLD_LOCAL|RTLD_NOW);
    if(!handle){fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
    int status=-1;
    if(several) {
        int (*start)(const char *,const char *,const uint32_t *,uint32_t,const char *,int)=dlsym(handle,"dw_privileged_fixture_start_windows");
        if(start)status=start(argv[2],argv[3],wids,(uint32_t)count,allowlist ? allowlist.UTF8String : NULL,v2Queue);
    } else {
        int (*start)(const char *,const char *,uint32_t,const char *)=dlsym(handle,"dw_privileged_fixture_start");
        if(start)status=start(argv[2],argv[3],wids[0],allowlist ? allowlist.UTF8String : NULL);
    }
    if(status){fprintf(stderr,"helper fixture start failed: %d\n",status);return 1;}
    printf("READY %d",getpid());for(int i=0;i<count;i++)printf(" %u",wids[i]);printf("\n");fflush(stdout);
    // Watchdog bounds fixture lifetime even if the test runner dies. Payload restores
    // controller disconnect first; closing the process removes its own fixture window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    [NSApp run];return 0;
} }
