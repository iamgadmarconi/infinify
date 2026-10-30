// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/canvas-renderer.m at 37b27b1, moved verbatim.
// Adapted from DriftWM, https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/ipc/mod.rs (cmd_screenshot,
// resolve_screenshot_region, window_visual_rect, snap_rect_to_rect, union_rect:
// what each screenshot target captures),
// src/render/screenshot.rs (capture_region_to_png: the scale rule, the 16384 px
// limit and their refusals), src/state/mod.rs (output_viewport_rect),
// src/canvas.rs (rule_to_internal), src/render/capture_background.rs (wallpaper_dest
// and the Wallpaper arm of tile_elements: where a capture shows a wallpaper) and
// src/render/mod.rs (compose_capture_elements: the opacity of a window captured
// alone; what a canvas capture leaves out: a screen-pinned window is never in one,
// a widget is drawn below the other windows). The frame description is the host
// protocol of the compositor (IFCompositor.h): canvas-space elements bottom to
// top from the controller's placements, a widget in the widget layer and a
// screen-pinned window in the pinned layer and the pinned space (upstream
// compose_frame's zoomed_widgets and zoomed_pinned buckets, and
// window_render_transform in src/state/output.rs: a pin's output-relative point at
// zoom 1), DrawnChrome's coverage rule per output, upstream's stand-in body
// rectangle and its projection of the other outputs' viewports. The effects are the
// compositor's (docs/native/app/Canvas/COMPOSITOR-NOTES.md, section 18), with src/state/errors.rs (ErrorSource:
// the order of the error bar's messages) and src/state/window_animation_driver.rs
// (start_window_open_animation, snapshot_closing_window, flatten_scale_for_canvas_rect:
// an event on no output animates nothing, and the density a closing window is baked
// at). The background's chunk caches (a baked cache_shader, a pyramidal TIFF's chunks)
// are the background module's (docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17); from here come
// upstream's one cache per output and its shrink while a fullscreen window conceals the
// canvas (src/render/mod.rs, the bg_elements of compose_frame), the frames that keep
// coming while a cache fills (has_pending_bakes and has_pending_loads, as
// src/backend/udev.rs asks them) and what a capture draws instead of a cache
// (src/render/capture_background.rs, CaptureBackground::prepare).
// New code over the controller's snapshot; cameras, world rectangles and pinned
// screen rectangles are the controller's, and no native window geometry is read.
#import "DWCanvasRenderer+Private.h"
#import "DWTypedValue.h"
#import <ImageIO/ImageIO.h>

