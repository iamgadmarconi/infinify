// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — the on-screen layer: redraw gating, the drawable pool
// and presentation statistics. See IFCompositor.h and COMPOSITOR-NOTES.md
// (under docs/).
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"

#import <os/lock.h>
#import <stdatomic.h>

// MARK: - Layer

// Frames the display took, counted where the presented handlers run. Keep the
// sample collection independent of the layer, whose last release stays on main.
typedef struct { double time,submitted,target,cameraX,cameraY,zoom; } IFCPresentationSample;
static const NSUInteger kIFCPresentationSamples=2048;
static int IFCComparePresentation(const void *a,const void *b) {
    double x=((const IFCPresentationSample *)a)->time,y=((const IFCPresentationSample *)b)->time;return (x>y)-(x<y);
}
static int IFCCompareInterval(const void *a,const void *b) {double x=*(const double *)a,y=*(const double *)b;return (x>y)-(x<y);}
@interface IFCPresentedCount : NSObject {
@public
    _Atomic NSUInteger shown;
    os_unfair_lock lock;
    IFCPresentationSample samples[2048];
    NSUInteger sampleCount,overflow,completed,errors,commandCompleted,notPresented;
    double previous,gpuSeconds,gpuWorst,previousCameraX,previousCameraY,previousZoom,completionSeconds,completionWorst;
    BOOL hasCamera;
}
- (IFCompositorPresentationStats)take:(double)interval;
@end
@implementation IFCPresentedCount
- (IFCompositorPresentationStats)take:(double)interval {
    IFCPresentationSample taken[2048];IFCompositorPresentationStats stats={0};double gpuTotal,completionTotal;
    os_unfair_lock_lock(&lock);stats.frames=sampleCount;memcpy(taken,samples,sampleCount*sizeof(*taken));sampleCount=0;
    stats.overflow=overflow;overflow=0;stats.completed=completed;completed=0;stats.errors=errors;errors=0;stats.notPresented=notPresented;notPresented=0;
    gpuTotal=gpuSeconds;gpuSeconds=0;stats.gpuWorst=gpuWorst;gpuWorst=0;
    stats.commandCompleted=commandCompleted;commandCompleted=0;completionTotal=completionSeconds;completionSeconds=0;stats.completionWorst=completionWorst;completionWorst=0;os_unfair_lock_unlock(&lock);
    // A GPU callback need not arrive in presentation order. Sort the actual
    // times before comparing refresh gaps; do not infer them from callback time.
    qsort(taken,stats.frames,sizeof(*taken),IFCComparePresentation);double gaps[2048],sum=0,latency=0;
    for(NSUInteger i=0;i<stats.frames;i++){
        IFCPresentationSample sample=taken[i];double gap=sample.time-previous;
        // Positive callbacks alone do not establish distinct display refreshes.
        // Keep repeated timestamps and callbacks older than the preceding batch
        // explicit; neither can manufacture a new presentation interval.
        if(previous>0){stats.duplicateTime+=gap==0;stats.reorderedTime+=gap<0;}
        if(previous>0&&gap>0){gaps[stats.intervals++]=gap;sum+=gap;stats.gapWorst=fmax(stats.gapWorst,gap);if(interval>0&&gap>interval*1.5)stats.missed+=(NSUInteger)llround(gap/interval)-1;}
        previous=fmax(previous,sample.time);double age=fmax(0,sample.time-sample.submitted);latency+=age;stats.latencyWorst=fmax(stats.latencyWorst,age);
        if(sample.target>0)stats.lateWorst=fmax(stats.lateWorst,sample.time-sample.target);
        if(hasCamera){if(sample.cameraX!=previousCameraX||sample.cameraY!=previousCameraY||sample.zoom!=previousZoom)stats.cameraChanged++;else stats.cameraRepeated++;}
        previousCameraX=sample.cameraX;previousCameraY=sample.cameraY;previousZoom=sample.zoom;hasCamera=YES;
    }
    if(stats.intervals){qsort(gaps,stats.intervals,sizeof(*gaps),IFCCompareInterval);stats.gapMean=sum/stats.intervals;stats.gapP99=gaps[(NSUInteger)ceil(stats.intervals*.99)-1];}
    if(previous>0)stats.presentationSilence=fmax(0,CACurrentMediaTime()-previous);
    if(stats.frames)stats.latencyMean=latency/stats.frames;if(stats.completed)stats.gpuMean=gpuTotal/stats.completed;
    if(stats.commandCompleted)stats.completionMean=completionTotal/stats.commandCompleted;return stats;
}
@end

