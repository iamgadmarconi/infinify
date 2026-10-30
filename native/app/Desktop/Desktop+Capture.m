// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop capture: window streams, capture demand and recovery, screenshots and one-shot native export.
#import "Desktop+Private.h"
#include <stdatomic.h>
#import "DWWindowEvents.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
// Cold one-shot capture can lose its temporary stream while the source remains
// valid. Retry only recoverable ScreenCaptureKit failures, inside the original
// request deadline; authorization/configuration failures are final.
static BOOL DWExportRetryable(NSError *error) {
    if(![error.domain isEqual:SCStreamErrorDomain])return NO;
    switch(error.code){
        case SCStreamErrorFailedToStart:case SCStreamErrorInternalError:
        case SCStreamErrorFailedApplicationConnectionInterrupted:
        case SCStreamErrorNoWindowList:case SCStreamErrorNoCaptureSource:
        case SCStreamErrorSystemStoppedStream:return YES;
        default:return NO;
    }
}
// Immutable native capture plan, made on a read-only worker. Geometry is kept
// here in native coordinates; the renderer receives normalized image offsets.
static NSArray<NSDictionary *> *DWNativeExportPlan(NSArray<NSDictionary *> *roots,BOOL families,NSString *__autoreleasing *why) {
    NSMutableDictionary<NSNumber *,NSNumber *> *rank=[NSMutableDictionary dictionary],*owners=[NSMutableDictionary dictionary];
    // Only OnScreenOnly promises front-to-back ordering. Offscreen families
    // remain capturable, but supply no authority to interleave export families.
    NSArray *ordered=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    for(NSUInteger i=0;i<ordered.count;i++){NSNumber *wid=DWTyped(ordered[i][(id)kCGWindowNumber],NSNumber.class),*pid=DWTyped(ordered[i][(id)kCGWindowOwnerPID],NSNumber.class);if(wid&&pid){if(rank[wid]){*why=@"native export stacking observation has duplicate windows";return nil;}rank[wid]=@(i);owners[wid]=pid;}}
    NSMutableArray<NSMutableDictionary *> *items=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *root in roots){NSDictionary *identity=root[@"identity"];CGRect own=CGRectZero;
        if(!((NSString *)DWTyped(root[@"capture_key"],NSString.class)).length||!DWNativeBounds([identity[@"wid"]unsignedIntValue],&own)||!isfinite(own.size.width)||!isfinite(own.size.height)||own.size.width<=0||own.size.height<=0){*why=@"native export could not read the root's own bounds";return nil;}
        NSArray *members=nil;
        if(families){NSDictionary *family=DWNativeWindowFamily(identity,why);if(!family)return nil;members=family[@"members"];}
        else members=@[@{@"identity":identity,@"native_bounds":DWRectJSON(own)}];
        BOOL hasRoot=NO,rankedFamily=YES;for(NSDictionary *member in members){NSDictionary *named=member[@"identity"];NSNumber *wid=named[@"wid"];
            if((rank[wid]&&![owners[wid]isEqual:named[@"pid"]])||[seen containsObject:wid]){*why=@"native export family changed during the stacking read";return nil;}
            if(!rank[wid])rankedFamily=NO;
            [seen addObject:wid];if([named isEqual:identity])hasRoot=YES;}
        if(!hasRoot){*why=@"native export family omitted its root";return nil;}
        members=[members sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSNumber *aw=a[@"identity"][@"wid"],*bw=b[@"identity"][@"wid"];
            if([aw isEqual:bw])return NSOrderedSame;
            if([aw isEqual:identity[@"wid"]])return NSOrderedAscending;if([bw isEqual:identity[@"wid"]])return NSOrderedDescending;
            // Unranked families keep a stable root-then-child fallback; no
            // partial observed order can move them through another family.
            return rankedFamily?[rank[bw]compare:rank[aw]]:[aw compare:bw];
        }];
        NSUInteger memberIndex=0;for(NSDictionary *member in members){CGRect r=DWRectFromJSON(member[@"native_bounds"]);
            CGRect unit=CGRectMake((r.origin.x-own.origin.x)/own.size.width,(r.origin.y-own.origin.y)/own.size.height,r.size.width/own.size.width,r.size.height/own.size.height);
            NSMutableDictionary *item=[root mutableCopy];item[@"member"]=member[@"identity"];item[@"native_bounds"]=member[@"native_bounds"];item[@"root_bounds"]=DWRectJSON(own);item[@"unit_rect"]=DWRectJSON(unit);
            item[@"capture_member_key"]=[NSString stringWithFormat:@"%@:%lu",root[@"capture_key"],(unsigned long)memberIndex++];if(rankedFamily)item[@"stack_rank"]=rank[member[@"identity"][@"wid"]];
            [items addObject:item];}
    }
    // Compare only relative ranks inside this request. An unrelated window can
    // enter the desktop without invalidating otherwise identical captured order.
    NSMutableArray *eligible=[NSMutableArray array];for(NSDictionary *item in items)if(item[@"stack_rank"])[eligible addObject:item];
    NSArray *ranked=[eligible sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"stack_rank"]compare:b[@"stack_rank"]];}];
    for(NSUInteger i=0;i<ranked.count;i++)ranked[i][@"stack_rank"]=@(i);
    NSMutableArray *frozen=[NSMutableArray arrayWithCapacity:items.count];for(NSDictionary *item in items)[frozen addObject:item.copy];return frozen.copy;
}
// Frozen one-shot evidence is separate from the live replica stream cohort.
static NSDictionary *DWExportOrderCohort(NSArray<NSDictionary *> *items) {
    NSMutableDictionary *cohort=[NSMutableDictionary dictionary];
    for(NSDictionary *item in items){if(!item[@"stack_rank"])continue;NSNumber *window=item[@"window"];NSMutableDictionary *family=cohort[window];
        if(!family){family=[@{@"children":[NSMutableDictionary dictionary]}mutableCopy];cohort[window]=family;}
        if([item[@"member"]isEqual:item[@"identity"]])family[@"root"]=item;
        else family[@"children"][item[@"capture_member_key"]]=item[@"stack_rank"];
    }
    NSMutableDictionary *frozen=[NSMutableDictionary dictionary];for(NSNumber *window in cohort){NSDictionary *family=cohort[window];if(family[@"root"])frozen[window]=@{@"root":family[@"root"],@"children":[family[@"children"]copy]};}return frozen.copy;
}
static BOOL DWNativeExportCurrent(NSDictionary *item,BOOL families) {
    NSDictionary *root=item[@"identity"],*member=item[@"member"];
    NSArray *born=@[member[@"birth_sec"],member[@"birth_usec"]];CGRect own=CGRectZero,rootOwn=CGRectZero;
    if(![birth([member[@"pid"]intValue])isEqual:born]||[windowInfo([member[@"wid"]unsignedIntValue])[(id)kCGWindowOwnerPID]intValue]!=[member[@"pid"]intValue]
        ||!DWNativeBounds([member[@"wid"]unsignedIntValue],&own)||!DWNativeBounds([root[@"wid"]unsignedIntValue],&rootOwn)
        ||!CGRectEqualToRect(own,DWRectFromJSON(item[@"native_bounds"]))||!CGRectEqualToRect(rootOwn,DWRectFromJSON(item[@"root_bounds"])))return NO;
    return !families||DWNativeWindowBelongsToRoot(member,root);
}
// The macOS 26 screenshot API returns an image rather than a live-stream sample.
// Convert it on the completion queue to the renderer's sRGB, IOSurface-backed BGRA.
static CVPixelBufferRef DWExportPixels(CGImageRef image) {
    if(!image)return NULL;size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);CVPixelBufferRef pixels=NULL;
    NSDictionary *attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if(!width||!height||width>16384||height>16384||CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&pixels)!=kCVReturnSuccess)return NULL;
    if(CVPixelBufferLockBaseAddress(pixels,0)!=kCVReturnSuccess){CVPixelBufferRelease(pixels);return NULL;}
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels),width,height,8,CVPixelBufferGetBytesPerRow(pixels),color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);CGColorSpaceRelease(color);
    if(context){CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);}
    CVPixelBufferUnlockBaseAddress(pixels,0);if(!context){CVPixelBufferRelease(pixels);return NULL;}return pixels;
}
// The compositor reads a stream's buffers as sRGB values, and holds the current one and
// the one before it until the frame that sampled it has completed: its stream says sRGB
// and has buffers to spare. A second output needs the whole root even when the native
// placement is clipped by its output. Children have separate native identities and must
// not silently change this image's root-relative geometry.
static void compositedStream(SCStreamConfiguration *config) {
    config.colorSpaceName=kCGColorSpaceSRGB;config.queueDepth=5;
    config.ignoreGlobalClipSingleWindow=YES;config.includeChildWindows=NO;
}
// The window-capture configuration of a stream: its pixel size and request interval.
static SCStreamConfiguration *windowCaptureConfiguration(CGSize pixels,CMTime interval) {
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;
    config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=interval;config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;
    compositedStream(config);return config;
}
@implementation Desktop (Capture)
// How often a window's picture is asked for, at most: as often as the display it is shown on refreshes, the fastest screen a canvas panel is on,
// and 60 times a second at least. Rate changes are reconciled independently of pixel-size changes. Frame-status and dirty-rectangle
// checks skip frames that explicitly report no changed content; some streams still report complete frames at the full requested rate.
- (CMTime)captureInterval {NSInteger rate=60;for(NSScreen *screen in [self canvasScreens])rate=MAX(rate,screen.maximumFramesPerSecond);return CMTimeMake(1,(int32_t)rate); }
// One stream for a source at a pixel size. NO leaves the reason in source.error.
- (BOOL)startCapture:(LiveSource *)source size:(CGSize)pixels interval:(CMTime)interval {
    // An --only-pid run without Screen Recording access has no shareable window to make a filter of. -captureDemand never comes here for one.
    // The one NO that leaves source.error alone: a reason there would have -track: detach a source that nothing is wrong with.
    if(!source.window||source.detached||self.cleaning)return NO;
    source.error=nil;source.captureRecovering=NO;source.captureRetryAt=0;
    source.captureSize=pixels;CGRect native=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&native);source.captureNativeSize=native.size;source.captureCandidateSince=0;
    SCStreamConfiguration *config=windowCaptureConfiguration(pixels,interval);
    source.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:source.window] configuration:config delegate:source];source.restarted=YES;NSError *error=nil;
    source.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:source stream:source.stream];
    if(![source.stream addStreamOutput:source.captureMailbox type:SCStreamOutputTypeScreen sampleHandlerQueue:source.captureMailbox.queue error:&error]){source.stream=nil;[source captureFailed:error];return NO;}
    uint64_t serial=[source beginCaptureConfiguration:config];
    SCStream *starting=source.stream;[starting startCaptureWithCompletionHandler:^(NSError *e){dispatch_async(dispatch_get_main_queue(),^{if(source.stream!=starting||source.detached||self.cleaning||![source completeCaptureConfiguration:serial success:e==nil])return;if(e){source.stream=nil;[source captureFailed:e];if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: capture start failed window=%s pid=%d wid=%u: %s (%ld)\n",source.logical.stringValue.UTF8String,source.router.pid,source.router.wid,e.localizedDescription.UTF8String,(long)e.code);}});}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(source.stream!=starting||source.detached||self.cleaning||!DWCaptureConfigurationPending(source.captureConfiguration,serial))return;[self stopCapture:source];[source captureFailed:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorFailedToStart userInfo:@{NSLocalizedDescriptionKey:@"Capture start timed out"}]];});
    return YES;
}
// An intentional stop is no error: the stream is forgotten first, so nothing it still
// reports is read, and cleanup waits for the stop like any other. The compositor keeps
// the last picture, so a window whose placement returns is not blank until its stream
// delivers again.
- (void)stopCapture:(LiveSource *)source {
    SCStream *stream=source.stream;if(!stream)return;source.stream=nil;source.captureCandidateSince=0;
    [self.pendingStops addObject:stream];[stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{[self.pendingStops removeObject:stream];});}];
}
// A larger tile needs sharper pixels immediately. Density buckets grow by sqrt(2), limiting their area slack to 2x
// instead of 4x just above each power of two. Smaller tiles change buckets after half a second of
// stable actual density as well as bucket demand. Continuous zoom may linger in a bucket longer than that; it must not
// repeatedly shrink and regrow all streams while the scale is still moving. The largest placement across all outputs
// wins, including pinned windows and widgets. Cropping does not lower density. Native ownership and world geometry are unchanged.
- (CGSize)capturePixels:(LiveSource *)source native:(CGSize)native placements:(NSArray *)placements scales:(NSDictionary *)scales demandDensity:(double *)demand {
    double density=0;
    for(NSDictionary *p in placements)if([p[@"window"]isEqual:source.logical]){CGRect r=DWRectFromJSON(p[@"screen_rect"]);if(CGRectIsNull(r))continue;double scale=[scales[p[@"output"]]doubleValue];density=fmax(density,fmax(r.size.width/native.width,r.size.height/native.height)*(scale>0?scale:2));}
    if(density<=0)density=source.captureNativeSize.width>0?source.captureSize.width/source.captureNativeSize.width:2;
    density=fmin(2,fmax(1.0/32,density));if(demand)*demand=density;
    density=fmax(density,exp2(ceil(2*log2(density))*.5));
    return CGSizeMake(MAX(2,ceil(native.width*density)),MAX(2,ceil(native.height*density)));
}
- (void)updateCapture:(LiveSource *)source size:(CGSize)pixels native:(CGSize)native interval:(CMTime)interval {
    if(!source.stream||source.captureUpdating||source.error||source.detached)return;
    // A rate-only update preserves the current picture and a pending shrink's
    // stability clock. Only a changed raster/native size needs a fresh image.
    if(!CGSizeEqualToSize(pixels,source.captureSize)||!CGSizeEqualToSize(native,source.captureNativeSize)){source.captureCandidateSince=0;source.restarted=YES;}
    source.captureSize=pixels;source.captureNativeSize=native;
    SCStreamConfiguration *config=windowCaptureConfiguration(pixels,interval);
    uint64_t serial=[source beginCaptureConfiguration:config];
    SCStream *stream=source.stream;[stream updateConfiguration:config completionHandler:^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{if(source.stream!=stream||source.detached||self.cleaning||![source completeCaptureConfiguration:serial success:error==nil])return;if(error){[self stopCapture:source];[source captureFailed:error];}});}];
}
// Capture on demand, in a managed run: a stream runs while its window has a placement
// on some output and for two seconds after the last one went, and starts again when one
// returns. Transient failures keep their binding for -captureRecovery.
- (void)captureDemand {
    if(!self.manager||!self.sources.count||self.sessionInactive){[self.nativeFamilies reset];return;}
    if(self.native.ended){[self.nativeFamilies reset];for(LiveSource *source in self.sources.allValues){source.replicaWanted=NO;[self stopCapture:source];}return;}
    NSDictionary *snapshot=[self presentationSnapshot];if(!snapshot)return;
    if(self.native&&!self.nativeViews.capturedWindows.count){
        BOOL draining=NO;for(LiveSource *source in self.sources.allValues)if(source.stream||source.replicaWanted){draining=YES;break;}
        if(!draining){[self.nativeFamilies reset];return;}
    }
    NSMutableDictionary *outputs=[NSMutableDictionary dictionary],*captureSites=[NSMutableDictionary dictionary],*scales=[NSMutableDictionary dictionary];
    for(NSDictionary *output in snapshot[@"outputs"])if(output[@"id"])outputs[output[@"id"]]=output;
    for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)scales[output]=@(view.window.backingScaleFactor);
    NSMutableSet<NSNumber *> *placed=[NSMutableSet set];NSMutableArray *pictures=[NSMutableArray array];
    for(NSDictionary *p in snapshot[@"placements"])if(!self.native||[self.nativeViews replica:p[@"window"] output:p[@"output"]]){
        NSNumber *window=p[@"window"];[placed addObject:window];[pictures addObject:p];
        if(!captureSites[window])captureSites[window]=[NSMutableArray array];
        // The viewport is the output, not the root's clip: a child may extend
        // into it from outside its root, including family-only placements.
        NSDictionary *output=outputs[p[@"output"]];double scale=[scales[p[@"output"]]doubleValue],zoom=[p[@"pinned"]boolValue]?1:[output[@"zoom"]doubleValue];
        // Surface origin/extent round before zoom, then both final corners
        // round again. Include that error plus a physical pixel of fringe.
        NSNumber *margin=scale>0&&isfinite(scale)&&zoom>0&&isfinite(zoom)?@((MAX(1,zoom)+1)/scale):nil;
        [captureSites[window]addObject:@{@"screen_rect":p[@"screen_rect"]?:NSNull.null,@"viewport":output[@"screen_bounds"]?:NSNull.null,@"pixel_margin":margin?:NSNull.null}];
    }
    BOOL captureAll=self.compositor.hasFamilyGeometryTransitions;
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary];for(NSDictionary *window in snapshot[@"windows"])if(DWTyped(window[@"source"],NSDictionary.class))bindings[window[@"window"]]=window[@"source"];
    CMTime interval=[self captureInterval];
    NSMutableArray *familyRoots=[NSMutableArray array];NSInteger familyRate=(NSInteger)llround(1/CMTimeGetSeconds(interval));
    for(LiveSource *source in self.sources.allValues){
        if(source.error)[self cancelCapturedInputForWindow:source.logical];
        BOOL wanted=[self.manager capture:source.logical placed:[placed containsObject:source.logical]],running=source.stream!=nil;
        source.replicaWanted=wanted;
        if(!wanted){if(running)[self stopCapture:source];continue;}
        if(self.native&&!source.window&&!source.error&&!source.captureRecovering){source.captureRecovering=YES;source.captureRetryAt=0;}
        // Bound without a shareable window (--only-pid without Screen Recording access): there is nothing to capture, and no
        // failure either, which would detach the window at the next look.
        if(!source.window)continue;
        if(source.error)continue;
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds)||bounds.size.width<=0||bounds.size.height<=0)continue;
        double densityDemand=0;CGSize pixels=[self capturePixels:source native:bounds.size placements:pictures scales:scales demandDensity:&densityDemand];
        CFTimeInterval demandTime=CACurrentMediaTime();
        if(source.captureDemandDensity!=densityDemand){source.captureDemandDensity=densityDemand;source.captureDemandSince=demandTime;}
        NSDictionary *binding=bindings[source.logical];
        if(self.native&&[placed containsObject:source.logical]&&boundIdentity(source.identity,binding[@"identity"])&&binding[@"generation"]){
            double density=running&&source.captureSize.width>0?source.captureSize.width/bounds.size.width:pixels.width/bounds.size.width;
            [familyRoots addObject:@{@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":DWRectJSON(bounds),@"density":@(density),@"capture_sites":[captureSites[source.logical]copy]?:@[],@"capture_all":@(captureAll)}];
        }
        if(!running){[self startCapture:source size:pixels interval:interval];continue;}
        if(source.captureUpdating)continue;
        BOOL samePixels=CGSizeEqualToSize(pixels,source.captureSize),resizeReady=samePixels;
        if(samePixels)source.captureCandidateSince=0;
        else {
            resizeReady=pixels.width>source.captureSize.width||pixels.height>source.captureSize.height||!CGSizeEqualToSize(bounds.size,source.captureNativeSize);
            if(!resizeReady){if(!source.captureCandidateSince||!CGSizeEqualToSize(pixels,source.captureCandidate)){source.captureCandidate=pixels;source.captureCandidateSince=demandTime;}
                resizeReady=demandTime-source.captureCandidateSince>=.5&&demandTime-source.captureDemandSince>=.5;}
        }
        CGSize configured;
        if(DWCaptureConfigurationUpdate(source.captureConfiguration,pixels,interval,resizeReady,&configured))
            [self updateCapture:source size:configured native:bounds.size interval:interval];
    }
    // Overlay roots need geometry observations even outside the current view:
    // a child can extend into a display while its root is offscreen. Only
    // placements request capture; observation alone starts no child stream.
    if(!self.native)for(LiveSource *source in self.sources.allValues){
        NSDictionary *binding=bindings[source.logical];CGRect bounds=CGRectZero;
        if(source.detached||source.error||!source.router.bounds||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]
           ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds)||CGRectIsEmpty(bounds)||CGRectIsInfinite(bounds))continue;
        CGSize pixels=[self capturePixels:source native:bounds.size placements:pictures scales:scales demandDensity:NULL];
        double density=pixels.width/bounds.size.width;
        [familyRoots addObject:@{@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":DWRectJSON(bounds),@"density":@(density),@"capture":@(source.replicaWanted),@"capture_sites":[captureSites[source.logical]copy]?:@[],@"capture_all":@(captureAll)}];
    }
    if(!self.nativeFamilies){__weak Desktop *weak=self;self.nativeFamilies=[[DWNativeReplicaFamilies alloc]initWithChanged:^(NSNumber *window){Desktop *d=weak;if(!d||d.cleaning||d.sessionInactive)return;
        if(!d.native&&d.overlayFamilyDescriptions!=d.nativeFamilies.descriptions){[d render];return;}
        if([d.compositor contentChanged:window])[d startFrames];}];}
    [self.nativeFamilies describe:familyRoots rate:familyRate];
}
// One bounded shareable-content refresh for every due, visible failed source.
// No permission request, stale filter reuse, or window mutation is involved.
// A late answer cannot replace a newer retry, detached binding or reused PID/WID.
- (void)captureRecovery {
    if(self.cleaning||self.sessionInactive||self.native.ended||self.captureRecoveryReading)return;
    CFTimeInterval now=CACurrentMediaTime();NSMutableArray<LiveSource *> *due=[NSMutableArray array];
    for(LiveSource *source in self.sources.allValues)if(source.captureRecovering&&!source.detached&&(!self.native||source.replicaWanted)&&source.captureRetryAt<=now)[due addObject:source];
    if(!due.count)return;
    if(self.manager){
        NSMutableSet *placed=[NSMutableSet set];for(NSDictionary *p in [self presentationSnapshot][@"placements"])if(!self.native||[self.nativeViews replica:p[@"window"] output:p[@"output"]])[placed addObject:p[@"window"]];
        for(LiveSource *source in due.copy)if(![self.manager capture:source.logical placed:[placed containsObject:source.logical]])[due removeObject:source];
    }
    if(!due.count)return;
    if(!CGPreflightScreenCaptureAccess()){
        NSError *error=[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorUserDeclined userInfo:@{NSLocalizedDescriptionKey:@"Screen Recording access is no longer available"}];
        for(LiveSource *source in due)[source captureFailed:error];return;
    }
    self.captureRecoveryReading=YES;NSUInteger generation=++self.captureRecoveryGeneration;NSArray<LiveSource *> *asked=due.copy;__weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||d.cleaning||!d.captureRecoveryReading||d.captureRecoveryGeneration!=generation)return;
        d.captureRecoveryReading=NO;d.captureRecoveryGeneration++;
        NSError *error=[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorFailedToStart userInfo:@{NSLocalizedDescriptionKey:@"Refreshing the capture source timed out"}];
        for(LiveSource *source in asked)if(d.sources[source.logical]==source&&!source.detached&&source.captureRecovering)[source captureFailed:error];
    });
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||d.cleaning||!d.captureRecoveryReading||d.captureRecoveryGeneration!=generation)return;d.captureRecoveryReading=NO;
        NSMutableDictionary<NSNumber *,SCWindow *> *windows=[NSMutableDictionary dictionary];for(SCWindow *window in content.windows)windows[@(window.windowID)]=window;
        for(LiveSource *source in asked){
            if(d.sources[source.logical]!=source||source.detached||!source.captureRecovering||source.stream||d.sessionInactive||d.native.ended||(d.native&&!source.replicaWanted))continue;
            NSDictionary *info=windowInfo(source.router.wid);
            if(sourceGone(source,info)||!DWInScope(d.scope,source.router.pid)){[d track:source info:info];continue;}
            if(error){[source captureFailed:error];continue;}
            SCWindow *window=windows[@(source.router.wid)];
            if(!window||window.owningApplication.processID!=source.router.pid){[source captureFailed:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorNoCaptureSource userInfo:@{NSLocalizedDescriptionKey:@"The capture window is not available yet"}]];continue;}
            source.window=window;CGSize pixels=source.captureSize;
            if(pixels.width<1||pixels.height<1)pixels=source.buffer;
            [d startCapture:source size:pixels interval:[d captureInterval]];
        }
    });}];
}
// Exports draw at canvas scale, independent of zoom. Native one-shot capture sees
// the transformed window's pixel density; request that raster instead of padding
// it to an untransformed size. It cannot recover detail lost at an overview zoom.
// Cold ScreenCaptureKit setup
// can require the main queue: return the IPC handler before waiting for it. The
// request owns its snapshots, leaves live-stream configuration alone, and expires
// after two seconds. Late completions cannot install pixels or answer twice.
- (void)prepareScreenshot:(NSDictionary *)effect completed:(void (^)(NSString *))completed {
    if(!self.manager){completed(nil);return;}
    if(self.exportSources){completed(@"another screenshot is preparing");return;}
    if(!CGPreflightScreenCaptureAccess()){completed(@"Screen Recording access is unavailable; no snapshot requested");return;}
    if(self.native.ended){completed(@"native presentation has ended");return;}
    NSDictionary *alone=DWTyped(DWTyped(effect[@"target"],NSDictionary.class)[@"Window"],NSDictionary.class);NSDictionary *focus=DWTyped([self call:@{@"op":@"snapshot"}][@"focus"],NSDictionary.class);NSNumber *wanted=alone?(DWTyped(alone[@"window"],NSNumber.class)?:DWTyped(focus[@"intent"],NSNumber.class)):nil;
    NSArray *windows=alone?(wanted?@[wanted]:@[]):self.sources.allKeys;self.exportSources=[NSMutableDictionary dictionary];self.exportAttachments=[NSMutableDictionary dictionary];self.exportOrdering=nil;
    DWExportFrame *request=[DWExportFrame new];
    void (^finish)(NSString *)=^(NSString *failure){if(atomic_exchange(&request->completed,YES))return;completed(failure);};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{finish(@"full-resolution snapshot did not arrive within two seconds");});
    // Native presentation has neither an SCWindow nor a capture stream. Enumerate
    // once, then select only the fresh identities already bound by this run.
    if(windows.count){
        NSMutableArray *roots=[NSMutableArray array];NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
        for(NSNumber *logical in windows){LiveSource *source=self.sources[logical];if(!source)continue;NSDictionary *binding=nil;
            for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:logical])binding=DWTyped(window[@"source"],NSDictionary.class);
            if(source.detached||!DWInScope(self.scope,source.router.pid)||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]){finish(@"native screenshot binding expired");return;}
            [roots addObject:@{@"window":logical,@"source":source,@"identity":[source.identity copy],@"generation":binding[@"generation"],@"capture_key":NSUUID.UUID.UUIDString}];}
        NSArray *asked=roots.copy;request->presenter=self.native;request->nativeFamilies=!self.native||self.native.familiesNeeded;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *failure=nil;NSArray *plan=DWNativeExportPlan(asked,request->nativeFamilies,&failure);
            if(!plan){dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&request->completed))finish(failure?:@"native screenshot family is unavailable");});return;}
            if(atomic_load(&request->completed))return;
            dispatch_async(dispatch_get_main_queue(),^{if(atomic_load(&request->completed))return;
                request->nativeItems=plan;[self requestNativeExport:request index:0 attempt:0 completed:finish];});
        });
    }else [self captureExportWindows:windows index:0 content:nil request:request completed:finish];
}
- (void)retryNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt error:(NSError *)error completed:(void (^)(NSString *))completed {
    if(atomic_load(&request->completed))return;
    if(attempt>=2||!DWExportRetryable(error)){completed(error.localizedDescription?:@"native screenshot capture failed");return;}
    // Re-enumeration never changes the audited family plan or its bindings.
    // Each new attempt repeats identity, parent-chain and own-bounds checks.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.08*(1u<<attempt)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(!atomic_load(&request->completed))[self requestNativeExport:request index:index attempt:attempt+1 completed:completed];});
}
- (void)requestNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt completed:(void (^)(NSString *))completed {
    if(atomic_load(&request->completed))return;
    if(self.cleaning||stopped||self.sessionInactive||self.native!=request->presenter||self.native.ended){completed(@"native screenshot cancelled or its session ended");return;}
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{if(atomic_load(&request->completed))return;
            if(error){[self retryNativeExport:request index:index attempt:attempt error:error completed:completed];return;}
            if(!content){completed(@"native screenshot supplied no window list");return;}
            [self captureNativeExport:request index:index attempt:attempt content:content completed:completed];});
    }];
}
- (void)captureNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt content:(SCShareableContent *)content completed:(void (^)(NSString *))completed {
    if(atomic_load(&request->completed))return;
    if(self.cleaning||stopped||self.sessionInactive||self.native!=request->presenter||self.native.ended){completed(@"native screenshot cancelled or its session ended");return;}
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    for(NSDictionary *item in request->nativeItems){LiveSource *source=item[@"source"];NSDictionary *binding=nil;
        for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:item[@"window"]])binding=DWTyped(window[@"source"],NSDictionary.class);
        if(self.sources[item[@"window"]]!=source||source.detached||!DWInScope(self.scope,source.router.pid)||!boundIdentity(source.identity,item[@"identity"])
            ||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"generation"]isEqual:item[@"generation"]]){completed(@"native screenshot binding changed during capture");return;}}
    if(index>=request->nativeItems.count){
        // Re-read the complete family before composition. A new/removed child,
        // changed bounds or changed child order cannot silently produce a partial
        // family from captures made earlier in this request.
        NSMutableArray *roots=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
        for(NSDictionary *item in request->nativeItems)if(![seen containsObject:item[@"window"]]){
            [seen addObject:item[@"window"]];[roots addObject:@{@"window":item[@"window"],@"source":item[@"source"],@"identity":item[@"identity"],@"generation":item[@"generation"],@"capture_key":item[@"capture_key"]}];}
        NSArray *asked=roots.copy;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *failure=nil;NSArray *fresh=DWNativeExportPlan(asked,request->nativeFamilies,&failure);BOOL same=[fresh isEqual:request->nativeItems];
            dispatch_async(dispatch_get_main_queue(),^{if(atomic_load(&request->completed))return;
                if(self.cleaning||stopped||self.sessionInactive||self.native!=request->presenter||self.native.ended){completed(@"native screenshot cancelled or its session ended");return;}
                NSDictionary *current=[self call:@{@"op":@"snapshot"}];NSMutableDictionary *bindings=[NSMutableDictionary dictionary];for(NSDictionary *window in current[@"windows"])if(DWTyped(window[@"source"],NSDictionary.class))bindings[window[@"window"]]=window[@"source"];
                for(NSDictionary *item in request->nativeItems){NSDictionary *binding=bindings[item[@"window"]];LiveSource *source=item[@"source"];
                    if(self.sources[item[@"window"]]!=source||source.detached||!DWInScope(self.scope,source.router.pid)||!boundIdentity(source.identity,item[@"identity"])||!boundIdentity(item[@"identity"],binding[@"identity"])||![item[@"generation"]isEqual:binding[@"generation"]]){completed(@"native screenshot source changed before composition");return;}}
                if(same)self.exportOrdering=DWExportOrderCohort(request->nativeItems);
                completed(same?nil:failure?:@"native screenshot family changed before composition");
            });
        });return;
    }
    NSDictionary *item=request->nativeItems[index],*identity=item[@"member"];LiveSource *source=item[@"source"];NSNumber *logical=item[@"window"];
    SCWindow *capturable=nil;
    for(SCWindow *candidate in content.windows)if(candidate.windowID==[identity[@"wid"]unsignedIntValue]&&candidate.owningApplication.processID==[identity[@"pid"]intValue]){capturable=candidate;break;}
    if(!capturable){
        NSError *missing=[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorNoCaptureSource userInfo:@{NSLocalizedDescriptionKey:@"native family member is unavailable for screenshot capture"}];
        [self retryNativeExport:request index:index attempt:attempt error:missing completed:completed];return;
    }
    CGRect bounds=DWRectFromJSON(item[@"native_bounds"]);SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:capturable];
    CGRect area=filter.contentRect;double density=filter.pointPixelScale;
    if(!(isfinite(area.size.width)&&isfinite(area.size.height)&&area.size.width>0&&area.size.height>0&&isfinite(density)&&density>0)){completed(@"native screenshot has no capturable pixel area");return;}
    CGSize available=CGSizeMake(ceil(area.size.width*density),ceil(area.size.height*density));
    double shrink=fmin(1,fmin(ceil(bounds.size.width*2)/available.width,ceil(bounds.size.height*2)/available.height));
    CGSize pixels=CGSizeMake(MAX(1,floor(available.width*shrink)),MAX(1,floor(available.height*shrink)));
    if(pixels.width>16384||pixels.height>16384){completed(@"window snapshot exceeds the 16384px per-side limit");return;}
    SCScreenshotConfiguration *config=[SCScreenshotConfiguration new];config.width=(NSInteger)pixels.width;config.height=(NSInteger)pixels.height;config.destinationRect=CGRectMake(0,0,pixels.width,pixels.height);config.showsCursor=NO;config.ignoreShadows=YES;config.ignoreClipping=YES;config.includeChildWindows=NO;config.dynamicRange=SCScreenshotDynamicRangeSDR;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        if(atomic_load(&request->completed))return;
        if(!DWNativeExportCurrent(item,request->nativeFamilies)){dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&request->completed))completed(@"native family member changed before screenshot capture");});return;}
        [SCScreenshotManager captureScreenshotWithFilter:filter configuration:config completionHandler:^(SCScreenshotOutput *output,NSError *error){
            if(atomic_load(&request->completed))return;
            DWExportFrame *result=[DWExportFrame new];result->failure=error.localizedDescription;
            if(!result->failure&&!DWNativeExportCurrent(item,request->nativeFamilies))result->failure=@"native family member changed identity, ancestry or own bounds during capture";
            if(!result->failure)result->pixels=DWExportPixels(output.sdrImage);
            if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"export: native window=%s member=%s requested=%.0fx%.0f image=%zux%zu\n",logical.stringValue.UTF8String,[identity[@"wid"]stringValue].UTF8String,pixels.width,pixels.height,output.sdrImage?CGImageGetWidth(output.sdrImage):0,output.sdrImage?CGImageGetHeight(output.sdrImage):0);
            dispatch_async(dispatch_get_main_queue(),^{
                if(atomic_load(&request->completed))return;
                if(self.cleaning||stopped||source.detached||self.sources[logical]!=source||self.native!=request->presenter||self.native.ended){completed(@"native screenshot source or session ended during capture");return;}
                if(error){[self retryNativeExport:request index:index attempt:attempt error:error completed:completed];return;}
                if(result->failure){completed(result->failure);return;}
                if(!result->pixels||CVPixelBufferGetWidth(result->pixels)<pixels.width||CVPixelBufferGetHeight(result->pixels)<pixels.height){completed(@"native snapshot supplied fewer pixels than requested");return;}
                if([identity[@"wid"]isEqual:item[@"identity"][@"wid"]]){
                    LiveSource *export=[LiveSource new];export.logical=logical;export.frames=source.frames;[export installPixels:result->pixels];self.exportSources[logical]=export;
                }else{DWCanvasAttachment *image=[DWCanvasAttachment new];image.key=item[@"capture_member_key"];image.buffer=result->pixels;image.unitRect=DWRectFromJSON(item[@"unit_rect"]);
                    NSMutableArray *family=self.exportAttachments[logical];if(!family){family=[NSMutableArray array];self.exportAttachments[logical]=family;}[family addObject:image];}
                [self captureNativeExport:request index:index+1 attempt:0 content:content completed:completed];
            });
        }];
    });
}
- (void)captureExportWindows:(NSArray<NSNumber *> *)windows index:(NSUInteger)index content:(SCShareableContent *)content request:(DWExportFrame *)request completed:(void (^)(NSString *))completed {
    (void)content; // Native exports use the separately audited family plan above.
    if(atomic_load(&request->completed))return;
    if(self.cleaning||stopped){completed(@"screenshot cancelled during shutdown");return;}
    while(index<windows.count){
        NSNumber *window=windows[index++];LiveSource *source=self.sources[window];if(!source||source.error||!source.window)continue;
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds))continue;
        CGSize pixels=CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2));
        if(source.pixels&&source.buffer.width>=pixels.width&&source.buffer.height>=pixels.height)continue;
        if(pixels.width>16384||pixels.height>16384){completed(@"window snapshot exceeds the 16384px per-side limit");return;}
        SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:source.window];
        SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;compositedStream(config);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            [SCScreenshotManager captureSampleBufferWithFilter:filter configuration:config completionHandler:^(CMSampleBufferRef sample,NSError *error){
                if(atomic_load(&request->completed))return;
                DWExportFrame *result=[DWExportFrame new];if(sample)result->sample=(CMSampleBufferRef)CFRetain(sample);result->failure=error.localizedDescription;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(atomic_load(&request->completed))return;
                    if(source.detached||self.cleaning||stopped){completed(@"window closed or screenshot cancelled during capture");return;}
                    if(result->failure){completed(result->failure);return;}
                    CVPixelBufferRef image=result->sample&&CMSampleBufferIsValid(result->sample)?CMSampleBufferGetImageBuffer(result->sample):NULL;
                    if(!image){completed(@"snapshot supplied no valid pixels");return;}
                    if(CVPixelBufferGetWidth(image)<pixels.width||CVPixelBufferGetHeight(image)<pixels.height){completed(@"snapshot supplied fewer pixels than requested");return;}
                    LiveSource *export=[LiveSource new];export.logical=window;export.frames=source.frames;[export installPixels:image];self.exportSources[window]=export;
                    [self captureExportWindows:windows index:index content:nil request:request completed:completed];
                });
            }];
        });return;
    }
    completed(nil);
}
@end