// Upstream output_viewport_rect: size / zoom canvas units from the rounded camera. CGRectNull without an output.
static CGRect viewportOf(NSDictionary *o) {
    CGRect bounds=rectOf(o[@"screen_bounds"]);if(!o||CGRectIsNull(bounds))return CGRectNull;
    CGPoint camera=pointOf(o[@"camera"]);double zoom=[DWTyped(o[@"zoom"],NSNumber.class)doubleValue];if(!(isfinite(zoom)&&zoom>0))zoom=1;
    return CGRectMake(round(camera.x),round(camera.y),round(round(bounds.size.width)/zoom),round(round(bounds.size.height)/zoom));
}
static NSDictionary *refusal(NSString *message) { return @{@"error":message}; }
@implementation DWCanvasRenderer (Screenshot)
// What a capture frames for one element, bounds rounded outward. A live window:
// upstream's window_visual_rect, its content with a server title bar above and the
// border and the shadow radius all round. A stand-in: its visual frame, bar and body
// with the border, as snap_rect_to_rect rounds it.
- (CGRect)visual:(IFCompositorElement *)element {
    IFCompositorDecoration d=element.decoration;CGRect r=element.rect;BOOL bare=d.mode==IFCompositorDecorationModeNone,standin=element.kind==IFCompositorElementKindStandIn;
    double edge=bare?0:MAX(d.borderWidth,0),bar=standin||d.mode==IFCompositorDecorationModeServer?self.chrome.titleBarHeight:0;
    if(!standin&&!bare&&d.shadow)edge+=ceil(d.shadowRadius);
    double x=floor(r.origin.x-edge),y=floor(r.origin.y-bar-edge);
    return CGRectMake(x,y,MAX(ceil(CGRectGetMaxX(r)+edge)-x,1),MAX(ceil(CGRectGetMaxY(r)+edge)-y,1));
}
// Upstream resolve_screenshot_region, for an effect that names its target only. The
// controller's own `region`, when the effect carries one, is used instead: it knows
// zoom.fit_padding and the decoration of windows that are on no output.
- (CGRect)region:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot elements:(NSArray<IFCompositorElement *> *)elements isolate:(IFCompositorElement *)isolate refusal:(NSString *__autoreleasing *)refused {
    NSArray<NSDictionary *> *outputs=list(snapshot[@"outputs"]);NSDictionary *active=nil;id target=effect[@"target"];NSDictionary *r=DWTyped(DWTyped(target,NSDictionary.class)[@"Region"],NSDictionary.class);
    for(NSDictionary *o in outputs)if(DWTyped(effect[@"output"],NSNumber.class)&&[o[@"id"]isEqual:effect[@"output"]])active=o;
    if(isolate)return [self visual:isolate];
    if([target isEqual:@"Viewport"]){
        if(!active){*refused=@"no active output to capture";return CGRectNull;}
        return viewportOf(active);
    }
    if([target isEqual:@"All"]){
        // The union of every canvas window and stand-in, framed by zoom.fit_padding canvas units (upstream's default
        // without one). `elements` holds no pinned window; a widget is drawn and not framed, as upstream's is_canvas_window says.
        CGRect all=CGRectNull;for(IFCompositorElement *element in elements)if(element.layer!=IFCompositorStackLayerWidget)all=CGRectUnion(all,[self visual:element]);
        if(CGRectIsNull(all)){*refused=@"no windows to capture";return CGRectNull;}
        double pad=round(fmax(DWTyped(effect[@"fit_padding"],NSNumber.class)?[effect[@"fit_padding"]doubleValue]:80,0));return CGRectInset(all,-pad,-pad);
    }
    if(!r){*refused=@"unknown screenshot target";return CGRectNull;}
    long x=[DWTyped(r[@"x"],NSNumber.class)longValue],y=[DWTyped(r[@"y"],NSNumber.class)longValue],w=[DWTyped(r[@"w"],NSNumber.class)longValue],h=[DWTyped(r[@"h"],NSNumber.class)longValue];
    if(w<=0||h<=0){*refused=@"region width and height must be positive";return CGRectNull;}
    // rule_to_internal: the rectangle is centred on a Y-up canvas point.
    if(![DWTyped(r[@"from_screen"],NSNumber.class)boolValue])return CGRectMake(x-w/2,-y-h/2,w,h);
    // Screen points, mapped through the output they lie on, else the active one.
    NSDictionary *output=nil;for(NSDictionary *o in outputs)if(!output&&CGRectContainsPoint(rectOf(o[@"screen_bounds"]),CGPointMake(x,y)))output=o;
    if(!output)output=active;if(!output){*refused=@"no output for the screen region";return CGRectNull;}
    CGPoint camera=pointOf(output[@"camera"]),corner=rectOf(output[@"screen_bounds"]).origin;double zoom=[DWTyped(output[@"zoom"],NSNumber.class)doubleValue];if(!(isfinite(zoom)&&zoom>0))zoom=1;
    return CGRectMake(round(camera.x+(x-corner.x)/zoom),round(camera.y+(y-corner.y)/zoom),round(w/zoom),round(h/zoom));
}
- (NSDictionary *)screenshotPixels:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    NSString *path=DWTyped(effect[@"path"],NSString.class),*refused=nil;double scale=DWTyped(effect[@"scale"],NSNumber.class)?[effect[@"scale"]doubleValue]:NAN;
    if(!path.isAbsolutePath)return refusal(@"screenshot path must be absolute");
    if(!snapshot)return refusal(@"no renderer available for capture");
    if(!currentOutputPlacements(snapshot[@"placements"]))return refusal(@"snapshot placements do not match the current schema");
    [self configure:snapshot];
    // A window target is composed alone on transparency, its shadow included. The controller resolved the selector.
    id target=effect[@"target"];IFCompositorElement *isolate=nil;NSDictionary *alone=DWTyped(DWTyped(target,NSDictionary.class)[@"Window"],NSDictionary.class);
    NSNumber *wanted=alone?DWTyped(alone[@"window"],NSNumber.class)?:DWTyped(DWTyped(snapshot[@"focus"],NSDictionary.class)[@"intent"],NSNumber.class):nil;
    // Every world window bottom to top at its canvas rectangle, described by its placement on any
    // output; one that is on no output is described by its entry of the window list. Upstream
    // compose_capture_elements: a canvas capture never includes a screen-pinned window
    // (window_render_transform gives it no place without an output), and draws the widgets below the
    // other windows; only a window captured alone is drawn whatever it is, at its stage position,
    // which for a pinned window is the canvas frame its pin shows.
    NSMutableDictionary<NSNumber *,NSDictionary *> *placed=[NSMutableDictionary dictionary];
    for(id entry in list(snapshot[@"placements"])){
        NSDictionary *p=DWTyped(entry,NSDictionary.class);NSNumber *window=DWTyped(p[@"window"],NSNumber.class);
        if(currentOutputPlacement(p)&&(!placed[window]||[p[@"output"]isEqual:effect[@"output"]]))placed[window]=p;
    }
    NSMutableArray<IFCompositorElement *> *elements=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,NSArray<IFCompositorElement *> *> *attachments=[NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *exportTokens=self.exportOrder?[NSMutableArray array]:nil;
    NSMutableDictionary<NSDictionary *,IFCompositorElement *> *exportElements=self.exportOrder?[NSMutableDictionary dictionary]:nil;
    for(id entry in list(snapshot[@"windows"])){
        NSDictionary *w=DWTyped(entry,NSDictionary.class);if(!w)return refusal(@"snapshot window entries must be objects");
        NSNumber *window=DWTyped(w[@"window"],NSNumber.class);CGRect world=rectOf(w[@"world_rect"]);NSDictionary *p=placed[window],*source=DWTyped(w[@"source"],NSDictionary.class),*metadata=DWTyped(w[@"metadata"],NSDictionary.class);
        // Upstream's windows are at least one pixel in each direction.
        if(!window||CGRectIsNull(world)||world.size.width<=0||world.size.height<=0)continue;
        // An isolated export has exactly this family's token set. Other roots
        // neither constrain its order nor borrow pixels into this composition.
        if(alone&&![window isEqual:wanted])continue;
        if(pinnedOf(w)&&![window isEqual:wanted])continue;
        if(!p){NSMutableDictionary *described=[w mutableCopy];BOOL settled=source&&[DWTyped(source[@"observation_known"],NSNumber.class)boolValue];
            described[@"presentation_settled"]=settled?@YES:@NO;if(!described[@"title"])described[@"title"]=DWTyped(metadata[@"title"],NSString.class)?:@"";if(!described[@"app_name"])described[@"app_name"]=DWTyped(metadata[@"bundle_id"],NSString.class)?:@"";p=described;}
        if(!currentDrawnPlacement(p))return refusal(@"snapshot window entries do not match the current schema");
        // Native presentation omits live pictures from the on-screen canvas, but
        // an export supplies separate one-shot pixels through the source provider.
        IFCompositorElement *element=[IFCompositorElement new];if(![self fill:element window:window placement:p rect:world onScreen:NO])return refusal(@"snapshot window entries do not match the current schema");[elements addObject:element];
        if(exportTokens){BOOL barrier=element.kind==IFCompositorElementKindStandIn||!self.exportOrderRoot||!self.exportOrderRoot(window);
            NSDictionary *token=barrier?@{@"window":window,@"bucket":@(element.layer),@"barrier":@YES}:@{@"window":window,@"bucket":@(element.layer)};
            [exportTokens addObject:token];exportElements[token]=element;}
        // A one-shot family is authoritative when provided. Otherwise a live
        // family's matching output may supply pixels when no one-shot ordering
        // contract is installed. Never borrow live observations into an ordered
        // one-shot export, or another output's geometry/capture generation.
        NSArray<DWCanvasAttachment *> *familyImages=element.kind==IFCompositorElementKindWindow?(self.exportAttachments?self.exportAttachments(window):!self.exportOrder&&self.liveAttachments&&DWTyped(p[@"output"],NSNumber.class)?self.liveAttachments(window,p[@"output"]):nil):nil;
        if(familyImages.count){NSMutableArray *family=[NSMutableArray array];NSMutableSet<NSString *> *keys=exportTokens?[NSMutableSet set]:nil;
            for(DWCanvasAttachment *image in familyImages){
                if(!validAttachment(image))return refusal(@"capture attachment has no valid image geometry or source-pixel crop");
                if(exportTokens){if(!image.key.length||[keys containsObject:image.key])return refusal(@"capture attachment has no unique opaque ordering key");[keys addObject:image.key];}
                CGRect r=image.unitRect;
                IFCompositorElement *child=[IFCompositorElement new];child.identifier=[self mark];child.kind=IFCompositorElementKindWindow;child.space=IFCompositorSpaceCanvas;child.layer=element.layer;
                child.rect=CGRectMake(world.origin.x+r.origin.x*world.size.width,world.origin.y+r.origin.y*world.size.height,r.size.width*world.size.width,r.size.height*world.size.height);
                IFCompositorDecoration d=IFCompositorDecorationDefault();d.mode=IFCompositorDecorationModeNone;d.borderWidth=0;d.cornerRadius=0;d.shadow=NO;d.opacity=element.decoration.opacity;child.decoration=d;
                child.pixelBuffer=image.buffer;child.contentRect=image.contentRect;child.contentGeneration=image.generation;[family addObject:child];[elements addObject:child];
                if(exportTokens){NSDictionary *token=@{@"window":window,@"key":image.key,@"bucket":@(child.layer)};[exportTokens addObject:token];exportElements[token]=child;}
            }
            if(family.count)attachments[window]=family.copy;
        }
    }
    if(exportTokens){
        // Capture composition has no pinned or closing bucket. Use the same
        // order the compositor actually draws, before region culling can hide
        // a root needed to validate its complete captured family membership.
        NSMutableArray<NSDictionary *> *base=[NSMutableArray array];
        for(NSNumber *bucket in @[@(IFCompositorStackLayerWidget),@(IFCompositorStackLayerNormal)])for(NSDictionary *token in exportTokens)if([token[@"bucket"]isEqual:bucket])[base addObject:token];
        NSArray *order=DWCanvasValidatedOrder(self.exportOrder(base.copy,effect,snapshot),base.copy);
        NSMutableArray<IFCompositorElement *> *ordered=[NSMutableArray arrayWithCapacity:elements.count];for(NSDictionary *token in order)if(exportElements[token])[ordered addObject:exportElements[token]];
        if(ordered.count!=elements.count)return refusal(@"capture ordering does not describe every exported image");
        elements=ordered;
    }
    if(alone){
        NSNumber *window=wanted;
        for(IFCompositorElement *element in elements)if(window&&element.identifier==window.unsignedLongLongValue)isolate=element;
        if(!isolate)return refusal(window?@"window has no capturable area":@"no window matching selector");
        // Upstream compose_capture_elements: a window captured alone is drawn as itself, at its rule's
        // opacity or 1, not at the opacity its focus gives it on screen. The controller resolved which.
        NSNumber *opacity=DWTyped(DWTyped(DWTyped(target,NSDictionary.class)[@"Window"],NSDictionary.class)[@"opacity"],NSNumber.class);if(opacity){IFCompositorDecoration d=isolate.decoration;d.opacity=opacity.doubleValue;isolate.decoration=d;
            for(IFCompositorElement *child in attachments[window]){IFCompositorDecoration d=child.decoration;d.opacity=opacity.doubleValue;child.decoration=d;}}
    }
    CGRect region=rectOf(effect[@"region"]);if(CGRectIsNull(region))region=[self region:effect snapshot:snapshot elements:elements isolate:isolate refusal:&refused];
    if(refused)return refusal(refused);
    // A Window effect's controller-supplied region describes the root's chrome;
    // attached popups and sheets can lie outside it. Include the complete family
    // for that target. Viewport and Region targets keep their requested clipping.
    if(isolate)for(IFCompositorElement *child in attachments[wanted])region=CGRectUnion(region,[self visual:child]);
    IFCompositorRenderer *renderer=[IFCompositorRenderer rendererWithDevice:nil];if(!renderer)return refusal(@"no renderer available for capture");
    // capture_region_to_png: `scale` pixels per canvas unit, whatever any output's zoom is.
    if(!(isfinite(scale)&&scale>0))return refusal(@"scale must be a positive number");
    if(!(region.size.width>0&&region.size.height>0))return refusal(@"capture region is empty");
    double width=fmin(round(region.size.width*scale),INT32_MAX),height=fmin(round(region.size.height*scale),INT32_MAX);
    if(width<=0||height<=0)return refusal(@"capture resolves to zero pixels");
    if(width>16384||height>16384)return refusal([NSString stringWithFormat:@"capture %.0fx%.0fpx exceeds the 16384px per-side limit — lower --scale or shrink the region",width,height]);
    // Upstream capture_background.rs (wallpaper_dest and the Wallpaper arm of tile_elements): a wallpaper is
    // fixed to the screen, so a capture shows it over the canvas footprint of the output the region's centre
    // lies on, else of the active output. The region crops it and the rest stays transparent; with no such
    // output there is no background.
    CGPoint backgroundCentre=CGPointMake(region.origin.x+trunc(region.size.width/2),region.origin.y+trunc(region.size.height/2));NSDictionary *backgroundOutput=nil,*activeBackgroundOutput=nil;
    for(NSDictionary *output in list(snapshot[@"outputs"])){if(!backgroundOutput&&CGRectContainsPoint(viewportOf(output),backgroundCentre))backgroundOutput=output;if([output[@"id"]isEqual:effect[@"output"]])activeBackgroundOutput=output;}
    backgroundOutput=backgroundOutput?:activeBackgroundOutput;
    IFBackgroundProgram *backgroundProgram=!isolate&&self.backgroundForOutput&&backgroundOutput?self.backgroundForOutput(DWTyped(backgroundOutput[@"id"],NSNumber.class),backgroundOutput,self.program):nil;backgroundProgram=backgroundProgram?:self.program;
    BOOL wallpaper=!isolate&&backgroundProgram.kind==IFBackgroundKindWallpaper;CGRect dest=CGRectNull;
    if(wallpaper){
        dest=viewportOf(backgroundOutput);
        // The upstream fixed cover-fit image can use the bare viewport's one
        // pass. Mac sizing/parallax still needs its real output sampling pose.
        if(CGRectEqualToRect(dest,region)&&!backgroundProgram.config.parallax&&!backgroundProgram.config.inheritedWallpaper)wallpaper=NO;
    }
    // Upstream's capture: zoom 1, a transparent target, no outlines, and the background
    // under every scene but not under a window captured alone. A capture draws no chunk
    // cache: a baked shader is rendered live and a pyramidal TIFF from one level of at
    // most 4096 pixels, whatever the outputs have loaded (the module's captureProgram).
    IFCompositorFrame *frame=[IFCompositorFrame new];
    frame.size=region.size;frame.scale=scale;frame.cameraX=region.origin.x;frame.cameraY=region.origin.y;frame.zoom=1;frame.time=DWCanvasRendererTime();frame.clear=IFCompositorClearTransparent;
    frame.chrome=self.chrome;frame.placeholderColor=self.chrome.backgroundColor;frame.background=isolate||wallpaper?nil:backgroundProgram.captureProgram;
    for(IFCompositorElement *element in elements){
        // Nothing of an element farther away than its bar, border and shadow reaches the region.
        double reach=ceil(element.decoration.shadowRadius)+1;
        if(isolate?element==isolate||[attachments[wanted]containsObject:element]:CGRectIntersectsRect(CGRectInset([self visual:element],-reach,-reach),region))[frame.elements addObject:element];
    }
    NSError *error=nil;CGImageRef image=[renderer newImageForFrame:frame error:&error];if(!image)return refusal(error.localizedDescription?:@"the render did not complete");
    if(wallpaper&&!CGRectIsEmpty(CGRectIntersection(dest,region))){
        // The picture that output shows, drawn by the same module at the capture's density (one texture at
        // most), laid under the scene at whole pixels. Core Graphics counts rows from the bottom.
        IFCompositorFrame *under=[IFCompositorFrame new];size_t wide=CGImageGetWidth(image),high=CGImageGetHeight(image);
        CGRect paperBounds=rectOf(backgroundOutput[@"screen_bounds"]);CGPoint paperCamera=pointOf(backgroundOutput[@"camera"]);double paperZoom=[DWTyped(backgroundOutput[@"zoom"],NSNumber.class)doubleValue];
        under.size=paperBounds.size;under.scale=fmin(scale/paperZoom,16384/fmax(paperBounds.size.width,paperBounds.size.height));under.cameraX=paperCamera.x;under.cameraY=paperCamera.y;under.zoom=paperZoom;under.time=frame.time;under.clear=IFCompositorClearTransparent;under.background=backgroundProgram;
        CGImageRef paper=[renderer newImageForFrame:under error:&error];CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=paper?CGBitmapContextCreate(NULL,wide,high,8,0,srgb,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little):NULL;CGColorSpaceRelease(srgb);
        if(!context){CGImageRelease(paper);CGImageRelease(image);return refusal(error.localizedDescription?:@"the render did not complete");}
        double x0=round((CGRectGetMinX(dest)-region.origin.x)*scale),x1=round((CGRectGetMaxX(dest)-region.origin.x)*scale),y0=round((CGRectGetMinY(dest)-region.origin.y)*scale),y1=round((CGRectGetMaxY(dest)-region.origin.y)*scale);
        CGContextDrawImage(context,CGRectMake(x0,high-y1,x1-x0,y1-y0),paper);CGContextDrawImage(context,CGRectMake(0,0,wide,high),image);
        CGImageRelease(paper);CGImageRelease(image);image=CGBitmapContextCreateImage(context);CGContextRelease(context);
        if(!image)return refusal(@"the render did not complete");
    }
    long pixelsWide=(long)CGImageGetWidth(image),pixelsHigh=(long)CGImageGetHeight(image);
    return @{@"image":CFBridgingRelease(image),@"path":path,@"width":@(pixelsWide),@"height":@(pixelsHigh)};
}
@end
