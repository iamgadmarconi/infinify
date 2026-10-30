// SPDX-License-Identifier: GPL-3.0-or-later
// Actual renderer demand queries, with in-memory states and lifecycle answers.
// No renderer/device, drawable, window, capture or native input is created.
#import "IFCompositor.h"
#include <stdio.h>
#include <stdlib.h>

@interface GeometryElement : NSObject
@property IFCompositorElementKind kind;
@property IFCompositorLifecycle lifecycle;
@end
@implementation GeometryElement @end
@interface GeometryFrame : NSObject
@property BOOL finished;
@property NSUInteger reads;
- (BOOL)lifecycleFinishedForElement:(GeometryElement *)element;
@end
@implementation GeometryFrame
- (BOOL)lifecycleFinishedForElement:(GeometryElement *)element { (void)element;self.reads++;return self.finished; }
@end
@interface DWCanvasOutput : NSObject
@property BOOL geometryAnimating,geometryNeedsSettledDraw;
@property NSDictionary<NSNumber *,GeometryElement *> *elements;
@property GeometryFrame *frame;
@end
@implementation DWCanvasOutput @end
@interface GeometryRenderer : NSObject
@property NSDictionary<NSNumber *,DWCanvasOutput *> *states;
@property(readonly) BOOL hasGeometryTransitions,hasFamilyGeometryTransitions;
@end
@implementation GeometryRenderer
#define IFCompositorElement GeometryElement
#include "family-geometry-queries.inc"
#undef IFCompositorElement
@end
static NSUInteger checks;
static void check(BOOL condition,const char *message) { checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);} }
int main(void) {@autoreleasepool {
    GeometryRenderer *renderer=[GeometryRenderer new];renderer.states=@{};
    check(!renderer.hasFamilyGeometryTransitions,"empty outputs have no live family transform");
    DWCanvasOutput *state=[DWCanvasOutput new];state.frame=[GeometryFrame new];state.elements=@{};renderer.states=@{@1:state};
    state.geometryAnimating=YES;check(renderer.hasFamilyGeometryTransitions,"active observed geometry preserves captures");
    state.geometryAnimating=NO;state.geometryNeedsSettledDraw=YES;check(renderer.hasFamilyGeometryTransitions,"undrawn settled geometry preserves captures");
    state.geometryNeedsSettledDraw=NO;
    GeometryElement *root=[GeometryElement new];root.kind=IFCompositorElementKindWindow;root.lifecycle=IFCompositorLifecycleNone;state.elements=@{@7:root};
    check(!renderer.hasFamilyGeometryTransitions&&!state.frame.reads,"steady roots require no lifecycle read");
    root.lifecycle=IFCompositorLifecycleOpening;
    check(renderer.hasFamilyGeometryTransitions&&state.frame.reads==1,"unfinished root opening conservatively captures protruding children");
    state.frame.finished=YES;check(!renderer.hasFamilyGeometryTransitions,"completed opening no longer disables visibility pruning");
    root.lifecycle=IFCompositorLifecycleClosing;state.frame.finished=NO;NSUInteger reads=state.frame.reads;
    check(!renderer.hasFamilyGeometryTransitions&&state.frame.reads==reads,"closing baked pictures need no live capture");
    root.kind=IFCompositorElementKindStandIn;root.lifecycle=IFCompositorLifecycleOpening;
    check(!renderer.hasFamilyGeometryTransitions&&state.frame.reads==reads,"stand-in animation needs no live family capture");
    DWCanvasOutput *other=[DWCanvasOutput new];other.frame=[GeometryFrame new];GeometryElement *otherRoot=[GeometryElement new];otherRoot.kind=IFCompositorElementKindWindow;otherRoot.lifecycle=IFCompositorLifecycleOpening;other.elements=@{@8:otherRoot};
    renderer.states=@{@1:state,@2:other};check(renderer.hasFamilyGeometryTransitions,"an opening on any independent view preserves demand");
    other.frame.finished=YES;check(!renderer.hasFamilyGeometryTransitions,"all independent views must finish before normal visibility pruning");
    printf("PASS: %lu family geometry demand checks (headless substituted state only)\n",(unsigned long)checks);return 0;
}}
