// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1.
// A canvas panel that never becomes key or main on its own.
#import <AppKit/AppKit.h>
// A canvas panel never becomes key or main on its own (DesktopPanel lets its stand-in keyboard make it key).
@interface CanvasPanel : NSPanel
@end
