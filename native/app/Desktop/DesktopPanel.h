// SPDX-License-Identifier: GPL-3.0-or-later
// A normal run's full-display canvas panel.
#import "CanvasPanel.h"
// A normal run's panel covers its display whole, the part under the menu bar and the Dock included: AppKit is not to
// move it into the area those leave free. Its level stays NSFloatingWindowLevel (3), above every ordinary window and
// below the Dock (20) and the menu bar (24), which both keep drawing over the canvas.
@interface DesktopPanel : CanvasPanel
@property BOOL standinKeyboard;
@end
