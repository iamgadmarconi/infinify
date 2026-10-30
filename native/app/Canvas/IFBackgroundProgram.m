// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: IFBackgroundConfig and
// IFBackgroundProgram - see IFBackground.h and docs/native/app/Canvas/BACKGROUND-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/background.rs
// (init_background and its helpers, update, update_background_element),
// src/config/mod.rs, src/render/tile_chunks.rs and
// src/render/capture_background.rs, as the comments below cite.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackground.h"
#import "IFBackground+Private.h"
#import "IFBGTiffSource.h"
#import "DWMetalSupport.h"

#import <AppKit/NSImage.h>

#include <math.h>
#include <string.h>

// MARK: - Config

@implementation IFBackgroundConfig

- (instancetype)init {
    if ((self = [super init])) {
        _type = IFBackgroundTypeDefault;
        _cacheBudgetMB = 128;
        _parallax = YES;
        _wallpaperScaling = NSImageScaleProportionallyUpOrDown;
        _wallpaperClipping = YES;
        _wallpaperFillColor = @[@0, @0, @0, @1];
    }
    return self;
}

- (void)setAnimateFPS:(NSUInteger)animateFPS {
    _animateFPS = MIN(animateFPS, (NSUInteger)1000);  // config/mod.rs: `.min(1000)`
}

- (id)copyWithZone:(NSZone *)zone {
    IFBackgroundConfig *c = [[IFBackgroundConfig allocWithZone:zone] init];
    c.type = _type;
    c.path = _path;
    c.texture = _texture;
    c.mirrorTile = _mirrorTile;
    c.cacheShader = _cacheShader;
    c.transparentShader = _transparentShader;
    c.cacheBudgetMB = _cacheBudgetMB;
    c.animateFPS = _animateFPS;
    c.parallax = _parallax;
    c.inheritedWallpaper = _inheritedWallpaper;
    c.wallpaperScaling = _wallpaperScaling;
    c.wallpaperClipping = _wallpaperClipping;
    c.wallpaperFillColor = _wallpaperFillColor;
    return c;
}

+ (instancetype)configWithTypeString:(NSString *)type
                                path:(NSString *)path
                             texture:(NSString *)texture
                             warning:(NSString **)warning {
    IFBackgroundConfig *c = [IFBackgroundConfig new];
    if (warning) *warning = nil;
    if (!type) return c;  // no `type`: default, whatever else is set
    NSString *expandedPath = path.stringByExpandingTildeInPath;
    NSDictionary<NSString *, NSNumber *> *sourced = @{
        @"shader": @(IFBackgroundTypeShader),
        @"tile": @(IFBackgroundTypeTile),
        @"wallpaper": @(IFBackgroundTypeWallpaper)};
    if (sourced[type] && path) {
        c.type = sourced[type].integerValue;
        c.path = expandedPath;
        if (c.type == IFBackgroundTypeShader) c.texture = texture.stringByExpandingTildeInPath;
    } else if ([type isEqualToString:@"default"]) {
        c.type = IFBackgroundTypeDefault;
    } else if ([type isEqualToString:@"none"]) {
        c.type = IFBackgroundTypeNone;
    } else if (!path) {
        if (warning) *warning = [NSString stringWithFormat:@"config: [background] type=\"%@\" requires `path`, using default", type];
    } else {
        if (warning) *warning = [NSString stringWithFormat:@"config: [background] unknown type \"%@\", using default", type];
    }
    return c;
}
@end

// MARK: - Program

@interface IFBackgroundProgram ()
- (id<MTLCommandQueue>)commandQueue;
@end

@implementation IFBackgroundProgram {
    IFBGDeviceResources *_resources;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
    simd_float4 _wallpaperFill;
    // A pyramidal TIFF, as every program of one load shares it: the open file,
    // what `new_from_tiff` derived from it, and (in `_texture`) its fallback level.
    IFBGTiffSource *_tiff;
    IFBGTileLayout *_layout;
    NSUInteger _fallbackHoles;   // tiles of the fallback level that could not be decoded
    BOOL _fallbackTransparency;  // some texel of it is not opaque
    IFBackgroundProgram *_captureTwin;
    // This program's own chunk cache, made by its first frame.
    IFBGShaderChunks *_shaderChunks;
    IFBGTileChunks *_tileChunks;
    // Image size in pixels for tile / wallpaper / textured shader, else zero.
    // For a pyramidal TIFF: the size of its full-resolution level.
    CGSize _textureSize;
}

