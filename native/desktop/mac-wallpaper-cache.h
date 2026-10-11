// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Worker-only fallback for a missing NSWorkspace desktop image. macOS may keep
// displaying its cached rendition after the original file has been removed.
// Returns only a rendition of this exact source path at this display's size.
NSURL *DWMacCachedWallpaper(NSURL *source, CGSize pixels);
