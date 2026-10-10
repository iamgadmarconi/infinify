// SPDX-License-Identifier: GPL-3.0-or-later
#import "session-watch.h"

@implementation DWSessionWatch {
    void (^_returned)(void);
    NSMutableArray *_observers;
}
- (instancetype)initWithReturned:(void (^)(void))returned {
    if((self=[super init])){
        _returned=[returned copy];_observers=[NSMutableArray array];__weak DWSessionWatch *weak=self;
        for(NSNotificationName name in @[NSWorkspaceDidWakeNotification,NSWorkspaceScreensDidWakeNotification,NSWorkspaceSessionDidBecomeActiveNotification,NSWorkspaceActiveSpaceDidChangeNotification])
            [_observers addObject:[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                (void)note;DWSessionWatch *watch=weak;void (^returned)(void)=watch?watch->_returned:nil;if(returned)returned();}]];
    }
    return self;
}
- (void)stop { for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];[_observers removeAllObjects];_returned=nil; }
- (void)dealloc { for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer]; }
@end