+ (instancetype)programWithConfig:(IFBackgroundConfig *)config device:(id<MTLDevice>)device {
    if (!device) device = MTLCreateSystemDefaultDevice();
    if (!device) device = MTLCopyAllDevices().firstObject;
    return [[IFBackgroundProgram alloc] initWithConfig:config device:device];
}

- (instancetype)initWithConfig:(IFBackgroundConfig *)config device:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _config = [config copy];
    _device = device;
    _resources = device ? [IFBGDeviceResources resourcesForDevice:device] : nil;
    if (!_resources) {
        _kind = IFBackgroundKindNone;
        _errorText = @"background: no Metal device";
        return self;
    }
    [self load];
    if (_kind != IFBackgroundKindNone && !_pipeline) {
        _kind = IFBackgroundKindNone;
        _errorText = _resources.builtinError ?: _errorText ?: @"background: pipeline creation failed";
    }
    return self;
}

// The dot grid, as a background of its own or as the fallback. Upstream
// `init_shader_bg` / `init_default_shader_bg` with DEFAULT_SHADER: it declares
// `u_camera` only, and honours `transparent_shader` like any other shader.
- (void)useDotGrid {
    _kind = IFBackgroundKindDotGrid;
    _pipeline = [_resources builtinPipeline:@"ifbg_dot_grid"];
    _texture = nil;
    _textureSize = CGSizeZero;
    _animated = NO;
    _transparent = _config.transparentShader;
}

- (id<MTLRenderPipelineState>)compileUserShader:(NSString *)source textured:(BOOL)textured error:(NSString **)error {
    NSString *translateError = nil;
    NSString *msl = IFBGTranslateGLSL(source, textured, &translateError);
    if (!msl) {
        if (error) *error = translateError;
        return nil;
    }
    NSError *nsError = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:msl options:DWMetalCompileOptions() error:&nsError];
    id<MTLFunction> fragment = [library newFunctionWithName:@"ifbg_user_fragment"];
    if (!fragment) {
        if (error) *error = IFBGCondenseDiagnostics(nsError.localizedDescription ?: @"no fragment function");
        return nil;
    }
    id<MTLRenderPipelineState> pipeline = [_resources pipelineWithFragment:fragment error:&nsError];
    if (!pipeline && error) *error = IFBGCondenseDiagnostics(nsError.localizedDescription ?: @"pipeline creation failed");
    return pipeline;
}

