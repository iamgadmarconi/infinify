// SPDX-License-Identifier: GPL-3.0-or-later
#import "scene-writer.h"
#include <os/lock.h>
#include <stdio.h>
#include <string.h>

@interface DWSceneSave : NSObject
@property DriftDesktop *controller;
@property NSData *request;
@property uint64_t generation;
@end
@implementation DWSceneSave
- (void)dealloc {driftwm_desktop_destroy(_controller);}
@end

@implementation DWSceneWriter {
    os_unfair_lock _lock;
    dispatch_queue_t _worker;
    dispatch_group_t _active;
    DWSceneSave *_pending;
    BOOL _running;
    uint64_t _generation;
}
- (instancetype)init {
    if((self=[super init])){
        _lock=OS_UNFAIR_LOCK_INIT;_active=dispatch_group_create();
        _worker=dispatch_queue_create("org.infinify.scene-writer",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    }
    return self;
}
- (BOOL)submit:(DriftDesktop *)controller path:(NSString *)path {
    DWSceneSave *save=[DWSceneSave new];save.controller=driftwm_desktop_clone(controller);
    if(!save.controller)return NO;
    save.request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":@{@"op":@"save",@"path":path}} options:0 error:nil];
    if(!save.request)return NO;
    os_unfair_lock_lock(&_lock);
    __attribute__((objc_precise_lifetime)) DWSceneSave *replaced=_pending;save.generation=++_generation;_pending=save;
    BOOL start=!_running;if(start){_running=YES;dispatch_group_enter(_active);}
    os_unfair_lock_unlock(&_lock);
    // Replaced copies have never reached the worker; release outside its lock.
    (void)replaced;replaced=nil;
    if(start)dispatch_async(_worker,^{[self run];});
    return YES;
}
- (void)run {
    for(;;){@autoreleasepool{
        os_unfair_lock_lock(&_lock);DWSceneSave *save=_pending;_pending=nil;
        if(!save){_running=NO;dispatch_group_leave(_active);os_unfair_lock_unlock(&_lock);return;}
        os_unfair_lock_unlock(&_lock);
        // Only this worker accesses the copied handle. The existing Rust save
        // owns atomic rename, file fsync, directory fsync and temporary cleanup.
        char *answer=driftwm_desktop_request(save.controller,save.request.bytes,save.request.length);
        NSDictionary *reply=answer?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:answer length:strlen(answer)] options:0 error:nil]:nil;
        driftwm_desktop_response_free(answer);
        if(![reply[@"ok"]boolValue]){
            NSString *reason=[reply[@"error"]isKindOfClass:NSString.class]?reply[@"error"]:@"scene writer received no valid controller reply";
            fprintf(stderr,"Infinify: scene save failed: %s\n",reason.UTF8String);
            uint64_t generation=save.generation;
            dispatch_async(dispatch_get_main_queue(),^{
                os_unfair_lock_lock(&self->_lock);BOOL latest=self->_generation==generation;os_unfair_lock_unlock(&self->_lock);
                if(latest&&self.failed)self.failed(reason);
            });
        }
    }}
}
- (void)drain {dispatch_group_wait(_active,DISPATCH_TIME_FOREVER);}
@end
