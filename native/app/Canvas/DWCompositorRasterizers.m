// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — CPU rasterisers: text on CoreText, title bars, stand-in
// bodies and labels, and the error bar. See IFCompositor.h and
// docs/native/app/Canvas/COMPOSITOR-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"

#import <CoreText/CoreText.h>

// MARK: - Text (text.rs, on CoreText instead of cosmic-text)

// text.rs `weight_of`, as CoreText's -1..1 weight trait (the NSFontWeight
// values for CSS weights 100..900).
static CGFloat IFCWeightTrait(IFCompositorFontWeight weight) {
    switch (weight) {
        case IFCompositorFontWeightThin: return -0.8;
        case IFCompositorFontWeightExtraLight: return -0.6;
        case IFCompositorFontWeightLight: return -0.4;
        case IFCompositorFontWeightNormal: return 0.0;
        case IFCompositorFontWeightMedium: return 0.23;
        case IFCompositorFontWeightSemiBold: return 0.3;
        case IFCompositorFontWeightBold: return 0.4;
        case IFCompositorFontWeightExtraBold: return 0.56;
        case IFCompositorFontWeightBlack: return 0.62;
    }
    return 0.0;
}

// text.rs `family_of` + fontconfig's behaviour: the named family when it is
// installed, otherwise a generic sans (upstream: "otherwise a generic sans is
// substituted") — here the system UI font.
static CTFontRef IFCCreateFont(NSString *family, double px, IFCompositorFontWeight weight) CF_RETURNS_RETAINED {
    NSDictionary *traits = @{(__bridge id)kCTFontWeightTrait: @(IFCWeightTrait(weight))};
    NSString *name = family ?: @"";
    NSString *lower = name.lowercaseString;
    CTFontUIFontType generic = kCTFontUIFontSystem;
    if ([lower isEqualToString:@"monospace"]) {
        generic = kCTFontUIFontUserFixedPitch;
        name = @"";
    } else if ([lower isEqualToString:@"sans-serif"]) {
        name = @"";
    } else if ([lower isEqualToString:@"serif"]) {
        name = @"Times New Roman";
    } else if ([lower isEqualToString:@"cursive"]) {
        name = @"Apple Chancery";
    } else if ([lower isEqualToString:@"fantasy"]) {
        name = @"Papyrus";
    }
    CTFontRef font = NULL;
    if (name.length) {
        NSDictionary *attributes = @{(__bridge id)kCTFontFamilyNameAttribute: name, (__bridge id)kCTFontTraitsAttribute: traits};
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
        font = CTFontCreateWithFontDescriptor(descriptor, (CGFloat)px, NULL);
        CFRelease(descriptor);
        NSString *got = font ? CFBridgingRelease(CTFontCopyFamilyName(font)) : nil;
        if (!got || [got caseInsensitiveCompare:name] != NSOrderedSame) {
            // CoreText substituted another family: the request is not installed.
            if (font) CFRelease(font);
            font = NULL;
        }
    }
    if (!font) {
        CTFontRef base = CTFontCreateUIFontForLanguage(generic, (CGFloat)px, NULL);
        CTFontDescriptorRef baseDescriptor = CTFontCopyFontDescriptor(base);
        NSDictionary *attributes = @{(__bridge id)kCTFontTraitsAttribute: traits};
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(baseDescriptor, (__bridge CFDictionaryRef)attributes);
        font = CTFontCreateWithFontDescriptor(descriptor, (CGFloat)px, NULL);
        CFRelease(descriptor);
        CFRelease(baseDescriptor);
        CFRelease(base);
    }
    return font;
}

// text.rs `shape_line`: one unwrapped line.
static CTLineRef IFCCreateLine(NSString *text, CTFontRef font) CF_RETURNS_RETAINED {
    NSDictionary *attributes = @{(__bridge id)kCTFontAttributeName: (__bridge id)font,
                                 (__bridge id)kCTForegroundColorFromContextAttributeName: @YES};
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
}

// text.rs `measure`: pixel width, `ceil`ed; 0 for empty text.
static long IFCMeasure(NSString *text, CTFontRef font) {
    if (!text.length) return 0;
    CTLineRef line = IFCCreateLine(text, font);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return IFCCeil(width);
}