// Mirrors `init_background` and its helpers in upstream background.rs,
// including every fallback and the wording of each error.
- (void)load {
    NSString *path = _config.path.stringByExpandingTildeInPath;
    NSString *texturePath = _config.texture.stringByExpandingTildeInPath;
    switch (_config.type) {
        case IFBackgroundTypeNone:
            _kind = IFBackgroundKindNone;  // init_none_bg
            return;
        case IFBackgroundTypeDefault:
            [self useDotGrid];
            return;
        case IFBackgroundTypeTile:
        case IFBackgroundTypeWallpaper: {
            BOOL wallpaper = _config.type == IFBackgroundTypeWallpaper;
            if (!path) {
                [self useDotGrid];
                _errorText = [NSString stringWithFormat:@"config: [background] type=\"%@\" requires `path`, using default",
                                                        wallpaper ? @"wallpaper" : @"tile"];
                return;
            }
            if (IFBGIsTIFFPath(path) && !(wallpaper && _config.inheritedWallpaper)) {
                if (wallpaper) {
                    [self useDotGrid];
                    _errorText = [NSString stringWithFormat:@"wallpaper '%@': TIFF isn't supported in wallpaper mode (PNG/JPEG only) — use [background] type = \"tile\" for TIFF images", path];
                    return;
                }
                // tile_chunks_or_shader_fallback: a tiled pyramidal TIFF is drawn
                // from its levels chunk by chunk, or not at all.
                NSString *pyramidError = [self loadPyramid:path];
                if (pyramidError) {
                    [self useDotGrid];
                    _errorText = [NSString stringWithFormat:@"tile bg '%@': %@", path, pyramidError];
                }
                return;
            }
            NSString *imageError = nil;
            BOOL hasTransparency = NO;
            CGSize size = CGSizeZero;
            BOOL inherited = wallpaper && _config.inheritedWallpaper;
            id<MTLTexture> texture = IFBGLoadImage(_device, path, &size, inherited, inherited ? NULL : &hasTransparency, &imageError);
            NSString *fragment = wallpaper ? @"ifbg_wallpaper" : (_config.mirrorTile ? @"ifbg_tile_mirror" : @"ifbg_tile");
            id<MTLRenderPipelineState> pipeline = texture ? [_resources builtinPipeline:fragment] : nil;
            if (!texture || !pipeline) {
                [self useDotGrid];
                _errorText = imageError ?: [NSString stringWithFormat:@"background: %@ shader failed to compile", wallpaper ? @"wallpaper" : @"tile"];
                return;
            }
            _kind = wallpaper ? IFBackgroundKindWallpaper : IFBackgroundKindTile;
            _pipeline = pipeline;
            _texture = texture;
            _textureSize = size;
            _animated = NO;
            _transparent = hasTransparency && !inherited;
            if (inherited) {
                _wallpaperFill = simd_make_float4(0, 0, 0, 1);
                NSArray<NSNumber *> *fill = _config.wallpaperFillColor;
                if (fill.count >= 3) for (NSUInteger i = 0; i < 3; i++) {
                    double component = [fill[i] doubleValue];
                    _wallpaperFill[i] = isfinite(component) ? (float)fmin(fmax(component, 0.0), 1.0) : 0.0f;
                }
            }
            return;
        }
        case IFBackgroundTypeShader:
            break;
    }

    if (!path) {
        [self useDotGrid];
        _errorText = @"config: [background] type=\"shader\" requires `path`, using default";
        return;
    }
    NSString *readError = nil;
    NSString *source = IFBGReadText(path, &readError);

    if (texturePath) {
        // textured_shader_or_fallback: read, compile, then load the image; any
        // failure draws the dot grid.
        if (!source) {
            [self useDotGrid];
            _errorText = [NSString stringWithFormat:@"background shader '%@': %@", path, readError];
            return;
        }
        NSString *compileError = nil;
        id<MTLRenderPipelineState> pipeline = [self compileUserShader:source textured:YES error:&compileError];
        if (!pipeline) {
            [self useDotGrid];
            _errorText = [NSString stringWithFormat:@"background shader '%@': compile error: %@", path, compileError];
            return;
        }
        NSString *imageError = nil;
        CGSize size = CGSizeZero;
        id<MTLTexture> texture = IFBGLoadImage(_device, texturePath, &size, NO, NULL, &imageError);
        if (!texture) {
            [self useDotGrid];
            _errorText = imageError;
            return;
        }
        _kind = IFBackgroundKindTexturedShader;
        _pipeline = pipeline;
        _texture = texture;
        _textureSize = size;
        _animated = IFBGReferencesUniform(source, @"float", @"u_time");
        _transparent = _config.transparentShader;  // the texture's alpha does not decide
        return;
    }

    // shader_no_texture_dispatch
    if (source && IFBGReferencesUniform(source, @"sampler2D", @"tex")) {
        [self useDotGrid];
        _errorText = [NSString stringWithFormat:
            @"background shader '%@': samples `tex` but no `texture` is set — add a `texture` path under [background]", path];
        return;
    }
    // init_shader_bg, or with `cache_shader` shader_chunks_or_live first.
    if (!source) {
        [self useDotGrid];
        _errorText = [NSString stringWithFormat:@"background shader '%@': %@", path, readError];
        return;
    }
    // try_init_shader_chunks: `cache_shader` bakes a shader that is a rigid
    // function of the canvas, one that reads `u_camera` and neither `u_time`
    // nor `u_zoom`. A shader without `u_camera` is fixed to the screen, and
    // baking it into canvas chunks would make it scroll. Every other shader is
    // drawn live, and so is every shader under `transparent_shader`: a chunk
    // cannot carry transparency.
    BOOL bake = _config.cacheShader && !_config.transparentShader && IFBGReferencesUniform(source, @"vec2", @"u_camera") &&
                !IFBGReferencesUniform(source, @"float", @"u_time") && !IFBGReferencesUniform(source, @"float", @"u_zoom");
    NSString *compileError = nil;
    id<MTLRenderPipelineState> pipeline = [self compileUserShader:source textured:NO error:&compileError];
    if (!pipeline) {
        [self useDotGrid];
        // try_init_shader_chunks names the file, init_shader_bg does not.
        _errorText = bake ? [NSString stringWithFormat:@"background shader '%@': compile error: %@", path, compileError]
                          : [NSString stringWithFormat:@"background shader: compile error: %@", compileError];
        return;
    }
    _kind = IFBackgroundKindShader;
    _pipeline = pipeline;
    _animated = IFBGReferencesUniform(source, @"float", @"u_time");
    _transparent = _config.transparentShader;
    if (!bake) return;
    // The shader itself stays compiled: the bake draws through it, and so does
    // a capture.
    if ([_resources chunkPipeline]) {
        _cache = IFBackgroundCacheShaderBake;
    } else {
        _errorText = [NSString stringWithFormat:@"background shader '%@': chunk_bg compile error: the built-in chunk shader could not be built", path];
    }
}

