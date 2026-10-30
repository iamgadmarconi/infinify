// SPDX-License-Identifier: GPL-3.0-or-later
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
// compositor's (COMPOSITOR-NOTES.md, section 18), with src/state/errors.rs (ErrorSource:
// the order of the error bar's messages) and src/state/window_animation_driver.rs
// (start_window_open_animation, snapshot_closing_window, flatten_scale_for_canvas_rect:
// an event on no output animates nothing, and the density a closing window is baked
// at). The background's chunk caches (a baked cache_shader, a pyramidal TIFF's chunks)
// are the background module's (BACKGROUND-NOTES.md, section 17); from here come
// upstream's one cache per output and its shrink while a fullscreen window conceals the
// canvas (src/render/mod.rs, the bg_elements of compose_frame), the frames that keep
// coming while a cache fills (has_pending_bakes and has_pending_loads, as
// src/backend/udev.rs asks them) and what a capture draws instead of a cache
// (src/render/capture_background.rs, CaptureBackground::prepare).
// New code over the controller's snapshot; cameras, world rectangles and pinned
// screen rectangles are the controller's, and no native window geometry is read.
#import "DWCanvasRenderer+Private.h"
#import "DWTypedValue.h"
#import "DWGeometryJSON.h"

@implementation DWCanvasRenderer (Lifecycle)
// Flatten the family once, retaining immutable textures rather than capture
// buffers after it closes. First use the compositor's exact chrome bake for the
// root and every child, then compose their currently applied relative order at
// zoom 1. Flattening a family cannot preserve interleaving with another family.
// The temporary renderer has its own caches and the output's device/queue; it
// cannot evict the output's live-window caches or require a main-thread GPU wait.
- (IFCompositorElement *)closingFamily:(NSNumber *)window state:(DWCanvasOutput *)state flattenScale:(double)flattenScale {
    IFCompositorElement *root=state.elements[window];DWCanvasFamily *family=state.attachments[window];IFCompositorRenderer *output=state.layer.renderer;
    if(!family.ordered.count)return [output closingSnapshotOfElement:root inFrame:state.frame flattenScale:flattenScale];
    if(!state.attachmentRenderer)state.attachmentRenderer=[IFCompositorRenderer rendererWithDevice:output.device];
    IFCompositorRenderer *renderer=state.attachmentRenderer;if(!renderer||renderer.commandQueue!=output.commandQueue)return nil;
    double scale=isfinite(flattenScale)&&flattenScale>1?flattenScale:1,zoom=isfinite(state.frame.zoom)&&state.frame.zoom>0?state.frame.zoom:1;
    double unit=root.space==IFCompositorSpaceOutput?zoom:1;
    NSMutableArray<IFCompositorElement *> *baked=[NSMutableArray array];CGRect bounds=CGRectNull;CGPoint centre=CGPointZero;
    NSMutableSet<IFCompositorElement *> *members=[NSMutableSet setWithObject:root];for(DWCanvasChild *child in family.ordered)[members addObject:child.element];
    NSMutableArray<IFCompositorElement *> *images=[NSMutableArray array];for(IFCompositorElement *element in state.frame.elements)if([members containsObject:element])[images addObject:element];
    if(images.count!=members.count)return nil;
    for(IFCompositorElement *image in images){
        IFCompositorElement *picture=[renderer closingSnapshotOfElement:image inFrame:state.frame flattenScale:scale];
        if(!picture){[renderer purge];return nil;}
        CGRect rect=picture.rect;rect=CGRectMake(rect.origin.x/unit,rect.origin.y/unit,rect.size.width/unit,rect.size.height/unit);
        if(!DWFiniteRect(rect)){[renderer purge];return nil;}
        picture.rect=rect;picture.space=IFCompositorSpaceCanvas;picture.hasClipRect=NO;picture.lifecycle=IFCompositorLifecycleClosingAlphaOnly;picture.lifecycleStartTime=NAN;picture.lifecycleProgress=0;picture.contentGeneration=image.contentGeneration;
        if(image==root)centre=CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect));bounds=CGRectUnion(bounds,rect);[baked addObject:picture];
    }
    // Keep upstream's root closing pivot even when a popup extends far beyond
    // one side. Transparent padding on the opposite side keeps the family from
    // shifting as its one texture shrinks; it is never clipped to the root.
    double halfWidth=fmax(centre.x-CGRectGetMinX(bounds),CGRectGetMaxX(bounds)-centre.x),halfHeight=fmax(centre.y-CGRectGetMinY(bounds),CGRectGetMaxY(bounds)-centre.y);
    double width=ceil(2*halfWidth*scale),height=ceil(2*halfHeight*scale);
    if(!isfinite(width)||!isfinite(height)||width<=0||height<=0||width>16384||height>16384){[renderer purge];return nil;}
    bounds=CGRectMake(centre.x-width/scale/2,centre.y-height/scale/2,width/scale,height/scale);
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)width height:(NSUInteger)height mipmapped:NO];
    descriptor.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;descriptor.storageMode=MTLStorageModePrivate;
    id<MTLTexture> texture=[renderer.device newTextureWithDescriptor:descriptor];id<MTLCommandBuffer> command=[renderer.commandQueue commandBuffer];
    if(!texture||!command){[renderer purge];return nil;}
    IFCompositorFrame *frame=[IFCompositorFrame new];frame.size=bounds.size;frame.scale=scale;frame.cameraX=bounds.origin.x;frame.cameraY=bounds.origin.y;frame.zoom=1;frame.clear=IFCompositorClearTransparent;
    frame.chrome=state.frame.chrome;frame.decorationScale=state.frame.decorationScale;frame.effects=state.frame.effects;frame.time=state.frame.time;[frame.elements addObjectsFromArray:baked];
    BOOL encoded=[renderer encodeFrame:frame intoTexture:texture commandBuffer:command];[command commit];[renderer purge];if(!encoded)return nil;
    IFCompositorElement *snapshot=[IFCompositorElement new];snapshot.identifier=root.identifier;snapshot.kind=IFCompositorElementKindSnapshot;snapshot.space=root.space;snapshot.layer=IFCompositorStackLayerClosing;
    snapshot.rect=CGRectMake(bounds.origin.x*unit,bounds.origin.y*unit,bounds.size.width*unit,bounds.size.height*unit);snapshot.hasClipRect=root.hasClipRect;snapshot.clipRect=root.clipRect;
    snapshot.texture=texture;snapshot.contentGeneration=++state.attachmentSerial;snapshot.lifecycle=IFCompositorLifecycleClosing;snapshot.lifecycleProgress=0;return snapshot;
}
// A window closed (upstream snapshot_closing_window): on each output that drew it, the element of the frame last described is
// baked with all its chrome and live attachments into one texture, and that snapshot shrinks and fades in the closing bucket, or with inPlace fades
// where it stood, over the stand-in the window left (upstream's alpha_only). That element still retains the pixel buffer it
// drew, whatever the shell did with the window's stream since, until this output is described again: the bake comes first.
// Upstream's skips: a window no output showed has no element here; one that never had a picture has nothing to bake; and its
// age test, pixels of a window hidden more than a second ago, cannot come up, since what is baked is what the last frame showed.
// The density is upstream's flatten scale: the largest backing scale times zoom among the outputs showing a canvas window, the
// backing scale of its output for a pinned one, at least 1. Each output bakes its own copy at it, with the chrome it drew.
- (void)close:(NSNumber *)window inPlace:(BOOL)inPlace now:(double)now {
    double density=1;
    for(DWCanvasOutput *state in self.states.allValues){IFCompositorElement *element=state.elements[window];if(element.kind==IFCompositorElementKindWindow&&element.space!=IFCompositorSpacePinned&&pictured(element))density=fmax(density,state.frame.scale*state.frame.zoom);}
    for(DWCanvasOutput *state in self.states.allValues){
        IFCompositorElement *element=state.elements[window],*snapshot=nil;if(!element||element.kind!=IFCompositorElementKindWindow||!pictured(element))continue;
        @autoreleasepool{snapshot=[self closingFamily:window state:state flattenScale:element.space==IFCompositorSpacePinned?state.frame.scale:density];}
        if(!snapshot)continue;
        snapshot.identifier=[self mark];snapshot.lifecycle=inPlace?IFCompositorLifecycleClosingAlphaOnly:IFCompositorLifecycleClosing;snapshot.lifecycleStartTime=began(state,now);
        // Upstream's order: in front of the first snapshot in the list, so beneath every snapshot still running and above every fading stand-in.
        NSUInteger at=0;while(at<state.leaving.count&&state.leaving[at].kind!=IFCompositorElementKindSnapshot)at++;
        [state.leaving insertObject:snapshot atIndex:at];
    }
}
// A stand-in left (upstream StandInFade): the stand-in of the frame last described fades in the closing bucket, shrinking when
// it was dismissed and, with inPlace, where it stood over the window that adopted its slot, from that window's first picture.
// Beneath every snapshot and every older fade: first in the list.
- (void)fade:(NSNumber *)window inPlace:(BOOL)inPlace now:(double)now {
    for(DWCanvasOutput *state in self.states.allValues){
        IFCompositorElement *old=state.elements[window];if(!old||old.kind!=IFCompositorElementKindStandIn)continue;
        IFCompositorElement *fade=[IFCompositorElement new];fade.identifier=[self mark];fade.kind=IFCompositorElementKindStandIn;fade.rect=old.rect;fade.space=old.space;fade.layer=IFCompositorStackLayerClosing;
        fade.focused=old.focused;fade.decoration=old.decoration;fade.title=old.title;fade.appName=old.appName;fade.launching=old.launching;fade.showsPinnedIndicator=old.showsPinnedIndicator;
        fade.lifecycle=inPlace?IFCompositorLifecycleClosingAlphaOnly:IFCompositorLifecycleClosing;
        // One fade waits per window: an earlier one that still does goes now.
        if(inPlace){state.adopted[window].lifecycleStartTime=began(state,now);state.unseen[window]=@(now);state.adopted[window]=fade;}else fade.lifecycleStartTime=began(state,now);
        [state.leaving insertObject:fade atIndex:0];
    }
}
// snapshot.lifecycle_events: the window events upstream animates, oldest first, each with a serial that only grows. Every
// event newer than the last one played is played once, here, before any output is described again, while each output still
// holds the elements of its last frame. What the list held when this renderer described its first frame happened before
// there was a frame to animate. An opening is the output's own to start, in -render:. With animation_speed 1 upstream's
// animations are over on their first tick, and nothing is played.
- (void)play:(NSDictionary *)snapshot now:(double)now {
    NSArray *events=list(snapshot[@"lifecycle_events"]);uint64_t played=self.played,newest=played;
    for(id event in events)newest=MAX(newest,[DWTyped(DWTyped(event,NSDictionary.class)[@"serial"],NSNumber.class)unsignedLongLongValue]);
    self.played=newest;if(!self.following){self.following=YES;return;}
    if(newest==played||self.effects.animationSpeed>=1)return;
    for(id entry in events){
        NSDictionary *event=DWTyped(entry,NSDictionary.class);NSNumber *window=DWTyped(event[@"window"],NSNumber.class);NSString *name=DWTyped(event[@"event"],NSString.class);
        if(!window||[DWTyped(event[@"serial"],NSNumber.class)unsignedLongLongValue]<=played)continue;
        if([name isEqual:@"close"]||[name isEqual:@"close_to_standin"])[self close:window inPlace:[name isEqual:@"close_to_standin"] now:now];
        else if([name isEqual:@"standin_dismiss"]||[name isEqual:@"standin_adopted"])[self fade:window inPlace:[name isEqual:@"standin_adopted"] now:now];
    }
}
@end
