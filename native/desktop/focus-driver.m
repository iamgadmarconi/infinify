// SPDX-License-Identifier: GPL-3.0-or-later
#import "focus-driver.h"
#import "../focus/focus.h"
#import <AppKit/AppKit.h>
#include <dlfcn.h>
static DWFocusIdentity identity(NSDictionary *i){return (DWFocusIdentity){[i[@"pid"]intValue],[i[@"birth_sec"]unsignedLongLongValue],[i[@"birth_usec"]unsignedLongLongValue],[i[@"wid"]unsignedIntValue]};}
static NSDictionary *json(DWFocusIdentity i){return @{@"pid":@(i.pid),@"birth_sec":@(i.seconds),@"birth_usec":@(i.microseconds),@"wid":@(i.window)};}
@interface DWFocusLease : NSObject
@property (copy) DWGuard guard;
@property CGRect bounds;
@property pid_t foreground;
@property uint64_t seconds,microseconds;
@property BOOL reachedTarget, invalid;
@property DWFocusIdentity target;
@end
@implementation DWFocusLease
@end
static bool allowed(DWFocusIdentity i,void *context){
    DWFocusLease *lease=(__bridge DWFocusLease *)context;
    @synchronized(lease){
    if(lease.invalid||!lease.guard())return false;
    CGRect bounds;if(!dw_focus_owner(i,&bounds)||!CGRectEqualToRect(bounds,lease.bounds)){lease.invalid=YES;return false;}
    pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if(pid==i.pid){lease.reachedTarget=YES;return lease.guard();}
    uint64_t s,u;BOOL valid=!lease.reachedTarget&&pid==lease.foreground&&dw_focus_birth(pid,&s,&u)&&s==lease.seconds&&u==lease.microseconds&&lease.guard();if(!valid)lease.invalid=YES;return valid;
    }
}
static bool driverGuard(DWFocusIdentity i,void *context){(void)i;return ((__bridge DWFocusLease *)context).guard();}
@interface DWNativeFocusDriver ()
@property DWFocusLease *lease;
@property id observer;
@end
@implementation DWNativeFocusDriver
- (instancetype)init {
    if((self=[super init])){__weak DWNativeFocusDriver *weak=self;
        _observer=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note){
            DWNativeFocusDriver *driver=weak;DWFocusLease *lease;@synchronized(driver){lease=driver.lease;}if(!lease)return;
            NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];pid_t pid=app.processIdentifier;uint64_t s,u;BOOL fresh=dw_focus_birth(pid,&s,&u);
            @synchronized(lease){BOOL target=fresh&&pid==lease.target.pid&&s==lease.target.seconds&&u==lease.target.microseconds;
                BOOL original=fresh&&pid==lease.foreground&&s==lease.seconds&&u==lease.microseconds;
                if(target)lease.reachedTarget=YES;else if(!original||lease.reachedTarget)lease.invalid=YES;
            }
        }];
    }return self;
}
- (void)dealloc {if(_observer)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_observer];}

- (DWGuard)authorization:(NSDictionary *)value {
    if(value[@"owner"]&&value[@"owner"]!=NSNull.null)return nil;
    DWFocusIdentity i=identity(value);DWFocusLease *lease=[DWFocusLease new];lease.guard=^BOOL{return YES;};
    CGRect bounds;if(!dw_focus_owner(i,&bounds))return nil;lease.bounds=bounds;
    lease.foreground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    uint64_t s,u;if(!dw_focus_birth(lease.foreground,&s,&u))return nil;lease.seconds=s;lease.microseconds=u;
    lease.target=i;@synchronized(self){self.lease=lease;}
    return ^BOOL{return allowed(i,(__bridge void *)lease);};
}
- (BOOL)select:(NSDictionary *)value guard:(DWGuard)guard {
    DWFocusLease *lease=[DWFocusLease new];lease.guard=guard;
    // The coordinator captured ownership/foreground authorization at intent time.
    DWFocusResult result=dw_focus_select(identity(value),driverGuard,(__bridge void *)lease);
    // INFINIFY_DEBUG in the environment: what each native focus request came to, on stderr.
    if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native focus pid=%d wid=%u outcome=%s focused=%d ax_error=%d frontmost=%d\n",(int)[value[@"pid"]intValue],[value[@"wid"]unsignedIntValue],dw_focus_outcome_name(result.outcome),(int)result.focused,(int)result.ax_error,(int)NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    return result.focused&&guard();
}
- (NSDictionary *)observe {
    // One foreground AX lookup, followed by one independently validated exact readback.
    if(!AXIsProcessTrusted())return nil;
    AXError (*get)(AXUIElementRef,uint32_t *)=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");if(!get)return nil;
    pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    AXUIElementRef app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,.1);
    CFTypeRef window=NULL;AXError error=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute,&window);uint32_t wid=0;
    BOOL valid=!error&&window&&CFGetTypeID(window)==AXUIElementGetTypeID();
    if(valid)valid=AXUIElementSetMessagingTimeout(window,.1)==kAXErrorSuccess&&get(window,&wid)==kAXErrorSuccess;
    if(window)CFRelease(window);CFRelease(app);DWFocusIdentity i;
    if(!valid||!dw_focus_identity(pid,wid,&i))return nil;
    return dw_focus_observe(i).focused?json(i):nil;
}
@end
