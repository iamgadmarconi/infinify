// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Immutable offscreen pixels {image: CGImage, path, width, height}, or {error}.
// Encodes a PNG, creates missing parent directories and writes the named file
// without a renderer or native window: to a new file beside it that is renamed
// into place, so a failed write leaves the path as it was. An existing file is
// replaced, a symbolic link at the path replaced rather than written through. Returns
// {path,width,height}, or {error}; safe on the screenshot serial worker.
NSDictionary *DWWriteScreenshotPixels(NSDictionary *pixels);