// init_tile_chunks_bg and BgChunkCache::new_from_tiff: opens the file, derives
// the chunk layout and decodes the whole fallback level. Returns upstream's
// message (what follows its `tile bg '<path>': `), or nil when the program is
// ready. The decode pool is each output's own and starts with its first frame.
- (NSString *)loadPyramid:(NSString *)path {
    NSString *error = nil;
    IFBGTiffSource *source = [IFBGTiffSource sourceWithPath:path error:&error];
    if (!source) return error;
    if (![_resources chunkPipeline]) return @"chunk_bg shader compile: the built-in chunk shader could not be built";
    // The fallback plane reuses tile_bg.glsl, never its mirrored variant:
    // `mirror_tile` is a no-op on a pyramidal TIFF.
    id<MTLRenderPipelineState> plane = [_resources builtinPipeline:@"ifbg_tile"];
    if (!plane) return @"tile_bg shader compile failed";
    IFBGTileLayout *layout = IFBGTileLayoutMake(source, &error);
    if (!layout) return error;
    IFBGTiffBlock *fallback = [source readWholeLevel:layout->lodCount - 1 error:&error];
    if (!fallback) return error;
    id<MTLTexture> texture = IFBGUploadBlock(_device, fallback);
    if (!texture) {
        return [NSString stringWithFormat:@"fallback texture upload: a texture of %u×%u pixels could not be made", fallback.width, fallback.height];
    }
    _kind = IFBackgroundKindTile;
    _cache = IFBackgroundCacheTileChunks;
    _pipeline = plane;
    _texture = texture;
    _textureSize = CGSizeMake(layout->imageW, layout->imageH);  // `u_tile_size`: the wrap period, not the fallback level's size
    _tiff = source;
    _layout = layout;
    _fallbackHoles = fallback.failedTileCount;
    _fallbackTransparency = fallback.hasTransparency;
    _animated = NO;
    // Opaque whatever the file's alpha: chunk_bg.glsl writes alpha 1, and the
    // fallback plane claims its whole area opaque.
    _transparent = NO;
    return nil;
}

