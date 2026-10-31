// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// The setup assistant's text button, after Ego's design system (ego/docs/DESIGN_SYSTEM.md, Buttons): the role alone decides
// the surface. Primary is the pane's one main action, filled with the text ink and labelled in the canvas colour; Secondary
// rests on a soft neutral fill; Link is text only, muted. 28 points high, 12 points of side padding, the shared 12-point
// radius, a 12-point Helvetica Neue label; an unavailable button keeps its fill with a faint label. Colours follow the
// window's appearance, light or dark, and every one is a neutral grey.
typedef NS_ENUM(NSInteger,DWSetupButtonRole) { DWSetupButtonPrimary, DWSetupButtonSecondary, DWSetupButtonLink };

// Ego's role colours (DESIGN_SYSTEM.md, Color), resolved for the appearance they are drawn in.
NSColor *DWSetupCanvasColor(void);
NSColor *DWSetupRaisedColor(void);
NSColor *DWSetupTextColor(void);
NSColor *DWSetupSecondaryTextColor(void);
NSColor *DWSetupTertiaryTextColor(void);
NSColor *DWSetupSoftColor(void);
NSColor *DWSetupFaintColor(void);
// Helvetica Neue at Ego's sizes: the shared 12-point text, its medium weight for titles, 11 for secondary text.
NSFont *DWSetupFont(CGFloat size,BOOL medium);

@interface DWSetupButton : NSButton
+ (instancetype)buttonWithTitle:(NSString *)title role:(DWSetupButtonRole)role target:(id)target action:(SEL)action;
@property(nonatomic) DWSetupButtonRole role;
@end
