// SPDX-License-Identifier: GPL-3.0-or-later
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
// Optional image attachments in the root's normalized top-left rectangle:
// (0,0,1,1) is the root; negative coordinates and extents beyond one are valid.
// This generic image geometry carries no native identity or ownership. Each
// attachment retains its pixels, and the provider orders them back to front.
@interface DWCanvasAttachment : NSObject
// Opaque identity, stable within this root's family. Required for live images;
// one-shot exports require it when exportOrder is installed and may otherwise
// omit it. Never a native ownership identifier here.
@property(nonatomic,copy) NSString *key;
@property(nonatomic) CVPixelBufferRef buffer;
// Changes whenever pixels change, including when the buffer is reused.
@property(nonatomic) uint64_t generation;
// Image region inside the buffer, in top-left pixel coordinates. CGRectNull
// (the default) samples all pixels. A crop must be finite, positive and inside
// the buffer; invalid live crops withdraw the image and invalid exports refuse.
@property(nonatomic) CGRect contentRect;
@property(nonatomic) CGRect unitRect;
@end