// text.rs `fit_text`: tail-truncate with an ellipsis; the largest prefix (in
// Unicode scalar values, Rust `char`s) whose `prefix + …` still fits.
static NSString *IFCFitText(NSString *text, CTFontRef font, long maxWidth, long *outWidth) {
    long full = IFCMeasure(text, font);
    if (full <= maxWidth) {
        *outWidth = full;
        return text;
    }
    NSString *ellipsis = @"…";
    if (IFCMeasure(ellipsis, font) > maxWidth) {
        *outWidth = 0;
        return @"";
    }
    NSData *utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint8_t *scalars = utf32.bytes;
    NSUInteger count = utf32.length / 4;
    NSString * (^candidate)(NSUInteger) = ^NSString *(NSUInteger n) {
        NSString *prefix = [[NSString alloc] initWithBytes:scalars length:n * 4 encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
        return [prefix stringByAppendingString:ellipsis];
    };
    NSUInteger lo = 0, hi = count;
    while (lo + 1 < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (IFCMeasure(candidate(mid), font) <= maxWidth) lo = mid;
        else hi = mid;
    }
    NSString *result = candidate(lo);
    *outWidth = IFCMeasure(result, font);
    return result;
}

// text.rs `rasterize_into`: alpha-composite `text` onto an RGBA8 buffer,
// vertically centred within `bufH` by the line's ascent and descent, with
// upstream's per-pixel blend. The glyph coverage comes from CoreText.
static void IFCRasterizeInto(uint8_t *pixels, long bufW, long bufH, NSString *text, CTFontRef font, float size,
                             IFCompositorColor color, long originX) {
    if (!text.length || bufW <= 0 || bufH <= 0) return;
    uint8_t *coverage = calloc((size_t)bufW * (size_t)bufH, 1);
    if (!coverage) return;
    CGContextRef context = CGBitmapContextCreate(coverage, (size_t)bufW, (size_t)bufH, 8, (size_t)bufW, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context) {
        free(coverage);
        return;
    }
    CGContextSetShouldAntialias(context, true);
    CGContextSetAllowsFontSmoothing(context, false);
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetAllowsFontSubpixelPositioning(context, true);
    CGContextSetShouldSubpixelPositionFonts(context, true);
    CGContextSetGrayFillColor(context, 1.0, 1.0);

    CTLineRef line = IFCCreateLine(text, font);
    CGFloat lineAscent = 0, lineDescent = 0;
    CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, NULL);
    // `(ascent, descent)` of the laid-out line, else `(size * 0.8, size * 0.2)`.
    float ascent = (float)lineAscent, descent = (float)lineDescent;
    if (!(ascent + descent > 0.0f)) {
        ascent = size * 0.8f;
        descent = size * 0.2f;
    }
    // baseline = ((buf_h as f32 - (ascent + descent)) / 2.0 + ascent).round() as i32
    long baseline = IFCRound((double)(((float)bufH - (ascent + descent)) / 2.0f + ascent));
    // Core Graphics counts rows from the bottom.
    CGContextSetTextPosition(context, (CGFloat)originX, (CGFloat)(bufH - baseline));
    CTLineDraw(line, context);
    CFRelease(line);
    CGContextRelease(context);

    double colorAlpha = (double)color.a / 255.0;
    for (long y = 0; y < bufH; y++) {
        for (long x = 0; x < bufW; x++) {
            uint8_t c = coverage[y * bufW + x];
            if (!c) continue;
            double a = (double)c / 255.0 * colorAlpha;
            if (a <= 0.0) continue;
            uint8_t *p = pixels + (y * bufW + x) * 4;
            double inv = 1.0 - a;
            p[0] = IFCU8((double)color.r * a + (double)p[0] * inv);
            p[1] = IFCU8((double)color.g * a + (double)p[1] * inv);
            p[2] = IFCU8((double)color.b * a + (double)p[2] * inv);
            p[3] = IFCU8((double)p[3] + a * 255.0 * (1.0 - (double)p[3] / 255.0));
        }
    }
    free(coverage);
}

// MARK: - Chrome rasterisers (decorations.rs)

// Points -> logical pixels (96 dpi).
static const float kIFCPtToPx = 4.0f / 3.0f;
// decorations.rs constants.
static const long kIFCCloseBtnRightPad = 8;
static const long kIFCTitleTextGap = 6;
static const double kIFCCloseBtnStroke = 0.05;
// suspended.rs constant.
static const long kIFCLabelSidePad = 24;