/// The uniform mapping, including the macOS wallpaper extension below.
- (IFBGUniforms)uniformsForFrame:(IFBackgroundFrame)f {
    IFBGUniforms u;
    memset(&u, 0, sizeof u);
    double zoom = (isfinite(f.zoom) && f.zoom > 0) ? f.zoom : 1.0;
    double scale = (isfinite(f.scale) && f.scale > 0) ? f.scale : 1.0;
    long outW, outH;
    IFBGPixelSize(f, &outW, &outH, NULL, NULL);
    outW = MAX(outW, 1L);
    outH = MAX(outH, 1L);

    // background.rs update(): `Uniform::new("u_camera", (f.camera.x as f32, f.camera.y as f32))`
    u.camera = simd_make_float2((float)f.cameraX, (float)f.cameraY);
    u.time = (float)f.time;  // `state.start_time.elapsed().as_secs_f32()`
    u.zoom = (float)zoom;    // `Uniform::new("u_zoom", f.zoom as f32)`
    u.alpha = 1.0f;          // element alpha, always 1.0 for a background
    u.opaque = _transparent ? 0.0f : 1.0f;
    u.texture_size = simd_make_float2((float)_textureSize.width, (float)_textureSize.height);

    if (_kind == IFBackgroundKindWallpaper) {
        // Upstream wallpaper_cover_src(), or NSWorkspace's centred fit/fill,
        // stretch or unscaled still image. Fill is opaque outside image UVs.
        double tw = MAX(_textureSize.width, 1.0), th = MAX(_textureSize.height, 1.0);
        double factorX = (double)outW / tw, factorY = (double)outH / th;
        double imageScale = MAX(factorX, factorY);
        BOOL stretch = NO;
        if (_config.inheritedWallpaper) {
            switch (_config.wallpaperScaling) {
                case NSImageScaleAxesIndependently:
                    stretch = YES;
                    break;
                case NSImageScaleNone:
                    imageScale = 1.0;
                    break;
                case NSImageScaleProportionallyDown:
                    imageScale = MIN(_config.wallpaperClipping ? MAX(factorX, factorY) : MIN(factorX, factorY), 1.0);
                    break;
                case NSImageScaleProportionallyUpOrDown:
                default:
                    imageScale = _config.wallpaperClipping ? MAX(factorX, factorY) : MIN(factorX, factorY);
                    break;
            }
        }
        double baseX = stretch ? 1.0 : factorX / imageScale;
        double baseY = stretch ? 1.0 : factorY / imageScale;
        double cropX = baseX, cropY = baseY, panX = 0.0, panY = 0.0;
        if (_config.parallax) {
            // A shallow, bounded depth: 4..12% overscan changes smoothly with
            // zoom. Camera movement uses only its overscan margin, so a cover
            // image cannot run out, repeat, or expose clamped border pixels.
            // Use the world centre to keep a centred zoom from panning as well.
            double overscan = 1.04 + 0.08 * (2.0 / M_PI) * atan(zoom);
            cropX /= overscan;
            cropY /= overscan;
            double cameraX = isfinite(f.cameraX) ? f.cameraX : 0.0;
            double cameraY = isfinite(f.cameraY) ? f.cameraY : 0.0;
            double centreX = cameraX / (double)outW + 0.5 * (1.0 / zoom - 1.0);
            double centreY = cameraY / (double)outH + 0.5 * (1.0 / zoom - 1.0);
            panX = tanh(2.0 * centreX) * (baseX - cropX) * 0.5;
            panY = tanh(2.0 * centreY) * (baseY - cropY) * 0.5;
        }
        u.src_origin = simd_make_float2((float)((1.0 - cropX) * 0.5 + panX), (float)((1.0 - cropY) * 0.5 + panY));
        u.src_size = simd_make_float2((float)cropX, (float)cropY);
        u.wallpaper_fill = _wallpaperFill;
        u.dest_px = simd_make_float2((float)MAX(1.0, round((double)outW * scale)), (float)MAX(1.0, round((double)outH * scale)));
        u.size = simd_make_float2((float)outW, (float)outH);
        return u;
    }

    // background.rs update_background_element():
    //   canvas_w = (output_size.w as f64 / cur_zoom).ceil() as i32
    double canvasW = ceil((double)outW / zoom), canvasH = ceil((double)outH / zoom);
    canvasW = MIN(MAX(canvasW, 1.0), 2147483647.0);
    canvasH = MIN(MAX(canvasH, 1.0), 2147483647.0);
    // `size` (PixelShaderElement area) and `u_output_size` both carry the canvas area.
    u.size = simd_make_float2((float)canvasW, (float)canvasH);
    // The element's physical extent: geometry(scale) rounds canvas * scale,
    // RescaleRenderElement then rounds that * zoom. v_coords runs 0..1 over it.
    u.dest_px = simd_make_float2((float)MAX(1.0, round(round(canvasW * scale) * zoom)),
                                 (float)MAX(1.0, round(round(canvasH * scale) * zoom)));
    u.src_origin = simd_make_float2(0, 0);
    u.src_size = simd_make_float2(1, 1);
    return u;
}

// Draws the frame into a render pass the caller already opened, so that the
// compositor can put the background first in its own pass.
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder {
    if (_kind == IFBackgroundKindNone || !_pipeline) return NO;
    if (_cache != IFBackgroundCacheNone && [self encodeChunksOfFrame:frame inEncoder:encoder]) return YES;
    IFBGUniforms u = [self uniformsForFrame:frame];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder setFragmentTexture:_texture ?: _resources.placeholderTexture atIndex:0];
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    return YES;
}

// MARK: Chunk caches

