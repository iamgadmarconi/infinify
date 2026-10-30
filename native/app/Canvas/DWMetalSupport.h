// SPDX-License-Identifier: GPL-3.0-or-later
//
// Metal plumbing that IFBGDeviceResources.m, IFBackgroundProgram.m and the compositor pieces
// (IFCDeviceResources.m, IFCompositorFrame.m) both need and must keep
// identical: the integer output size of a frame, the per-device cache of shared
// resources, the shader compile options and the linear sampler. Header-only
// (static inline); each module keeps its own pipelines and shaders.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <math.h>

/// Integer output size, as upstream's logical output size is integral: the
/// logical size in points (rounded, never negative) and the size in pixels at
/// `scale` (1 when `scale` is not a positive number). Any out pointer may be NULL.
static inline void DWMetalPixelSize(double width, double height, double scale,
                                    long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH) {
    scale = (isfinite(scale) && scale > 0) ? scale : 1.0;
    long lw = isfinite(width) ? lround(width) : 0, lh = isfinite(height) ? lround(height) : 0;
    lw = MAX(lw, 0L);
    lh = MAX(lh, 0L);
    if (logicalW) *logicalW = lw;
    if (logicalH) *logicalH = lh;
    if (pxW) *pxW = (NSUInteger)MAX(0L, lround((double)lw * scale));
    if (pxH) *pxH = (NSUInteger)MAX(0L, lround((double)lh * scale));
}

/// The one object `owner` shares per Metal device, made by `make` the first time
/// the device is asked for and kept for the life of the process. A device is
/// identified by its registry ID.
static inline id DWMetalSharedForDevice(Class owner, id<MTLDevice> device, id (^make)(void)) {
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized(cache) {
        NSString *key = [NSString stringWithFormat:@"%@/%llu", NSStringFromClass(owner), device.registryID];
        id shared = cache[key];
        if (!shared) {
            shared = make();
            cache[key] = shared;
        }
        return shared;
    }
}

/// Shader compile options: IEEE-754 arithmetic (no reassociation, NaN and
/// infinity honoured) so GLSL written for `precision highp float` computes what
/// it says; library functions (sin, pow, ...) stay at the GPU's native
/// precision, as on every GL driver. Measured on an Apple M5 Pro at 3456x2234:
/// fast_smoke costs 8.6 ms of GPU time per frame this way against 20.6 ms with
/// MTLMathFloatingPointFunctionsPrecise, and the precise variant draws a
/// *different* noise pattern from the system GLSL compiler far from the canvas
/// origin (docs/native/app/Canvas/BACKGROUND-NOTES.md, "Math mode").
static inline MTLCompileOptions *DWMetalCompileOptions(void) {
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.mathMode = MTLMathModeSafe;
    options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
    return options;
}

/// smithay: GL_LINEAR minification and magnification, no mipmaps, and `mode`
/// (clamp to edge, or mirrored repeat for the blur) on both axes.
static inline id<MTLSamplerState> DWMetalLinearSampler(id<MTLDevice> device, MTLSamplerAddressMode mode) {
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode = mode;
    sd.tAddressMode = mode;
    return [device newSamplerStateWithDescriptor:sd];
}

static inline id<MTLSamplerState> DWMetalLinearClampSampler(id<MTLDevice> device) {
    return DWMetalLinearSampler(device, MTLSamplerAddressModeClampToEdge);
}