// decorations.rs `corner_alpha_at`: top-left and top-right arcs.
static double IFCCornerAlphaAt(long x, long y, long w, double r) {
    if (r <= 0.0) return 1.0;
    double px = (double)x + 0.5, py = (double)y + 0.5;
    if (px < r && py < r) {
        double dx = r - px, dy = r - py;
        double dist = sqrt(dx * dx + dy * dy);
        double t = fmin(fmax(dist - r + 0.5, 0.0), 1.0);
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }
    double rightEdge = (double)w;
    if (px > rightEdge - r && py < r) {
        double dx = px - (rightEdge - r), dy = r - py;
        double dist = sqrt(dx * dx + dy * dy);
        double t = fmin(fmax(dist - r + 0.5, 0.0), 1.0);
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }
    return 1.0;
}

// decorations.rs `body_corner_alpha_at`: bottom corners only.
static double IFCBodyCornerAlphaAt(long x, long y, long w, long h, double r) {
    if (r <= 0.0) return 1.0;
    double px = (double)x + 0.5, py = (double)y + 0.5;
    double cx, cy;
    if (px < r) cx = r;
    else if (px > (double)w - r) cx = (double)w - r;
    else return 1.0;
    if (py > (double)h - r) cy = (double)h - r;
    else return 1.0;
    double dx = px - cx, dy = py - cy;
    double dist = sqrt(dx * dx + dy * dy);
    double t = fmin(fmax(dist - r + 0.5, 0.0), 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

// The straight-alpha blend `draw_line` and `draw_filled_circle` share.
static inline void IFCBlendPixel(uint8_t *pixels, long length, long index, IFCompositorColor color, double coverage) {
    // Upstream indexes with `as usize` and checks only `idx + 3 < len`: a
    // negative index wraps out of range, a column past the stride wraps into
    // the next row.
    if (index < 0 || index + 3 >= length) return;
    double a = fmin((double)color.a / 255.0 * coverage, 1.0);
    double inv = 1.0 - a;
    uint8_t *p = pixels + index;
    p[0] = IFCU8((double)color.r * a + (double)p[0] * inv);
    p[1] = IFCU8((double)color.g * a + (double)p[1] * inv);
    p[2] = IFCU8((double)color.b * a + (double)p[2] * inv);
    p[3] = IFCU8((double)p[3] + a * 255.0 * (1.0 - (double)p[3] / 255.0));
}

// decorations.rs `draw_line`.
static void IFCDrawLine(uint8_t *pixels, long length, long stride, long x0, long y0, long x1, long y1,
                        IFCompositorColor color, double lineWidth) {
    long pad = IFCCeil(lineWidth * 0.5 + 1.0);
    long minX = MIN(x0, x1) - pad, maxX = MAX(x0, x1) + pad;
    long minY = MIN(y0, y1) - pad, maxY = MAX(y0, y1) + pad;
    double dx = (double)(x1 - x0), dy = (double)(y1 - y0);
    double len = sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    for (long py = minY; py <= maxY; py++) {
        for (long px = minX; px <= maxX; px++) {
            double t = (((double)px - (double)x0) * dx + ((double)py - (double)y0) * dy) / (len * len);
            t = fmin(fmax(t, 0.0), 1.0);
            double projX = (double)x0 + t * dx, projY = (double)y0 + t * dy;
            double dist = sqrt(pow((double)px - projX, 2) + pow((double)py - projY, 2));
            double aa = fmin(fmax(1.0 - fmax(dist - lineWidth * 0.5, 0.0) / 0.8, 0.0), 1.0);
            if (aa > 0.0) IFCBlendPixel(pixels, length, (py * stride + px) * 4, color, aa);
        }
    }
}

// decorations.rs `draw_filled_circle`.
static void IFCDrawFilledCircle(uint8_t *pixels, long length, long stride, double cx, double cy, double r, IFCompositorColor color) {
    long height = length / (stride * 4);
    long xMin = IFCTrunc(fmax(floor(cx - r - 1.0), 0.0));
    long xMax = IFCTrunc(fmin(ceil(cx + r + 1.0), (double)stride));
    long yMin = IFCTrunc(fmax(floor(cy - r - 1.0), 0.0));
    long yMax = IFCTrunc(fmin(ceil(cy + r + 1.0), (double)height));
    for (long py = yMin; py < yMax; py++) {
        for (long px = xMin; px < xMax; px++) {
            double dx = (double)px + 0.5 - cx, dy = (double)py + 0.5 - cy;
            double dist = sqrt(dx * dx + dy * dy);
            double cov = fmin(fmax(r + 0.5 - dist, 0.0), 1.0);
            if (cov <= 0.0) continue;
            IFCBlendPixel(pixels, length, (py * stride + px) * 4, color, cov);
        }
    }
}

// decorations.rs `render_title_bar`. Returns RGBA8 (`Abgr8888`) bytes of
// `*outW` x `*outH` pixels; the buffer scale is `scale`.
NSMutableData *IFCRenderTitleBar(long width, long scale, NSString *title, BOOL pinned, long cornerRadius,
                                        IFCompositorChromeStyle *style, long *outW, long *outH) {
    long s = MAX(scale, 1L);
    long h = (long)style.titleBarHeight * s;
    long w = MAX(width, 1L) * s;
    if (h <= 0 || w <= 0 || (NSUInteger)w > kIFCMaxTextureSide || (NSUInteger)h > kIFCMaxTextureSide) return nil;
    IFCompositorColor bg = style.backgroundColor, fg = style.foregroundColor;
    double cr = fmin(fmin((double)(cornerRadius * s), (double)w / 2.0), (double)h);

    long length = w * h * 4;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    uint8_t *pixels = data.mutableBytes;

    // Fill with the background colour, masking the top corners.
    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            uint8_t *p = pixels + (y * w + x) * 4;
            double cornerAlpha = IFCCornerAlphaAt(x, y, w, cr);
            p[0] = IFCU8((double)bg.r * cornerAlpha);
            p[1] = IFCU8((double)bg.g * cornerAlpha);
            p[2] = IFCU8((double)bg.b * cornerAlpha);
            p[3] = IFCU8((double)bg.a * cornerAlpha);
        }
    }

    // The close button: two crossed lines, inset from the right edge.
    long btnSize = h;
    long btnX = w - btnSize - kIFCCloseBtnRightPad * s;
    long margin = IFCRound((double)btnSize * 0.37);
    long x0 = btnX + margin, y0 = margin;
    long x1 = btnX + btnSize - margin, y1 = h - margin;
    double lineW = (double)btnSize * kIFCCloseBtnStroke;
    IFCDrawLine(pixels, length, w, x0, y0, x1, y1, fg, lineW);
    IFCDrawLine(pixels, length, w, x0, y1, x1, y0, fg, lineW);

    long baseLeftPad = kIFCCloseBtnRightPad * s + margin;
    long leftPad = baseLeftPad;
    if (pinned) {
        double r = fmax(round((double)h * 0.16), 2.0);
        double cx = (double)baseLeftPad + r, cy = (double)h / 2.0;
        IFCDrawFilledCircle(pixels, length, w, cx, cy, r, fg);
        leftPad = baseLeftPad + IFCRound(2.0 * r) + kIFCTitleTextGap * s;
    }
    long rightLimit = btnX - kIFCTitleTextGap * s;
    long available = rightLimit - leftPad;
    if (available > 0 && title.length) {
        float fontPx = fmaxf((float)style.fontSize * kIFCPtToPx * (float)s, 1.0f);
        CTFontRef font = IFCCreateFont(style.font, (double)fontPx, style.fontWeight);
        long textW = 0;
        NSString *text = IFCFitText(title, font, available, &textW);
        long originX = leftPad;
        if (style.titleAlign == IFCompositorTitleAlignCenter) {
            // ((w - text_w) / 2).min(right_limit - text_w).max(left_pad)
            originX = MAX(MIN((w - textW) / 2, rightLimit - textW), leftPad);
        }
        IFCRasterizeInto(pixels, w, h, text, font, fontPx, fg, originX);
        CFRelease(font);
    }
    *outW = w;
    *outH = h;
    return data;
}