// Acquire drawables away from input and the main run loop. Publish the ready
// set under a short lock on that worker: a display callback can consume it even
// when its main-queue notification has not run. Layer ownership stays on main,
// with at most one nextDrawable call pending and no queued scene descriptions.
@interface IFCDrawablePool : NSObject
- (instancetype)initWithLayer:(IFCompositorLayer *)layer;
- (id<CAMetalDrawable>)takeFrom:(IFCompositorLayer *)layer;
- (BOOL)waiting;
- (void)takeStats:(IFCompositorPresentationStats *)stats;
- (void)cancel;
@end
@implementation IFCDrawablePool {
    __weak IFCompositorLayer *_layer;
    dispatch_queue_t _queue;
    NSMutableArray<id<CAMetalDrawable>> *_ready;
    os_unfair_lock _lock;
    CGSize _size;
    uint64_t _generation;
    BOOL _transaction,_working,_cancelled,_notificationPending;
    NSUInteger _acquisitions,_timeouts;
    double _acquireSeconds,_acquireWorst,_acquireQueueWorst,_publishWorst,_notificationWorst;
}
- (instancetype)initWithLayer:(IFCompositorLayer *)layer {
    if(!(self=[super init]))return nil;
    _layer=layer;_ready=[NSMutableArray array];_size=layer.drawableSize;_transaction=layer.presentsWithTransaction;
    _queue=dispatch_queue_create("org.infinify.drawable",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    return self;
}
- (void)fill:(IFCompositorLayer *)layer {
    if(!layer)return;
    NSUInteger capacity=MIN((NSUInteger)2,MAX((NSUInteger)1,layer.maximumDrawableCount-1));
    os_unfair_lock_lock(&_lock);
    if(_cancelled||_working||_ready.count>=capacity){os_unfair_lock_unlock(&_lock);return;}
    _working=YES;uint64_t generation=_generation;CGSize wanted=_size;os_unfair_lock_unlock(&_lock);
    BOOL measured=layer.countsPresented;double queued=measured?CACurrentMediaTime():0;
    // Shared storage is cleared on main after the acquisition returns, so a
    // retired CALayer's final release cannot occur on the worker queue.
    __block IFCompositorLayer *held=layer;
    dispatch_async(_queue,^{@autoreleasepool{
        BOOL needsDemand=NO;
        // Replenish the bounded ready set without waiting for main to turn its
        // notification queue. A busy idle reconciliation must not delay the
        // next acquisition after the worker has already published one drawable.
        // The batch is bounded too; it never loops indefinitely holding a layer.
        for(NSUInteger attempt=0;attempt<capacity;attempt++){@autoreleasepool{
            os_unfair_lock_lock(&self->_lock);
            BOOL needed=!self->_cancelled&&generation==self->_generation&&self->_ready.count<capacity;
            os_unfair_lock_unlock(&self->_lock);if(!needed)break;
            double began=measured?CACurrentMediaTime():0;
            id<CAMetalDrawable> drawable=[held nextDrawable];
            double acquired=measured?CACurrentMediaTime():0;
            os_unfair_lock_lock(&self->_lock);
            BOOL valid=!self->_cancelled&&generation==self->_generation&&drawable&&drawable.texture.width==(NSUInteger)wanted.width&&drawable.texture.height==(NSUInteger)wanted.height;
            if(valid)[self->_ready addObject:drawable];
            BOOL notify=valid&&!self->_notificationPending;
            if(notify)self->_notificationPending=YES;
            if(measured){double wait=acquired-began;self->_acquisitions++;self->_timeouts+=!drawable;self->_acquireSeconds+=wait;self->_acquireWorst=fmax(self->_acquireWorst,wait);if(!attempt)self->_acquireQueueWorst=fmax(self->_acquireQueueWorst,began-queued);self->_publishWorst=fmax(self->_publishWorst,CACurrentMediaTime()-acquired);}
            os_unfair_lock_unlock(&self->_lock);
            if(!valid){needsDemand=YES;break;}
            if(notify)dispatch_async(dispatch_get_main_queue(),^{
                os_unfair_lock_lock(&self->_lock);self->_notificationPending=NO;BOOL available=!self->_cancelled&&self->_ready.count;
                if(measured)self->_notificationWorst=fmax(self->_notificationWorst,CACurrentMediaTime()-acquired);os_unfair_lock_unlock(&self->_lock);
                IFCompositorLayer *current=self->_layer;
                if(available&&current.drawableReady)current.drawableReady();
            });
        }}
        os_unfair_lock_lock(&self->_lock);self->_working=NO;os_unfair_lock_unlock(&self->_lock);
        dispatch_async(dispatch_get_main_queue(),^{
            held=nil;IFCompositorLayer *current=self->_layer;
            if(needsDemand){
                // A covered/asleep layer can return nil; a resized layer can
                // return an old size. Ask the owner to retry only if a scene
                // is still owed, rather than acquiring forever after the
                // frame driver stops or retrying an invalid size in a loop.
                if(current.drawableReady)current.drawableReady();
            }else [self fill:current];
        });
    }});
}
- (id<CAMetalDrawable>)takeFrom:(IFCompositorLayer *)layer {
    os_unfair_lock_lock(&_lock);
    if(_cancelled){os_unfair_lock_unlock(&_lock);return nil;}
    if(!CGSizeEqualToSize(_size,layer.drawableSize)||_transaction!=layer.presentsWithTransaction){_size=layer.drawableSize;_transaction=layer.presentsWithTransaction;_generation++;[_ready removeAllObjects];}
    id<CAMetalDrawable> drawable=_ready.firstObject;if(drawable)[_ready removeObjectAtIndex:0];
    os_unfair_lock_unlock(&_lock);[self fill:layer];return drawable;
}
- (BOOL)waiting {os_unfair_lock_lock(&_lock);BOOL waiting=!_cancelled&&_working&&!_ready.count;os_unfair_lock_unlock(&_lock);return waiting;}
- (void)takeStats:(IFCompositorPresentationStats *)stats {
    os_unfair_lock_lock(&_lock);
    stats->acquisitions=_acquisitions;stats->acquireTimeouts=_timeouts;stats->acquireMean=_acquisitions?_acquireSeconds/_acquisitions:0;stats->acquireWorst=_acquireWorst;stats->acquireQueueWorst=_acquireQueueWorst;stats->publishWorst=_publishWorst;stats->notificationWorst=_notificationWorst;
    _acquisitions=_timeouts=0;_acquireSeconds=_acquireWorst=_acquireQueueWorst=_publishWorst=_notificationWorst=0;os_unfair_lock_unlock(&_lock);
}
- (void)cancel {os_unfair_lock_lock(&_lock);_cancelled=YES;_generation++;[_ready removeAllObjects];os_unfair_lock_unlock(&_lock);_layer=nil;}
@end

@implementation IFCompositorLayer {
    BOOL _dirty;
    BOOL _hasLast;
    uint64_t _lastFingerprint;
    double _lastTime;
    BOOL _hasAnimateStamp;
    double _lastAnimate;  // upstream `background_last_animate`, in frame time
    IFCPresentedCount *_presented;  // made with the first handler; nil until `countsPresented`
    IFCDrawablePool *_drawables;
    BOOL _stopped;
}

- (NSUInteger)presentedCount {
    return _presented ? atomic_load(&_presented->shown) : 0;
}
- (IFCompositorPresentationStats)takePresentationStats {IFCompositorPresentationStats stats=_presented?[_presented take:_presentationInterval]:(IFCompositorPresentationStats){0};[_drawables takeStats:&stats];return stats;}
- (BOOL)drawablePending {return [_drawables waiting];}

- (instancetype)init {
    return [self initWithRenderer:nil];
}

- (instancetype)initWithRenderer:(IFCompositorRenderer *)renderer {
    if (!(self = [super init])) return nil;
    _renderer = renderer ?: [IFCompositorRenderer rendererWithDevice:nil];
    if (_renderer) self.device = _renderer.device;
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    // The framebuffer holds sRGB-encoded values (see COMPOSITOR-NOTES.md, "Colour").
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    self.opaque = YES;
    // Until the first frame is drawn; -updateWithFrame: decides it for each frame.
    self.presentsWithTransaction = YES;
    self.allowsNextDrawableTimeout = YES;
    self.needsDisplayOnBoundsChange = NO;
    self.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"contents": NSNull.null,
                     @"contentsScale": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null};
    _dirty = YES;
    return self;
}