// The fallback plane of a pyramidal TIFF, tile_chunks.rs
// `chunk_render_elements`: tile_bg.glsl over the visible rectangle, sampling
// the fallback level with the full-resolution image as the wrap period. Unlike
// the chunks above it, it follows the unrounded camera.
- (IFBGUniforms)planeUniformsForFrame:(IFBackgroundFrame)f {
    IFBGChunkView v = IFBGChunkViewMake(f);
    IFBGUniforms u;
    memset(&u, 0, sizeof u);
    u.camera = simd_make_float2((float)f.cameraX, (float)f.cameraY);  // `Uniform::new("u_camera", (camera.x as f32, camera.y as f32))`
    u.texture_size = simd_make_float2((float)_textureSize.width, (float)_textureSize.height);  // `u_tile_size`: image_dims
    u.size = simd_make_float2((float)MAX(v.viewW, 1L), (float)MAX(v.viewH, 1L));  // `u_output_size`: (canvas_w, canvas_h)
    // The element's area is the visible rectangle at the output's origin.
    simd_float4 dst = IFBGChunkDst(0, 0, MAX(v.viewW, 1L), MAX(v.viewH, 1L), &v);
    u.dest_px = simd_make_float2(fmaxf(dst.z, 1.0f), fmaxf(dst.w, 1.0f));
    u.src_size = simd_make_float2(1, 1);
    u.time = (float)f.time;
    u.zoom = (float)v.zoom;
    u.alpha = 1.0f;
    u.opaque = 1.0f;
    return u;
}

// The chunk work of one frame and the quads it draws, bottom first: what both
// the draw below and -chunkGenerationForFrame: ask, and each cache answers once
// per frame. nil when the live path draws instead.
- (nullable NSArray<IFBGChunkDraw *> *)chunkDrawsForFrame:(IFBackgroundFrame)frame {
    NSUInteger pxW, pxH;
    IFBGPixelSize(frame, NULL, NULL, &pxW, &pxH);
    if (pxW == 0 || pxH == 0 || ![_resources chunkPipeline]) return nil;
    // `state.config.background.cache_budget_mb as u64 * 1024 * 1024`
    uint64_t budget = (uint64_t)_config.cacheBudgetMB * 1024 * 1024;
    if (_cache == IFBackgroundCacheShaderBake) {
        // The chunks are baked for one output scale: at another the cache
        // starts again (upstream drops an output's cache when its scale changes).
        double scale = (isfinite(frame.scale) && frame.scale > 0) ? frame.scale : 1.0;
        if (!_shaderChunks || _shaderChunks.scale != scale) {
            _shaderChunks = [[IFBGShaderChunks alloc] initWithResources:_resources shader:_pipeline scale:scale budget:budget];
        }
        return [_shaderChunks drawsForFrame:frame];
    }
    if (!_tiff || !_layout) return nil;
    if (!_tileChunks) {
        _tileChunks = [[IFBGTileChunks alloc] initWithDevice:_device source:_tiff layout:_layout budget:budget];
        _tileChunks.readyHandler = _chunkReadyHandler;
    }
    return [_tileChunks drawsForFrame:frame] ?: @[];
}

- (uint64_t)chunkGenerationForFrame:(IFBackgroundFrame)frame {
    if (_cache == IFBackgroundCacheNone || _kind == IFBackgroundKindNone || !_pipeline) return 0;
    [self chunkDrawsForFrame:frame];
    return _shaderChunks.generation + _tileChunks.generation;
}