// decorations.rs `render_body_fill`: premultiplied, bottom corners rounded to
// the configured radius.
NSMutableData *IFCRenderBodyFill(long width, long height, long scale, IFCompositorChromeStyle *style, long *outW, long *outH) {
    long s = MAX(scale, 1L);
    long w = MAX(width, 1L) * s, h = MAX(height, 1L) * s;
    if ((NSUInteger)w > kIFCMaxTextureSide || (NSUInteger)h > kIFCMaxTextureSide) return nil;
    IFCompositorColor bg = style.backgroundColor;
    double ba = (double)bg.a / 255.0;
    double cr = fmin(fmin((double)((long)style.cornerRadius * s), (double)w / 2.0), (double)h / 2.0);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(w * h * 4)];
    uint8_t *pixels = data.mutableBytes;
    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            uint8_t *p = pixels + (y * w + x) * 4;
            double a = IFCBodyCornerAlphaAt(x, y, w, h, cr) * ba;
            p[0] = IFCU8((double)bg.r * a);
            p[1] = IFCU8((double)bg.g * a);
            p[2] = IFCU8((double)bg.b * a);
            p[3] = IFCU8(255.0 * a);
        }
    }
    *outW = w;
    *outH = h;
    return data;
}

// suspended.rs `ensure_label`: the label buffer and its body-local rectangle.
// Returns nil (and a zero rect) when nothing fits.
static NSMutableData *IFCLabel(NSString *text, long bodyW, long bodyH, long scale, IFCompositorChromeStyle *style,
                                     long *outW, long *outH, IFCRectI *labelRect, BOOL rasterize) {
    *labelRect = IFCRectIMake(0, 0, 0, 0);
    long s = MAX(scale, 1L);
    float fontPx = fmaxf((float)style.fontSize * kIFCPtToPx * (float)s, 1.0f);
    long avail = MAX(bodyW - 2 * kIFCLabelSidePad, 1L) * s;
    CTFontRef font = IFCCreateFont(style.font, (double)fontPx, style.fontWeight);
    long textW = 0;
    NSString *fitted = IFCFitText(text ?: @"", font, avail, &textW);
    if (!fitted.length || textW <= 0) {
        CFRelease(font);
        return nil;
    }
    long bufW = textW;
    long bufH = IFCCeil((double)(fontPx * 1.5f));
    if (bufH <= 0 || (NSUInteger)bufW > kIFCMaxTextureSide || (NSUInteger)bufH > kIFCMaxTextureSide) {
        CFRelease(font);
        return nil;
    }
    NSMutableData *data = rasterize ? [NSMutableData dataWithLength:(NSUInteger)(bufW * bufH * 4)] : nil;
    if (rasterize) IFCRasterizeInto(data.mutableBytes, bufW, bufH, fitted, font, fontPx, style.foregroundColor, 0);
    CFRelease(font);
    // Centre within the bar+body footprint: shift up by half the bar.
    long lw = MAX(bufW / s, 1L), lh = MAX(bufH / s, 1L);
    *labelRect = IFCRectIMake((bodyW - lw) / 2, (bodyH - (long)style.titleBarHeight - lh) / 2, lw, lh);
    *outW = bufW;
    *outH = bufH;
    return data;
}

