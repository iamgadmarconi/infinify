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
#import <AppKit/AppKit.h>

// AppKit's owned fullscreen exclusion plane is independent of real-window ownership. Its
// content cannot take focus or input, and AppKit must not move this deliberate
// menu-band frame into the screen's visibleFrame below the menu bar.
@interface DWCanvasMenuPanel : NSPanel
@end
@implementation DWCanvasMenuPanel
- (BOOL)canBecomeKeyWindow {return NO;}
- (BOOL)canBecomeMainWindow {return NO;}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen {(void)screen;return frame;}
@end
@interface DWCanvasMenuView : NSView
@end
@implementation DWCanvasMenuView
- (BOOL)isFlipped {return YES;}
@end
// The ordinary compositor layer supplies asynchronous drawables, pacing and
// retirement. Only its background-only renderer differs: a W x T target clips
// a W x H viewport. Background shaders use absolute fragment pixels, and cached
// chunks use full-output vertex coordinates, so both sample the same top rows
// as the canvas without allocating another full-display framebuffer.
@interface DWCanvasMenuRenderer : IFCompositorRenderer
@property CGSize outputSize;
@end
@implementation DWCanvasMenuRenderer
- (BOOL)encodeFrame:(IFCompositorFrame *)frame intoTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    double width=round(round(self.outputSize.width)*frame.scale),height=round(round(self.outputSize.height)*frame.scale);
    if(!isfinite(width)||!isfinite(height)||width<=0||height<=0||width>16384||height>16384||target.width!=(NSUInteger)width||target.height>(NSUInteger)height)return NO;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[commandBuffer renderCommandEncoderWithDescriptor:pass];if(!encoder)return NO;
    [encoder setViewport:(MTLViewport){0,0,width,height,0,1}];
    [encoder setScissorRect:(MTLScissorRect){0,0,target.width,target.height}];
    IFBackgroundFrame background={frame.cameraX,frame.cameraY,frame.zoom,self.outputSize.width,self.outputSize.height,frame.scale,frame.time};
    [frame.background encodeFrame:background inEncoder:encoder];[encoder endEncoding];return YES;
}
@end

