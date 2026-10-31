// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation of Ego's Button roles and palette (ego/docs/DESIGN_SYSTEM.md) in AppKit.
#import "DWSetupButton.h"

static NSColor *grey(NSString *name,CGFloat light,CGFloat dark) {
    return [NSColor colorWithName:name dynamicProvider:^NSColor *(NSAppearance *appearance){
        BOOL isDark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        CGFloat value=(isDark?dark:light)/255.0;
        return [NSColor colorWithSRGBRed:value green:value blue:value alpha:1];
    }];
}
NSColor *DWSetupCanvasColor(void) { return grey(@"DWSetupCanvas",0xFF,0x10); }
NSColor *DWSetupRaisedColor(void) { return grey(@"DWSetupRaised",0xF3,0x1C); }
NSColor *DWSetupTextColor(void) { return grey(@"DWSetupText",0x11,0xF2); }
NSColor *DWSetupSecondaryTextColor(void) { return grey(@"DWSetupSecondary",0x77,0x99); }
NSColor *DWSetupTertiaryTextColor(void) { return grey(@"DWSetupTertiary",0x99,0x77); }
NSColor *DWSetupSoftColor(void) { return grey(@"DWSetupSoft",0xE9,0x29); }
NSColor *DWSetupFaintColor(void) { return grey(@"DWSetupFaint",0xE4,0x33); }
NSFont *DWSetupFont(CGFloat size,BOOL medium) {
    return [NSFont fontWithName:medium?@"HelveticaNeue-Medium":@"HelveticaNeue" size:size]?:(medium?[NSFont systemFontOfSize:size weight:NSFontWeightMedium]:[NSFont systemFontOfSize:size]);
}

@implementation DWSetupButton {
    BOOL _hovered,_styling;
    NSTrackingArea *_tracking;
}
+ (instancetype)buttonWithTitle:(NSString *)title role:(DWSetupButtonRole)role target:(id)target action:(SEL)action {
    DWSetupButton *button=[self buttonWithTitle:title target:target action:action];
    button.bordered=NO;button.wantsLayer=YES;button.focusRingType=NSFocusRingTypeExterior;
    button.role=role;
    return button;
}
- (NSFont *)labelFont { return DWSetupFont(_role==DWSetupButtonLink?11:12,NO); }
// The label, in a colour that follows the appearance by itself; set again whenever role, title, state or hover change.
- (void)restyle {
    if(_styling)return;_styling=YES;
    NSColor *label=_role==DWSetupButtonPrimary?DWSetupCanvasColor():_role==DWSetupButtonSecondary?DWSetupTextColor():_hovered?DWSetupTextColor():DWSetupSecondaryTextColor();
    if(!self.enabled)label=DWSetupFaintColor();
    NSMutableParagraphStyle *centered=[NSMutableParagraphStyle new];centered.alignment=NSTextAlignmentCenter;
    self.attributedTitle=[[NSAttributedString alloc]initWithString:self.title attributes:@{NSFontAttributeName:self.labelFont,NSForegroundColorAttributeName:label,NSParagraphStyleAttributeName:centered}];
    [self invalidateIntrinsicContentSize];self.needsDisplay=YES;
    _styling=NO;
}
- (void)setRole:(DWSetupButtonRole)role { _role=role;[self restyle]; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled];[self restyle];[self.window invalidateCursorRectsForView:self]; }
- (void)setTitle:(NSString *)title { [super setTitle:title];[self restyle]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (NSSize)intrinsicContentSize {
    NSSize label=[self.title sizeWithAttributes:@{NSFontAttributeName:self.labelFont}];
    CGFloat inset=_role==DWSetupButtonLink?8:12;
    return NSMakeSize(ceil(label.width)+2*inset,_role==DWSetupButtonLink?22:28);
}
// The fill: the label's ground, resolved for this view's appearance. It moves toward the canvas on hover (Primary) or toward
// the ink (Secondary), as Ego's does; an unavailable filled button rests on the soft fill.
- (void)updateLayer {
    __block CGColorRef fill=NULL;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *background=nil;BOOL hover=self->_hovered&&self.enabled;
        switch(self->_role){
            case DWSetupButtonPrimary:background=self.enabled?DWSetupTextColor():DWSetupSoftColor();
                if(hover)background=[background blendedColorWithFraction:.15 ofColor:DWSetupCanvasColor()];break;
            case DWSetupButtonSecondary:background=DWSetupSoftColor();
                if(hover)background=[background blendedColorWithFraction:.10 ofColor:DWSetupTextColor()];break;
            case DWSetupButtonLink:background=hover?DWSetupRaisedColor():nil;break;
        }
        if(background)fill=CGColorRetain([background colorUsingColorSpace:NSColorSpace.sRGBColorSpace].CGColor);
    }];
    self.layer.backgroundColor=fill;if(fill)CGColorRelease(fill);
    self.layer.cornerRadius=_role==DWSetupButtonLink?6:12;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if(_tracking)[self removeTrackingArea:_tracking];
    _tracking=[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent *)event { (void)event;_hovered=YES;[self restyle]; }
- (void)mouseExited:(NSEvent *)event { (void)event;_hovered=NO;[self restyle]; }
- (void)resetCursorRects { if(self.enabled)[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance];self.needsDisplay=YES; }
@end
