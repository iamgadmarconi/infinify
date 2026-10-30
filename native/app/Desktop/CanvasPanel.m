// SPDX-License-Identifier: GPL-3.0-or-later
// A canvas panel that never becomes key or main on its own.
#import "CanvasPanel.h"
@implementation CanvasPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