// One frame of a cached program: its chunk cache decides what is drawn, after
// baking or uploading what this frame may. NO when nothing was drawn and the
// live path below should draw instead (no cache could be made, or a baked
// shader's coarse cover could not be baked).
- (BOOL)encodeChunksOfFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder {
    id<MTLRenderPipelineState> quad = [_resources chunkPipeline];
    NSArray<IFBGChunkDraw *> *draws = [self chunkDrawsForFrame:frame];
    if (!draws) return NO;
    if (_cache == IFBackgroundCacheTileChunks) {
        // Bottom: the fallback plane, one draw whatever the number of image
        // instances in view. No region of the output is ever blank.
        IFBGUniforms u = [self planeUniformsForFrame:frame];
        [encoder setRenderPipelineState:_pipeline];
        [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
        [encoder setFragmentTexture:_texture atIndex:0];
        [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    if (!draws.count) return YES;
    [encoder setRenderPipelineState:quad];
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    for (IFBGChunkDraw *draw in draws) {
        [encoder setVertexBytes:&draw->uniforms length:sizeof draw->uniforms atIndex:0];
        [encoder setFragmentBytes:&draw->uniforms length:sizeof draw->uniforms atIndex:0];
        [encoder setFragmentTexture:draw->texture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    return YES;
}

// Everything `base` loaded, and no chunk cache yet.
- (instancetype)initSharing:(IFBackgroundProgram *)base {
    if (!(self = [super init])) return nil;
    _config = base->_config;
    _device = base->_device;
    _resources = base->_resources;
    _kind = base->_kind;
    _errorText = base->_errorText;
    _animated = base->_animated;
    _transparent = base->_transparent;
    _textureSize = base->_textureSize;
    _pipeline = base->_pipeline;
    _texture = base->_texture;
    _wallpaperFill = base->_wallpaperFill;
    _cache = base->_cache;
    _tiff = base->_tiff;
    _layout = base->_layout;
    _fallbackHoles = base->_fallbackHoles;
    _fallbackTransparency = base->_fallbackTransparency;
    return self;
}

- (IFBackgroundProgram *)programForOutput {
    if (_cache == IFBackgroundCacheNone) return self;
    return [[IFBackgroundProgram alloc] initSharing:self];
}

// capture_background.rs `CaptureBackground::prepare`: a capture is a virtual
// viewport, so it never draws from an output's chunk cache. `shader_bg` hands
// it the compiled shader itself, `tiff_tile_bg` one level of the pyramid as a
// plain tile.
- (IFBackgroundProgram *)captureProgram {
    if (_cache == IFBackgroundCacheNone) return self;
    @synchronized(self) {
        if (_captureTwin) return _captureTwin;
        IFBackgroundProgram *twin = [[IFBackgroundProgram alloc] initSharing:self];
        twin->_cache = IFBackgroundCacheNone;
        if (_cache == IFBackgroundCacheTileChunks) {
            // The finest level that fits one bounded texture, else the coarsest,
            // among every page of the file; stretched over the full-resolution
            // extent by `_textureSize`, so it lands where the chunks would.
            // capture_background.rs prepare_tiff: `whole_lod(&lods, TIFF_LOD_CAP)`, and a level
            // past the whole-decode limit leaves the capture without a background.
            NSUInteger count = _tiff.levelCount;
            IFBGTiffLevel levels[kIFBGMaxTileLODs];
            for (NSUInteger i = 0; i < count && i < kIFBGMaxTileLODs; i++) levels[i] = [_tiff levelAtIndex:i];
            NSString *whole = nil;
            NSUInteger lod = IFBGTiffWholeLevel(levels, MIN(count, (NSUInteger)kIFBGMaxTileLODs), kIFBGFallbackMaxDim, &whole);
            if (lod == NSNotFound) {
                NSLog(@"background: capture background '%@': %@", _config.path, whole);
                twin->_kind = IFBackgroundKindNone;
                twin->_pipeline = nil;
                twin->_texture = nil;
            } else if (lod == (NSUInteger)_layout->lodCount - 1 && _fallbackHoles == 0) {
                // The fallback plane's level, whole: the texture already loaded.
                twin->_transparent = _fallbackTransparency;
            } else {
                // `source.read_block(lod_idx, 0, 0, n).ok()?`: any tile that
                // cannot be decoded leaves the capture without a background.
                IFBGTiffLevel level = [_tiff levelAtIndex:lod];
                uint32_t across = (level.imageWidth + level.tileWidth - 1) / level.tileWidth;
                uint32_t down = (level.imageHeight + level.tileHeight - 1) / level.tileHeight;
                IFBGTiffBlock *block = [_tiff readBlockAtLevel:lod gx:0 gy:0 aggregation:MAX(across, down) error:NULL];
                id<MTLTexture> texture = block ? IFBGUploadBlock(_device, block) : nil;
                if (texture) {
                    twin->_texture = texture;
                    twin->_transparent = block.hasTransparency;
                } else {
                    twin->_kind = IFBackgroundKindNone;
                    twin->_pipeline = nil;
                    twin->_texture = nil;
                }
            }
        }
        _captureTwin = twin;
        return twin;
    }
}

- (void)setChunkReadyHandler:(dispatch_block_t)handler {
    _chunkReadyHandler = [handler copy];
    _tileChunks.readyHandler = _chunkReadyHandler;
}

- (NSUInteger)pendingChunkCount {
    return _shaderChunks.pendingCount + _tileChunks.pendingCount;
}

- (void)shrinkChunkCache {
    [_shaderChunks shrink];
    [_tileChunks shrink];
}

- (id<MTLCommandQueue>)commandQueue {
    return _resources.queue;
}
@end
