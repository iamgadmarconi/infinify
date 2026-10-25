// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable opaque marker windows. No unrelated window or setting is changed.
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <signal.h>

int main(int argc,const char **argv) {
    @autoreleasepool {
        int count=4,watchdog=300;double width=480,height=320;
        while(argc>4){
            if(argc<6)return 64;
            const char *key=argv[argc-2],*value=argv[argc-1];
            if(!strcmp(key,"--windows"))count=atoi(value);
            else if(!strcmp(key,"--watchdog"))watchdog=atoi(value);
            else if(!strcmp(key,"--size")){if(sscanf(value,"%lfx%lf",&width,&height)!=2)return 64;}
            else if(strcmp(key,"--all-spaces")||strcmp(value,"yes"))return 64;
            argc-=2;
        }
        if(argc!=4||count<1||count>16||watchdog<1||watchdog>900||width<40||height<40||width>8192||height>8192)return 64;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSMutableArray<NSWindow *> *windows=[NSMutableArray array];uint32_t ids[16]={0};
        for(int i=0;i<count;i++){
            NSRect frame=NSMakeRect(100+i*35,150+i*35,width,height);
            NSWindow *window=[[NSWindow alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            window.title=[NSString stringWithFormat:@"Infinify disposable marker %d",i+1];
            window.opaque=YES;window.hasShadow=NO;window.releasedWhenClosed=NO;
            // Dock may own a transparent full-display container above ordinary
            // floating windows. Raise only these disposable markers above that
            // container; never exempt it from the observer's occlusion witness.
            window.level=NSMainMenuWindowLevel+1;
            window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;
            // Only the top-most first window is magenta; no other source uses it.
            window.backgroundColor=i==0?NSColor.magentaColor:[NSColor colorWithCalibratedRed:0.1 green:0.3+0.025*i blue:0.6 alpha:1];
            [windows addObject:window];
        }
        for(NSWindow *window in windows.reverseObjectEnumerator)[window orderFrontRegardless];
        for(int i=0;i<count;i++)ids[i]=(uint32_t)windows[i].windowNumber;
        // WindowServer metadata registration is asynchronous. The helper's
        // independent owner/PID admission must not race first ordering.
        [NSApp finishLaunching];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,.2,false);
        void *payload=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!payload)return 1;
        int(*start)(const char *,const char *,const uint32_t *,uint32_t,const char *,int)=dlsym(payload,"dw_privileged_fixture_start_windows");
        if(!start||start(argv[2],argv[3],ids,(uint32_t)count,NULL,-1))return 1;
        printf("READY %d",getpid());for(int i=0;i<count;i++)printf(" %u",ids[i]);puts("");fflush(stdout);
        signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
        dispatch_source_t term=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
        dispatch_source_t interrupt=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(term,^{[NSApp terminate:nil];});dispatch_resume(term);
        dispatch_source_set_event_handler(interrupt,^{[NSApp terminate:nil];});dispatch_resume(interrupt);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)watchdog*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
        [NSApp run];
    }
    return 0;
}
