// SPDX-License-Identifier: GPL-3.0-or-later
// A normal run's full-display canvas panel.
#import "DesktopPanel.h"
@implementation DesktopPanel
- (BOOL)canBecomeKeyWindow {return self.standinKeyboard;}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen { (void)screen;return frame; }
@end