NSMutableData *IFCRenderLabel(NSString *text, long bodyW, long bodyH, long scale, IFCompositorChromeStyle *style,
                                     long *outW, long *outH, IFCRectI *labelRect) {
    return IFCLabel(text,bodyW,bodyH,scale,style,outW,outH,labelRect,YES);
}
CGRect IFCompositorStandInLabelRect(NSString *name, BOOL launching, CGSize body, NSInteger scale, IFCompositorChromeStyle *style) {
    if(!style||!isfinite(body.width)||!isfinite(body.height)||body.width<=0||body.height<=0)return CGRectNull;
    long w=0,h=0;IFCRectI r;
    NSString *text=launching?[name stringByAppendingString:@" launching\u2026"]:name;
    IFCLabel(text,IFCRound(body.width),IFCRound(body.height),MAX(scale,1),style,&w,&h,&r,NO);
    return r.w>0&&r.h>0?CGRectMake(r.x,r.y,r.w,r.h):CGRectNull;
}

// error_bar.rs `render_error_bar`: opaque black, the joined messages in white
// monospace, tail-ellipsised between the side insets. RGBA8 (`Abgr8888`), at
// buffer scale `scale`.
NSMutableData *IFCRenderErrorBar(NSString *text, long width, long barHeight, long scale, long *outW, long *outH) {
    long s = MAX(scale, 1L);
    long w = MAX(MAX(width, 1L) * s, 1L), h = MAX(MAX(barHeight, 1L) * s, 1L);
    if ((NSUInteger)w > kIFCMaxTextureSide || (NSUInteger)h > kIFCMaxTextureSide) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(w * h * 4)];
    uint8_t *pixels = data.mutableBytes;
    for (long i = 0; i < w * h; i++) pixels[i * 4 + 3] = 255;

    float fontPx = kIFCErrorBarFontPx * (float)s;
    long padX = kIFCErrorBarPadX * s;
    long available = w - 2 * padX;
    if (available > 0) {
        CTFontRef font = IFCCreateFont(@"monospace", (double)fontPx, IFCompositorFontWeightNormal);
        long textW = 0;
        NSString *fitted = IFCFitText(text ?: @"", font, available, &textW);
        IFCRasterizeInto(pixels, w, h, fitted, font, fontPx, IFCompositorColorMake(255, 255, 255, 255), padX);
        CFRelease(font);
    }
    *outW = w;
    *outH = h;
    return data;
}
