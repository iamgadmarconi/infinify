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
#import "DWGeometryJSON.h"
#import <AppKit/AppKit.h>

@implementation DWCanvasGeometry
@end
static CGRect geometryRect(DWCanvasGeometry *geometry,double now) {
    if(!geometry.active||now>=geometry.end)return geometry.target;
    double t=fmin(1,fmax(0,(now-geometry.start)/(geometry.end-geometry.start))),p=t*t*(3-2*t);
    CGRect a=geometry.from,b=geometry.target;
    return CGRectMake(a.origin.x+(b.origin.x-a.origin.x)*p,a.origin.y+(b.origin.y-a.origin.y)*p,
                      a.size.width+(b.size.width-a.size.width)*p,a.size.height+(b.size.height-a.size.height)*p);
}
static CGRect geometryFromScreen(CGRect rect,IFCompositorSpace space,IFCompositorFrame *frame) {
    if(space==IFCompositorSpaceCanvas)return CGRectMake(rect.origin.x/frame.zoom+frame.cameraX,rect.origin.y/frame.zoom+frame.cameraY,rect.size.width/frame.zoom,rect.size.height/frame.zoom);
    return rect;
}

@implementation DWCanvasRenderer (GeometryTransitions)
- (void)describeGeometry:(NSDictionary *)snapshot state:(DWCanvasOutput *)state now:(double)now {
    BOOL wasAnimating=state.geometryAnimating;
    state.geometryAnimating=NO;
    // Physical WindowServer windows must keep the geometry submitted to their
    // native presenter; this overlay animation cannot move those windows.
    if(self.nativeWindows){[state.geometry removeAllObjects];state.geometryNeedsSettledDraw|=wasAnimating;return;}
    if(!state.geometry)state.geometry=[NSMutableDictionary dictionary];
    CGRect bounds=rectOf(state.orderOutput[@"screen_bounds"]);
    if(!CGRectEqualToRect(bounds,state.geometryBounds)){[state.geometry removeAllObjects];state.geometryBounds=bounds;}
    NSDictionary *resize=DWTyped(snapshot[@"native_resize"],NSDictionary.class);NSString *phase=DWTyped(resize[@"phase"],NSString.class);
    BOOL live=DWTyped(resize[@"pending_effect"],NSDictionary.class)||[phase isEqual:@"preparing"]||[phase isEqual:@"dragging"]||[phase isEqual:@"settling"];
    double duration=fmin(.35,fmax(.20,IFCompositorAnimationDuration(self.effects.animationSpeed)));
    for(NSNumber *window in state.geometry.allKeys)if(!state.elements[window])[state.geometry removeObjectForKey:window];
    for(NSNumber *window in state.elements){
        IFCompositorElement *element=state.elements[window];NSDictionary *p=state.placements[window],*source=DWTyped(p[@"source"],NSDictionary.class),*identity=DWTyped(source[@"identity"],NSDictionary.class);NSNumber *generation=DWTyped(source[@"generation"],NSNumber.class);
        if(element.kind!=IFCompositorElementKindWindow||!identity||!generation||!DWFiniteRect(element.rect)){[state.geometry removeObjectForKey:window];continue;}
        DWCanvasGeometry *geometry=state.geometry[window];BOOL known=geometry&&[geometry.identity isEqual:identity]&&[geometry.generation isEqual:generation];
        BOOL full=[DWTyped(p[@"fullscreen"],NSNumber.class)boolValue];
        BOOL action=[resize[@"window"]isEqual:window]&&DWTyped(resize[@"interactive"],NSNumber.class)&&![resize[@"interactive"]boolValue]&&[resize[@"identity"]isEqual:identity]&&[resize[@"generation"]isEqual:generation];
        NSNumber *transaction=action?DWTyped(resize[@"transaction"],NSNumber.class):nil;CGRect target=element.rect;
        if(!known){geometry=[DWCanvasGeometry new];geometry.identity=identity;geometry.generation=generation;geometry.target=target;geometry.space=element.space;geometry.screen=geometryScreen(target,element.space,state.frame);state.geometry[window]=geometry;}
        BOOL changed=geometry.space!=element.space||!CGRectEqualToRect(geometry.target,target);
        BOOL permitted=(geometry.active||geometry.fullscreen!=full||(action&&(live||geometry.actionLive||![geometry.transaction isEqual:transaction])))&&!(action&&[geometry.blockedTransaction isEqual:transaction]);
        BOOL animate=known&&geometry.drawn&&pictured(element)&&element.lifecycle==IFCompositorLifecycleNone&&self.effects.animationSpeed<1&&!NSEvent.pressedMouseButtons;
        if(changed&&permitted&&animate){
            // A canvas/fullscreen space switch starts where the last frame drew
            // the window. Ordinary fit sizing stays in world space, so the
            // controller's already-smooth camera flight is not delayed again.
            CGRect from=geometry.space==element.space?geometryRect(geometry,now):geometryFromScreen(geometry.screen,element.space,state.frame);
            double end=geometry.active&&now<geometry.end?fmax(geometry.end,now+.04):now+duration;
            geometry.from=from;geometry.start=now;geometry.end=end;geometry.active=DWFiniteRect(from)&&!CGRectEqualToRect(from,target);
        }else if(changed||!animate||now>=geometry.end)geometry.active=NO;
        geometry.target=target;geometry.space=element.space;geometry.fullscreen=full;geometry.actionLive=action&&live;geometry.transaction=transaction;
        element.rect=geometryRect(geometry,now);state.geometryAnimating|=geometry.active;
    }
    state.geometryNeedsSettledDraw|=wasAnimating&&!state.geometryAnimating;
}
- (void)advanceGeometry:(DWCanvasOutput *)state now:(double)now {
    if(!state.geometryAnimating)return;state.geometryAnimating=NO;
    for(NSNumber *window in state.geometry){DWCanvasGeometry *geometry=state.geometry[window];if(!geometry.active)continue;
        IFCompositorElement *element=state.elements[window];if(!element){geometry.active=NO;continue;}
        element.rect=geometryRect(geometry,now);if(now>=geometry.end)geometry.active=NO;state.geometryAnimating|=geometry.active;
    }
    state.geometryNeedsSettledDraw|=!state.geometryAnimating;
}
@end
