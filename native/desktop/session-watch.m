// SPDX-License-Identifier: GPL-3.0-or-later
#import "session-watch.h"

@implementation DWSessionWatch {
    void (^_returned)(void);
    void (^_left)(void);
    NSMutableArray *_observers;
    NSUInteger _inactive;
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
                (void)note;DWSessionWatch *watch=weak;if(!watch)return;BOOL first=!watch->_inactive;watch->_inactive|=bit;void (^left)(void)=watch->_left;if(first&&left)left();}]];
        }
        for(NSUInteger i=0;i<returns.count;i++){NSUInteger bit=i<3?1UL<<i:0;
            [_observers addObject:[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:returns[i] object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                (void)note;DWSessionWatch *watch=weak;if(!watch)return;watch->_inactive&=~bit;void (^returned)(void)=watch->_returned;if(!watch->_inactive&&returned)returned();}]];
        }
    }
    return self;
}
- (void)stop { for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];[_observers removeAllObjects];_returned=nil;_left=nil; }
- (void)dealloc { for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer]; }
@end
