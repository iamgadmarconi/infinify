// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Immutable offscreen pixels {image: CGImage, path, width, height}, or {error}.
// Encodes a PNG, creates missing parent directories and writes the named file
// without a renderer or native window. Existing files are overwritten. Returns
// {path,width,height}, or {error}; safe on the screenshot serial worker.
NSDictionary *DWWriteScreenshotPixels(NSDictionary *pixels);