@implementation DWCanvasRenderer (Fullscreen)
- (void)stopMenuBackground:(DWCanvasOutput *)state {
    [state.menuLayer stopDrawing];[state.menuLayer removeFromSuperlayer];state.menuFrame.background=nil;
    [state.menuLayer.renderer purge];[state.menuPanel orderOut:nil];[state.menuPanel close];
    state.menuPanel=nil;state.menuLayer=nil;state.menuFrame=nil;state.menuDirty=NO;
}
- (void)describeMenuBackground:(DWCanvasOutput *)state output:(NSDictionary *)output snapshot:(NSDictionary *)snapshot {
    NSNumber *identifier=DWTyped(output[@"id"],NSNumber.class);CGRect bounds=rectOf(output[@"screen_bounds"]);
    NSDictionary *context=DWTyped(DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"contexts"],NSDictionary.class)[identifier.stringValue],NSDictionary.class);
    CGRect usable=rectOf(context[@"usable_rect_local"]);double top=usable.origin.y;
    if(!self.nativeWindows||!self.nativeMenuBackground||!DWTyped(output[@"fullscreen"],NSDictionary.class)||CGRectIsNull(usable)||!isfinite(top)||top<=0||top>=bounds.size.height){[self stopMenuBackground:state];return;}
    top=ceil(top);if(top>=bounds.size.height){[self stopMenuBackground:state];return;}
    NSRect place=NSMakeRect(bounds.origin.x,NSMaxY(NSScreen.screens.firstObject.frame)-bounds.origin.y-top,bounds.size.width,top);
    if(!state.menuPanel){
        DWCanvasMenuRenderer *renderer=[DWCanvasMenuRenderer rendererWithDevice:state.layer.renderer.device];if(!renderer)return;
        state.menuLayer=[[IFCompositorLayer alloc]initWithRenderer:renderer];
        state.menuFrame=[IFCompositorFrame new];state.menuFrame.clear=IFCompositorClearOpaqueBlack;
        state.menuPanel=[[DWCanvasMenuPanel alloc]initWithContentRect:place styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        state.menuPanel.releasedWhenClosed=NO;state.menuPanel.level=NSMainMenuWindowLevel-1;state.menuPanel.ignoresMouseEvents=YES;
        state.menuPanel.hidesOnDeactivate=NO;state.menuPanel.canHide=NO;state.menuPanel.hasShadow=NO;state.menuPanel.opaque=YES;
        state.menuPanel.backgroundColor=NSColor.blackColor;state.menuPanel.animationBehavior=NSWindowAnimationBehaviorNone;
        state.menuPanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle|NSWindowCollectionBehaviorFullScreenAuxiliary;
        DWCanvasMenuView *view=[[DWCanvasMenuView alloc]initWithFrame:NSMakeRect(0,0,place.size.width,place.size.height)];view.wantsLayer=YES;view.layer=state.menuLayer;state.menuPanel.contentView=view;
        __weak DWCanvasRenderer *weak=self;__weak IFCompositorLayer *layer=state.menuLayer;
        state.menuLayer.drawableReady=^{DWCanvasRenderer *shown=weak;DWCanvasOutput *current=shown.states[identifier];if(shown.nativeMenuBackground&&current.menuLayer==layer&&current.menuDirty)[shown setNeedsFlush];};
    }
    DWCanvasMenuRenderer *renderer=(DWCanvasMenuRenderer *)state.menuLayer.renderer;
    if(!CGSizeEqualToSize(renderer.outputSize,bounds.size)){renderer.outputSize=bounds.size;[state.menuLayer setNeedsRedraw];}
    if(!NSEqualRects(state.menuPanel.frame,place)){[state.menuPanel setFrame:place display:NO];[state.menuLayer setNeedsRedraw];self.placed=YES;}
    state.menuLayer.frame=CGRectMake(0,0,place.size.width,place.size.height);
    IFCompositorFrame *frame=state.menuFrame;frame.size=CGSizeMake(bounds.size.width,top);frame.scale=state.frame.scale;
    frame.cameraX=state.frame.cameraX;frame.cameraY=state.frame.cameraY;frame.zoom=state.frame.zoom;frame.background=state.background;state.menuDirty=YES;
    // Like the canvas panel, order before acquisition: a hidden Metal surface
    // must not be required to deliver the drawable that would first show it.
    if(!state.menuPanel.isVisible)[state.menuPanel orderFrontRegardless];
}
// Adapted from DriftWM, https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/state/fullscreen.rs
// (enter_fullscreen: the window fills its output at zoom 1 from the output's own
// corner; recentre_fullscreen_window: one that took another size sits
// in the middle of it), src/render/chrome.rs (DrawnChrome::drawn: a fullscreen window
// sheds bar, border, corners and shadow) and src/tests/translucent_fullscreen.rs
// (fullscreen_conceals_canvas: an opaque fullscreen window conceals the background and
// the outlines of the other outputs, also where a smaller one leaves a band, which stays
// the clear colour; one drawn see-through leaves both drawn under it). Which window is
// fullscreen where, what else its output still shows and where the window sits are the
// controller's: outputs[].fullscreen, the placements it lists for that output and the
// screen_rect of the one it marks fullscreen. No native window geometry is read.
//
// One output's fullscreen, applied to the frame -render: has just described. The marked
// placement is drawn at its screen_rect, global screen points at zoom 1 whatever the
// output's camera and zoom, and bare. That is the compositor's pinned space: output-local
// points at zoom 1, which its output space only approximates by dividing by the frame's
// zoom (COMPOSITOR-NOTES.md, deviation 10); at zoom 1 the two are the same arithmetic.
// The window keeps its place in the list and its layer. Run for every output on every
// describe, so the background and the outlines are back with the first frame after the exit.
//
// A fullscreen output shows a screen-space window, not a canvas viewport, so it projects no
// outline onto the others (upstream build_output_outline_elements passes over one that is
// visually fullscreen, opaque or see-through): an output with such a neighbour has its
// outlines described again here, from the snapshot's outputs, without that neighbour's.
- (void)fullscreen:(NSDictionary *)o among:(NSArray<NSDictionary *> *)all state:(DWCanvasOutput *)state {
    IFCompositorFrame *frame=state.frame;NSDictionary *full=DWTyped(o[@"fullscreen"],NSDictionary.class);CGPoint corner=rectOf(o[@"screen_bounds"]).origin;
    // "black": nothing but the clear colour lies behind the window. "canvas": its opacity is below 1 and the canvas shows through it.
    BOOL concealed=full&&![DWTyped(full[@"backdrop"],NSString.class)isEqual:@"canvas"],parked=NO;
    for(NSDictionary *other in all)if(other!=o&&DWTyped(other[@"fullscreen"],NSDictionary.class))parked=YES;
    // Upstream shrinks a concealed output's chunk cache on every such frame: it frees its chunks, keeps its floor and has nothing pending.
    // Native windows fill the usable desktop area while this canvas covers the
    // entire display. Keep its background beneath the menu bar and uncovered
    // desktop margins; only captured fullscreen pixels use upstream's black
    // backdrop. A fullscreen still projects no other output's outline.
    frame.background=concealed&&!self.nativeWindows?nil:state.background;if(concealed){if(!self.nativeWindows)[state.background shrinkChunkCache];[frame setOutlineRects:NULL count:0];}
    else if(parked){
        NSMutableData *outlines=[NSMutableData data];
        for(NSDictionary *other in all){
            if(other==o||!DWTyped(other[@"id"],NSNumber.class)||[other[@"id"]isEqual:o[@"id"]]||DWTyped(other[@"fullscreen"],NSDictionary.class))continue;
            CGPoint otherCamera=pointOf(other[@"camera"]);CGRect otherBounds=rectOf(other[@"screen_bounds"]);if(CGRectIsNull(otherBounds))continue;
            CGRect outline=IFCompositorOutlineRect(frame.cameraX,frame.cameraY,frame.zoom,otherCamera.x,otherCamera.y,otherBounds.size,[DWTyped(other[@"zoom"],NSNumber.class)doubleValue]);[outlines appendBytes:&outline length:sizeof(outline)];
        }
        [frame setOutlineRects:outlines.bytes count:outlines.length/sizeof(CGRect)];
    }
    for(NSNumber *window in state.placements){
        NSDictionary *p=state.placements[window];IFCompositorElement *element=state.elements[window];CGRect screen=rectOf(p[@"screen_rect"]);
        // The controller refuses a stand-in fullscreen; one marked so all the same is drawn as the stand-in it is.
        if(![DWTyped(p[@"fullscreen"],NSNumber.class)boolValue]||element.kind!=IFCompositorElementKindWindow||CGRectIsNull(screen))continue;
        element.rect=CGRectOffset(screen,-corner.x,-corner.y);element.space=IFCompositorSpacePinned;
        element.decoration=IFCompositorDecorationDrawn(element.decoration,YES,IFCompositorCoverageNone);
    }
}
- (void)flushMenuBackground:(DWCanvasOutput *)state {
    if(!state.menuLayer)return;
    IFCompositorFrame *frame=state.menuFrame;
    // Reuse the canvas's exact frame instant as well as its coordinates. The
    // shared output cache spends its bake/upload allowance once for that frame,
    // even when either layer's drawable becomes ready later than the other's.
    frame.time=state.frame.time;state.menuLayer.paced=self.paced;
    @autoreleasepool{[state.menuLayer updateWithFrame:frame];}state.menuDirty=state.menuLayer.missed;
}
@end
