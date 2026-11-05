// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativeResizePresentation.h"
#import "DWGeometryJSON.h"
#import <QuartzCore/QuartzCore.h>

@implementation DWNativeResizePresentation {
    id<DWNativeResizePresenter> _presenter;
    DWResizeCapture _capture;
    DWJob _cancelCapture;
    DWNativeHiddenRoot *_root;
    NSDictionary *_identity;
    id<DWNativeResizePicture> _picture;
    void (^_ready)(BOOL);
    NSUInteger _epoch;
    BOOL _hiding,_hidden,_revealing,_updating,_recovering,_resumed;
    NSTimeInterval _deadline;
    CGRect _target;
}
+ (BOOL)requiresBridgeForTransaction:(NSDictionary *)transaction {
    if(![transaction[@"interactive"]boolValue])return NO;
    return ![@[@"right",@"bottom",@"bottom_right"]containsObject:transaction[@"edges"]?:NSNull.null];
}
+ (DWResizeCapture)snapshotCapture {
    return ^DWJob(DWNativeHiddenRoot *root,BOOL (^valid)(void),void (^completion)(id<DWNativeResizePicture>,NSString *)){
        DWNativeTransitionCapture *capture=[DWNativeTransitionCapture captureIdentity:root.identity nativeBounds:root.nativeBounds screenRect:root.screenRect validate:valid completion:^(DWNativeTransitionCaptureResult *result,NSString *failure){
            DWNativeTransition *picture=result?[[DWNativeTransition alloc]initWithImage:result.image screenRect:result.screenRect]:nil;
            completion((id)picture,failure?:(!picture?@"snapshot panel unavailable":nil));
        }];
        return ^{[capture cancel];};
    };
}
- (instancetype)initWithPresenter:(id<DWNativeResizePresenter>)presenter capture:(DWResizeCapture)capture {
    if((self=[super init])){_presenter=presenter;_capture=[capture copy];
        _clock=^{return CACurrentMediaTime();};
        _delay=^(NSTimeInterval seconds,DWJob job){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),job);};}
    return self;
}
- (BOOL)active {return _effect!=nil;}
- (void)settle:(BOOL)allowed {void (^ready)(BOOL)=_ready;_ready=nil;if(ready)ready(allowed);}
- (void)abort:(NSString *)reason {
    if(_recovering)return;
    // While current, cover emergency restoration until its ordinary placement
    // ACK, bounded after actual native work drains. Session loss uses the journal.
    _recovering=YES;_deadline=0;
    DWJob cancel=_cancelCapture;_cancelCapture=nil;
    if(cancel)cancel();
    [self settle:NO];if(self.failed)self.failed(reason);
    if(!_picture)[self cancel];
}
- (void)prepareEffect:(NSDictionary *)effect ready:(void (^)(BOOL))ready {
    NSAssert(NSThread.isMainThread,@"resize presentation is main-only");
    if(self.active){
        BOOL same=[_effect[@"transaction"]isEqual:effect[@"transaction"]]&&[_effect[@"generation"]isEqual:effect[@"generation"]]&&[_effect[@"identity"]isEqual:effect[@"identity"]];
        [self update];ready(same&&[self allowsEffect:effect]);return;
    }
    _resumed=NO;_effect=[effect copy];_ready=[ready copy];_deadline=self.clock()+2.5;
    // Rust serializes owner:null; the native presenter intentionally binds
    // only these four local-process fields. Preserve the full effect identity
    // for controller fencing, and never admit a named remote/native owner.
    NSDictionary *identity=effect[@"identity"];
    if(identity[@"owner"]&&identity[@"owner"]!=NSNull.null){[self abort:@"Resize cancelled: nonlocal source identity"];return;}
    NSMutableDictionary *native=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"]){
        if(![identity[key]isKindOfClass:NSNumber.class]){[self abort:@"Resize cancelled: invalid source identity"];return;}
        native[key]=identity[key];
    }
    _identity=native.copy;
    [self tick:++_epoch];
}
- (void)beginCaptureWhenReady {
    if(_root||_recovering||!self.active)return;
    // Raising/focusing at resize begin can leave the current placement in
    // flight. A missing token is not yet refusal; retry within preparation's
    // existing bound, before admitting any native work.
    _root=[_presenter beginTransitionForWindow:_identity];
    if(!_root)return;
    NSUInteger epoch=_epoch;
    __weak DWNativeResizePresentation *weak=self;
    BOOL (^valid)(void)=^BOOL{DWNativeResizePresentation *s=weak;return s&&s->_epoch==epoch&&s.active&&!s->_recovering&&s.state&&s.state().valid;};
    _cancelCapture=_capture(_root,valid,^(id<DWNativeResizePicture> picture,NSString *failure){
        DWNativeResizePresentation *s=weak;if(!s||s->_epoch!=epoch||!s.active||s->_recovering){[picture cancel];return;}
        if(!valid()||!picture||![picture show]){[picture cancel];[s abort:[@"Resize cancelled: " stringByAppendingString:failure?:@"snapshot unavailable or binding changed"]];return;}
        s->_picture=picture;[s update];
    });
}
- (void)tick:(NSUInteger)epoch {
    if(epoch!=_epoch||!self.active)return;
    [self update];if(self.render)self.render();
    if(epoch!=_epoch||!self.active)return;
    __weak DWNativeResizePresentation *weak=self;
    self.delay(1.0/60,^{[weak tick:epoch];});
}
- (BOOL)allowsEffect:(NSDictionary *)effect {
    BOOL read=![effect[@"requested"]isKindOfClass:NSDictionary.class];
    return self.active&&!_revealing&&(!_recovering||read)&&[_effect[@"transaction"]isEqual:effect[@"transaction"]]
        &&[_effect[@"identity"]isEqual:effect[@"identity"]]&&[_effect[@"generation"]isEqual:effect[@"generation"]]
        &&((_recovering&&read)||(_hidden&&[_presenter isTransitionHideOwned:_root]));
}
- (void)update {
    if(!self.active||_updating)return;_updating=YES;
    DWNativeResizePresentationState state=self.state?self.state():(DWNativeResizePresentationState){0};
    if(_recovering){
        if(!state.recoverable){[self cancel];_updating=NO;return;}
        // A cancelled AX call can still land. Keep hiding it through the actual
        // worker completion AND the controller's following diagnostic read.
        if(!state.drained){_updating=NO;return;}
        if(!_resumed){_resumed=YES;[_presenter resumeWindow:_identity];_root=nil;_deadline=self.clock()+2.5;}
        else if(state.restored||self.clock()>=_deadline)[self cancel];
        _updating=NO;return;
    }
    if(!state.valid){[self abort:@"Resize cancelled: native binding, session or display changed"];_updating=NO;return;}
    BOOL finished=state.finished;
    if(!_root&&!finished)[self beginCaptureWhenReady];
    if(_picture&&!_hiding)_hiding=[_presenter hideTransition:_root];
    if(_hiding&&!_revealing){
        if(_hidden&&![_presenter isTransitionHideOwned:_root]){[self abort:@"Resize cancelled: native family hide eligibility changed"];_updating=NO;return;}
        if(!_hidden)_hidden=[_presenter isTransitionHidden:_root];
    }
    if(_picture){
        CGRect target=state.screenRect;
        if(![_picture setScreenRect:target]){[self abort:@"Resize cancelled: snapshot geometry unavailable"];_updating=NO;return;}
        if(_revealing&&!CGRectEqualToRect(target,_target)){[self abort:@"Resize cancelled: final placement changed during reveal"];_updating=NO;return;}
        _target=target;
    }
    if(_hidden&&_ready){if(finished)[self settle:NO];else {_deadline=0;[self settle:YES];}}
    // Release/cancel still drains native readback. 'finished' is supplied only
    // for the exact controller terminal state, with no pending obligation.
    if(finished&&state.drained&&_picture&&_hidden){
        if(!_deadline)_deadline=self.clock()+2.5;
        if(!_revealing)_revealing=[_presenter revealTransition:_root screen:_target alpha:state.alpha];
        if(_revealing&&[_presenter isTransitionRevealed:_root]){
            id<DWNativeResizePicture> picture=_picture;_picture=nil;
            [self cancel];[picture finish];_updating=NO;return;
        }
    }
    if(_deadline&&self.clock()>=_deadline)[self abort:@"Resize cancelled: snapshot hide/reveal acknowledgement timed out"];
    _updating=NO;
}
- (void)cancel {
    ++_epoch;DWJob cancel=_cancelCapture;_cancelCapture=nil;
    NSDictionary *effect=_effect,*identity=_identity;_effect=nil;_identity=nil;_root=nil;
    id<DWNativeResizePicture> picture=_picture;_picture=nil;
    _hiding=NO;_hidden=NO;_revealing=NO;_recovering=NO;_deadline=0;
    // Retire before cancellation invokes any capture or coordinator completion.
    if(cancel)cancel();if(identity&&!_resumed){_resumed=YES;[_presenter resumeWindow:identity];}
    [picture cancel];[self settle:NO];if(effect&&self.retired)self.retired();
}
@end
