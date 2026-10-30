// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// A normal run's full-display canvas panel.
#import "DesktopPanel.h"
@implementation DesktopPanel
- (BOOL)canBecomeKeyWindow {return self.standinKeyboard;}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen { (void)screen;return frame; }
@end
