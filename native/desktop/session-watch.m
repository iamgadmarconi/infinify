// SPDX-License-Identifier: GPL-3.0-or-later
#import "session-watch.h"
#import <QuartzCore/QuartzCore.h>

static BOOL sessionBoolean(id value,BOOL expected) {
    return value&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()&&[value boolValue]==expected;
}
static BOOL sessionReady(void) {
    NSDictionary *session=CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if(![session isKindOfClass:NSDictionary.class]
        ||!sessionBoolean(session[(__bridge NSString *)kCGSessionOnConsoleKey],YES)
        ||!sessionBoolean(session[(__bridge NSString *)kCGSessionLoginDoneKey],YES)
        ||sessionBoolean(session[@"CGSSessionScreenIsLocked"],YES))return NO;
    // The lock dictionary entry is private and optional. Missing/malformed
    // metadata stays unknown; it is never interpreted as an unlocked proof.
    CGDirectDisplayID displays[32]={0};uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess||!count||count>=32)return NO;
    CGDirectDisplayID main=CGMainDisplayID();BOOL found=NO;
    for(uint32_t i=0;i<count;i++){
        if(!displays[i])return NO;
        for(uint32_t j=0;j<i;j++)if(displays[j]==displays[i])return NO;
        if(displays[i]==main)found=YES;
    }
    return found&&CGDisplayIsOnline(main)&&CGDisplayIsActive(main)&&!CGDisplayIsAsleep(main);
}

@implementation DWSessionWatch {
    void (^_returned)(void);
    void (^_left)(void);
    NSMutableArray *_observers;
    NSUInteger _inactive;
    BOOL _ready,_stopped;
    CFTimeInterval _retryAfter;
}
- (BOOL)ready { return _ready; }
- (void)refreshReturning:(BOOL)returning {
    if(_stopped||_inactive)return;
    BOOL wasReady=_ready;_ready=sessionReady();_retryAfter=CACurrentMediaTime()+.5;
    if(!_ready&&wasReady){if(_left)_left();}
    else if(_ready&&(returning||!wasReady)){if(_returned)_returned();}
}
- (void)poll {
    if(_stopped||_ready||_inactive||CACurrentMediaTime()<_retryAfter)return;
    [self refreshReturning:NO];
}
- (instancetype)initWithReturned:(void (^)(void))returned {
    return [self initWithReturned:returned left:nil];
}
- (instancetype)initWithReturned:(void (^)(void))returned left:(void (^)(void))left {
    if((self=[super init])){
        _returned=[returned copy];_left=[left copy];_observers=[NSMutableArray array];__weak DWSessionWatch *weak=self;
        NSArray *leaves=@[NSWorkspaceWillSleepNotification,NSWorkspaceScreensDidSleepNotification,NSWorkspaceSessionDidResignActiveNotification];
        NSArray *returns=@[NSWorkspaceDidWakeNotification,NSWorkspaceScreensDidWakeNotification,NSWorkspaceSessionDidBecomeActiveNotification,NSWorkspaceActiveSpaceDidChangeNotification];
        for(NSUInteger i=0;i<leaves.count;i++){NSUInteger bit=1UL<<i;
            [_observers addObject:[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:leaves[i] object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                (void)note;DWSessionWatch *watch=weak;if(!watch||watch->_stopped)return;BOOL first=watch->_ready;watch->_inactive|=bit;watch->_ready=NO;void (^left)(void)=watch->_left;if(first&&left)left();}]];
        }
        for(NSUInteger i=0;i<returns.count;i++){NSUInteger bit=i<3?1UL<<i:0;
            [_observers addObject:[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:returns[i] object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                (void)note;DWSessionWatch *watch=weak;if(!watch||watch->_stopped)return;watch->_inactive&=~bit;[watch refreshReturning:YES];}]];
        }
        _ready=sessionReady();_retryAfter=CACurrentMediaTime()+.5;
    }
    return self;
}
- (void)stop { _stopped=YES;_ready=NO;for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];[_observers removeAllObjects];_returned=nil;_left=nil; }
- (void)dealloc { for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer]; }
@end
