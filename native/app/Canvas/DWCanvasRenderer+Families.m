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

@implementation DWCanvasChild
@end
@implementation DWCanvasFamily
@end
@implementation DWCanvasRenderer (Families)
// Accept only the complete original tokens. Roots retain controller order and a
// child cannot move between compositor buckets or through a physical/stand-in/
// closing barrier. Provider dictionaries carry no additional ordering authority.
NSArray<NSDictionary *> *DWCanvasValidatedOrder(NSArray<NSDictionary *> *candidate,NSArray<NSDictionary *> *base) {
    if(![candidate isKindOfClass:NSArray.class]||candidate.count!=base.count)return base;
    NSSet *expected=[NSSet setWithArray:base];NSMutableSet *seen=[NSMutableSet set];
    NSMutableDictionary<NSDictionary *,NSNumber *> *segments=[NSMutableDictionary dictionary];
    NSMutableArray *roots=[NSMutableArray array],*nextRoots=[NSMutableArray array],*accepted=[NSMutableArray array];NSUInteger segment=0;NSNumber *bucket=nil;
    for(NSDictionary *token in base){
        if(![bucket isEqual:token[@"bucket"]]){bucket=token[@"bucket"];segment++;}
        if([token[@"barrier"]boolValue])segment++;
        segments[token]=@(segment);
        if(token[@"window"]&&!token[@"key"])[roots addObject:token];
        if([token[@"barrier"]boolValue])segment++;
    }
    for(NSUInteger i=0;i<candidate.count;i++){
        NSDictionary *token=DWTyped(candidate[i],NSDictionary.class),*original=base[i];
        if(!token||![expected containsObject:token]||[seen containsObject:token]||![token[@"bucket"]isEqual:original[@"bucket"]])return base;
        if([original[@"barrier"]boolValue]?![token isEqual:original]:[token[@"barrier"]boolValue]||![segments[token]isEqual:segments[original]])return base;
        [seen addObject:token];[accepted addObject:[expected member:token]];if(token[@"window"]&&!token[@"key"])[nextRoots addObject:token];
    }
    // Retain our immutable original tokens, never a provider's mutable copies.
    return [roots isEqualToArray:nextRoots]?accepted.copy:base;
}
- (void)rebuildOrderForState:(DWCanvasOutput *)state {
    NSMutableArray<NSDictionary *> *tokens=[NSMutableArray array];NSMutableDictionary<NSDictionary *,IFCompositorElement *> *elements=[NSMutableDictionary dictionary];
    static const IFCompositorStackLayer buckets[]={IFCompositorStackLayerWidget,IFCompositorStackLayerNormal,IFCompositorStackLayerClosing,IFCompositorStackLayerPinned};
    for(NSUInteger i=0;i<sizeof(buckets)/sizeof(*buckets);i++){
        IFCompositorStackLayer bucket=buckets[i];
        for(NSDictionary *p in state.orderPlacements){
            NSNumber *window=p[@"window"];IFCompositorElement *root=state.elements[window];
            IFCompositorStackLayer layer=root?root.layer:[DWTyped(p[@"pinned"],NSNumber.class)boolValue]?IFCompositorStackLayerPinned:[DWTyped(p[@"widget"],NSNumber.class)boolValue]?IFCompositorStackLayerWidget:IFCompositorStackLayerNormal;
            if(layer!=bucket)continue;
            BOOL barrier=!root||root.kind==IFCompositorElementKindStandIn;
            NSDictionary *token=barrier?@{@"window":window,@"bucket":@(bucket),@"barrier":@YES}:@{@"window":window,@"bucket":@(bucket)};
            [tokens addObject:token];if(root)elements[token]=root;
            for(DWCanvasChild *child in state.attachments[window].ordered){
                NSDictionary *member=@{@"window":window,@"key":child.key,@"bucket":@(bucket)};
                [tokens addObject:member];elements[member]=child.element;
            }
        }
        if(bucket==IFCompositorStackLayerClosing)for(IFCompositorElement *element in state.leaving){
            if(![state.frame.elements containsObject:element])continue;
            NSDictionary *token=@{@"mark":@(element.identifier),@"bucket":@(bucket),@"barrier":@YES};[tokens addObject:token];elements[token]=element;
        }
    }
    state.orderBase=tokens.copy;state.orderElements=elements.copy;state.orderDirty=NO;
}
// The base token list is cached across video frames. A coherent provider cohort
// can change order even when this output shows none of the callback's root, so
// every content callback checks revisions on every output before skipping it.
- (BOOL)applyOrderForOutput:(NSNumber *)output state:(DWCanvasOutput *)state {
    uint64_t revision=self.liveOrderRevision?self.liveOrderRevision(output):0;
    if(!state.orderDirty&&state.orderProvider==self.liveOrder&&state.orderRevisionProvider==self.liveOrderRevision&&(!self.liveOrder||(self.liveOrderRevision&&state.orderRevision==revision)))return NO;
    if(state.orderDirty)[self rebuildOrderForState:state];
    NSArray *order=DWCanvasValidatedOrder(self.liveOrder?self.liveOrder(state.orderBase,output):nil,state.orderBase);
    NSMutableArray<IFCompositorElement *> *elements=[NSMutableArray array];for(NSDictionary *token in order)if(state.orderElements[token])[elements addObject:state.orderElements[token]];
    // A missing description is never a usable hit order. It cannot silently drop
    // a visual element should a future compositor element lack a token adapter.
    if(elements.count!=state.frame.elements.count){state.orderApplied=nil;return NO;}
    BOOL changed=![state.frame.elements isEqualToArray:elements];if(changed)[state.frame.elements setArray:elements];
    state.orderApplied=order;state.orderRevision=revision;state.orderProvider=self.liveOrder;state.orderRevisionProvider=self.liveOrderRevision;
    return changed;
}
// Children inherit the final root geometry, including fullscreen and screen
// pins. An opening scales the whole family about the root's centre: giving each
// child its own Opening lifecycle would incorrectly grow it about its own centre.
- (void)geometryForFamily:(DWCanvasFamily *)family root:(IFCompositorElement *)root frame:(IFCompositorFrame *)frame {
    CGRect world=root.rect;IFCompositorDecoration decoration=IFCompositorDecorationDefault();
    decoration.mode=IFCompositorDecorationModeNone;decoration.borderWidth=0;decoration.cornerRadius=0;decoration.shadow=NO;decoration.opacity=root.decoration.opacity;
    BOOL transformed=root.hasTransform;IFCompositorTransform transform=root.transform;
    if(root.lifecycle==IFCompositorLifecycleOpening&&![frame lifecycleFinishedForElement:root]){
        double progress=[frame lifecycleProgressOfElement:root],scale=IFCompositorOpenScale(progress,frame.effects.animationScale);
        double zoom=root.space==IFCompositorSpacePinned?1:frame.zoom,density=frame.scale*zoom;
        double x=root.space==IFCompositorSpaceCanvas?world.origin.x-frame.cameraX:world.origin.x,y=root.space==IFCompositorSpaceCanvas?world.origin.y-frame.cameraY:world.origin.y;
        if(root.space==IFCompositorSpaceOutput){x/=zoom;y/=zoom;}
        double w=world.size.width,h=world.size.height;if(root.space==IFCompositorSpaceOutput){w/=zoom;h/=zoom;}
        transform=(IFCompositorTransform){x*density,y*density,(w-w*scale)/2*density,(h-h*scale)/2*density,w*scale/fmax(w,1),h*scale/fmax(h,1)};
        transformed=YES;decoration.opacity*=IFCompositorOpenAlpha(progress);
    }
    for(DWCanvasChild *image in family.ordered){
        IFCompositorElement *child=image.element;CGRect r=image.unitRect;
        child.rect=CGRectMake(world.origin.x+r.origin.x*world.size.width,world.origin.y+r.origin.y*world.size.height,r.size.width*world.size.width,r.size.height*world.size.height);
        child.space=root.space;child.layer=root.layer;child.decoration=decoration;child.hasTransform=transformed;child.transform=transform;
        child.hasClipRect=root.hasClipRect;child.clipRect=root.clipRect;
    }
}
// Refresh just this root's live family in the existing frame. Elements and their
// mark identifiers survive frames by opaque key; a withdrawn image releases its
// retained pixels immediately, including if a provider reuses its key later.
- (void)attachmentsForWindow:(NSNumber *)window output:(NSNumber *)output state:(DWCanvasOutput *)state {
    IFCompositorElement *root=state.elements[window];DWCanvasFamily *family=state.attachments[window];
    NSArray<DWCanvasAttachment *> *supplied=root.kind==IFCompositorElementKindWindow&&self.liveAttachments?self.liveAttachments(window,output):nil;
    if(!family&&!supplied.count)return;
    if(!family){family=[DWCanvasFamily new];family.images=[NSMutableDictionary dictionary];family.ordered=@[];state.attachments[window]=family;}
    NSArray<DWCanvasChild *> *ordered=family.ordered;
    // Ordinary capture and camera frames keep the same family. Validate every
    // current image and its ordered key before reusing the list; no provider
    // array/object identity or prior validity can keep withdrawn pixels alive.
    // The existing ordered keys are unique, so an exact match also excludes a
    // duplicate without allocating another set for every pixel frame.
    BOOL same=supplied.count==ordered.count;
    if(same)for(NSUInteger i=0;i<supplied.count;i++){
        DWCanvasAttachment *image=supplied[i];
        if(!validAttachment(image)||![ordered[i].key isEqual:image.key]){same=NO;break;}
    }
    if(same){
        for(NSUInteger i=0;i<supplied.count;i++){
            DWCanvasAttachment *image=supplied[i];DWCanvasChild *child=ordered[i];
            child.unitRect=image.unitRect;child.element.pixelBuffer=image.buffer;child.element.texture=nil;child.element.contentGeneration=image.generation;child.element.contentRect=image.contentRect;
        }
    }else{
        NSMutableArray<DWCanvasChild *> *next=[NSMutableArray array];NSMutableSet<NSString *> *keys=[NSMutableSet set];
        for(DWCanvasAttachment *image in supplied){
            if(!validAttachment(image))continue;NSString *key=image.key;CGRect r=image.unitRect;
            if(!key.length||[keys containsObject:key])continue;
            [keys addObject:key];DWCanvasChild *child=family.images[key];
            if(!child){child=[DWCanvasChild new];child.key=key;child.element=[IFCompositorElement new];child.element.identifier=[self mark];child.element.kind=IFCompositorElementKindWindow;family.images[key]=child;}
            child.unitRect=r;child.element.pixelBuffer=image.buffer;child.element.texture=nil;child.element.contentGeneration=image.generation;child.element.contentRect=image.contentRect;
            [next addObject:child];
        }
        for(NSString *key in family.images.allKeys)if(![keys containsObject:key]){
            DWCanvasChild *child=family.images[key];child.element.pixelBuffer=NULL;child.element.texture=nil;child.element.contentGeneration=0;[family.images removeObjectForKey:key];
        }
        ordered=next;
    }
    // On a description the frame was emptied; on a content callback only a
    // changed family order or membership needs to splice the element list.
    BOOL present=family.ordered.count&&[state.frame.elements containsObject:family.ordered.firstObject.element];
    if(!present||![family.ordered isEqualToArray:ordered]){
        state.orderDirty=YES;
        for(DWCanvasChild *child in family.ordered)[state.frame.elements removeObject:child.element];
        NSUInteger at=[state.frame.elements indexOfObjectIdenticalTo:root];
        if(at!=NSNotFound)for(DWCanvasChild *child in ordered)[state.frame.elements insertObject:child.element atIndex:++at];
    }
    family.ordered=ordered;
    if(ordered.count)[self geometryForFamily:family root:root frame:state.frame];else [state.attachments removeObjectForKey:window];
}
@end
