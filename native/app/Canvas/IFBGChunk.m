// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: the chunk record classes both chunk
// caches share (IFBGChunk, IFBGChunkDraw). The shared helpers (a frame's view
// in upstream's integers, the pixels a chunk covers, LOD choice, LRU eviction
// and the upload of a decoded block) are static inline in
// IFBackground+Private.h - see IFBackground.h and
// docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/tile_chunks.rs
// (pick_lod, evict_lru_to_budget), src/render/elements.rs (tile_corner_round
// and corner_round_rect: the pixels a chunk covers) and src/canvas.rs
// (visible_canvas_rect); the chunk-cache section of IFBackground+Private.h
// carries the full list.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackground+Private.h"

#include <math.h>

@implementation IFBGChunk
@end
@implementation IFBGChunkDraw
@end

