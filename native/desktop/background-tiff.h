// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tiled pyramidal TIFF source and decode pool for the canvas background's
// gigapixel path. Part of the background module (background.h); no dependency
// on the rest of the app, and none on Metal.
//
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/render/tile_chunks_tiff.rs (TiffSource: scan_lods, read_lod_metadata,
// read_block, read_whole_lod and the wording of every refusal) and
// src/render/tile_worker.rs (WorkerPool: six decoders, one FIFO queue, a
// response list, a wake-up after every response, drain_pending, shutdown).
// Upstream decodes with the `tiff` crate; here the container is walked by this
// file and each tile's compressed bytes are decoded by ImageIO
// (BACKGROUND-NOTES.md, section 17).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Upstream `LodMetadata`: one page of the file.
typedef struct IFBGTiffLevel {
    uint32_t imageWidth, imageHeight;
    uint32_t tileWidth, tileHeight;
    BOOL hasAlpha;  ///< RGBA8 (four samples); otherwise RGB8
} IFBGTiffLevel;

/// Upstream `DecodedTile`: tightly packed RGBA8, `width * height * 4` bytes.
@interface IFBGTiffBlock : NSObject
@property (nonatomic, readonly) NSData *rgba;
@property (nonatomic, readonly) uint32_t width, height;
/// Some alpha sample is below 255.
@property (nonatomic, readonly) BOOL hasTransparency;
/// `read_whole_lod` only: tiles that could not be decoded and were left zeroed.
@property (nonatomic, readonly) NSUInteger failedTileCount;
@end

/// Upstream `TiffSource`. Immutable after it is opened; every method may be
/// called from any thread, and from several at once.
@interface IFBGTiffSource : NSObject

/// `TiffSource::open`: every page of the file must be a tiled, chunky,
/// RGB8 or RGBA8 image. On refusal returns nil and sets `*error` to
/// upstream's message (what follows its `tile bg '<path>': ` prefix).
+ (nullable instancetype)sourceWithPath:(NSString *)path error:(NSString *_Nullable *_Nullable)error;

@property (nonatomic, readonly, copy) NSString *path;
/// `lods()`: page 0 is full resolution.
@property (nonatomic, readonly) NSUInteger levelCount;
- (IFBGTiffLevel)levelAtIndex:(NSUInteger)index;

/// `read_block`: the `n x n` block of tiles at block index `(gx, gy)` of
/// `level`, cropped at the image's right and bottom edges. Any tile that
/// cannot be decoded fails the block.
- (nullable IFBGTiffBlock *)readBlockAtLevel:(NSUInteger)level
                                          gx:(uint32_t)gx
                                          gy:(uint32_t)gy
                                 aggregation:(uint32_t)n
                                       error:(NSString *_Nullable *_Nullable)error;

/// `read_whole_lod`: the whole level, with a tile that cannot be decoded left
/// zeroed (opaque black in an RGB8 file). Fails only when every tile did.
- (nullable IFBGTiffBlock *)readWholeLevel:(NSUInteger)level error:(NSString *_Nullable *_Nullable)error;
@end

/// Upstream `TileResponse`.
@interface IFBGTileResponse : NSObject
@property (nonatomic, readonly) uint32_t level, cx, cy;
@property (nonatomic, readonly, nullable) IFBGTiffBlock *block;  ///< nil: the decode failed
@property (nonatomic, readonly, copy, nullable) NSString *error;
@end

/// Upstream `WorkerPool`: at most six decodes at a time, requests served in
/// the order they were queued. The pool keeps no thread while it has nothing
/// to decode.
@interface IFBGTileWorkerPool : NSObject
/// `wake` is called on an arbitrary thread after each response is queued
/// (upstream's `loop_signal.wakeup()`), and never after `-shutdown`.
- (instancetype)initWithSource:(IFBGTiffSource *)source wake:(dispatch_block_t)wake;
- (void)enqueueLevel:(uint32_t)level cx:(uint32_t)cx cy:(uint32_t)cy aggregation:(uint32_t)aggregation;
/// `try_recv`: the oldest response waiting, or nil.
- (nullable IFBGTileResponse *)tryReceive;
/// `drain_pending`: forgets every request no decode has started on.
- (void)drainPending;
/// Upstream's `Drop`: nothing more is decoded or delivered. A decode already
/// running finishes by itself and its result is discarded. Also done when the
/// pool is released.
- (void)shutdown;
/// Requests queued, being decoded, or decoded and not yet received (diagnostics).
@property (nonatomic, readonly) NSUInteger outstandingCount;
@end

NS_ASSUME_NONNULL_END