// CALayer copies presentation layers through -initWithLayer:.
- (instancetype)initWithLayer:(id)layer {
    if (!(self = [super initWithLayer:layer])) return nil;
    if ([layer isKindOfClass:IFCompositorLayer.class]) _renderer = ((IFCompositorLayer *)layer)->_renderer;
    return self;
}

- (void)setNeedsRedraw {
    _dirty = YES;
}

- (void)stopDrawing { _stopped=YES;self.drawableReady=nil;[_drawables cancel];_drawables=nil; }

- (BOOL)updateWithFrame:(IFCompositorFrame *)frame {
    _missed = NO;
    if (_stopped || !frame || !_renderer) return NO;
    NSUInteger pxW, pxH;
    IFCPixelSize(frame, NULL, NULL, &pxW, &pxH);
    _needsContinuousRedraw = frame.needsContinuousRedraw;
    if (pxW == 0 || pxH == 0 || pxW > kIFCMaxTextureSide || pxH > kIFCMaxTextureSide) return NO;

    uint64_t fingerprint = [frame ifc_fingerprint];
    BOOL need = _dirty || !_hasLast || fingerprint != _lastFingerprint;
    // state/redraw.rs `background_animation_due`: every tick, or at most
    // `animate_fps` times a second.
    BOOL animateDue = NO;
    if ([frame ifc_backgroundAnimates] && (!_hasLast || _lastTime != frame.time)) {
        NSUInteger fps = frame.background.config.animateFPS;
        animateDue = fps == 0 || !_hasAnimateStamp || frame.time < _lastAnimate || frame.time - _lastAnimate >= 1.0 / (double)fps;
    }
    if (!need && !animateDue) {
        [_renderer ifc_flushAgedTextures];
        return NO;
    }

    CGSize drawableSize = CGSizeMake(pxW, pxH);
    // A first, resized or unpaced frame presents inside the host's
    // CATransaction. A paced, unchanged frame presents by command buffer
    // without waiting for scheduling.
    BOOL resized = !_hasLast || !CGSizeEqualToSize(self.drawableSize, drawableSize) || (frame.scale > 0 && self.contentsScale != frame.scale);
    BOOL transaction = resized || !_paced;
    if (self.presentsWithTransaction != transaction) self.presentsWithTransaction = transaction;
    if (self.contentsScale != frame.scale && frame.scale > 0) self.contentsScale = frame.scale;
    if (!CGSizeEqualToSize(self.drawableSize, drawableSize)) self.drawableSize = drawableSize;
    BOOL opaque = frame.clear == IFCompositorClearOpaqueBlack;
    if (self.opaque != opaque) self.opaque = opaque;

    double presentationTarget=_presentationTime;
    if(!_drawables)_drawables=[[IFCDrawablePool alloc]initWithLayer:self];
    id<CAMetalDrawable> drawable=[_drawables takeFrom:self];
    if(!drawable){_missed=YES;return NO;}
    id<MTLCommandBuffer> commandBuffer = [_renderer.commandQueue commandBuffer];
    if (!commandBuffer) {  // still dirty: the next update retries
        _missed = YES;
        return NO;
    }
    if (![_renderer encodeFrame:frame intoTexture:drawable.texture commandBuffer:commandBuffer]) {
        [commandBuffer commit];
        return NO;
    }

    if (_countsPresented) {
        // The handler runs off the main thread and keeps the count, not the layer: a layer's last release stays the host's.
        if (!_presented) _presented = [IFCPresentedCount new];
        IFCPresentedCount *count = _presented;
        double submitted=CACurrentMediaTime(),target=_paced?presentationTarget:0;
        // Copy the camera used to encode, not its later mutable description.
        // A new background clock or captured buffer is not a new camera step.
        double cameraX=frame.cameraX,cameraY=frame.cameraY,zoom=frame.zoom;
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            if(shown.presentedTime<=0){os_unfair_lock_lock(&count->lock);count->notPresented++;os_unfair_lock_unlock(&count->lock);return;}atomic_fetch_add(&count->shown,1);
            os_unfair_lock_lock(&count->lock);
            if(count->sampleCount<kIFCPresentationSamples)count->samples[count->sampleCount++]=(IFCPresentationSample){shown.presentedTime,submitted,target,cameraX,cameraY,zoom};else count->overflow++;
            os_unfair_lock_unlock(&count->lock);
        }];
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> done){double elapsed=done.GPUEndTime-done.GPUStartTime,completion=fmax(0,CACurrentMediaTime()-submitted);
            os_unfair_lock_lock(&count->lock);if(done.status==MTLCommandBufferStatusError)count->errors++;
            count->commandCompleted++;count->completionSeconds+=completion;count->completionWorst=fmax(count->completionWorst,completion);
            if(elapsed>0){count->completed++;count->gpuSeconds+=elapsed;count->gpuWorst=fmax(count->gpuWorst,elapsed);}os_unfair_lock_unlock(&count->lock);
        }];
    }
    if (self.presentsWithTransaction) {
        [commandBuffer commit];
        [commandBuffer waitUntilScheduled];
        [drawable present];
    } else {
        if(presentationTarget>0)[commandBuffer presentDrawable:drawable atTime:presentationTarget];else [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
    if (animateDue) {
        _lastAnimate = frame.time;
        _hasAnimateStamp = YES;
    }
    _lastFingerprint = fingerprint;
    _lastTime = frame.time;
    _hasLast = YES;
    _dirty = NO;
    _drawCount++;
    return YES;
}
@end
