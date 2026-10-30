//
//  DeinterlaceShader.swift
//  PlaybackKit
//
//  Metal source for the field-rate deinterlacer (v2) and the bob pass for grid tiles (at the end), compiled at
//  runtime so the package needs no resource bundle.
//  Written clean-room under Apache-2.0 from first principles; no FFmpeg code or coefficient tables (bwdif, w3fdif and
//  yadif are LGPL/GPL). The derivation is below.
//
//  Each output field keeps its own lines (parity `keepParity`) from the current frame. For every missing line m:
//
//  1. Spatial estimate, low band: the kept field's lines m-3, m-1, m+1, m+3 through Keys' cubic convolution kernel
//     (a = -1/2, which is also cubic Lagrange interpolation) evaluated half way between samples:
//         W(1/2) = (a+2)/8 - (a+3)/4 + 1 = 9/16,    W(3/2) = a(27/8 - 45/4 + 12 - 4) = -1/16
//     so taps (-1, 9, 9, -1) / 16. On a vertical cosine of frequency w (radians per frame line) it responds
//         Hs(w) = (9 cos w - cos 3w) / 8 = 1 - (3/8) w^4 + O(w^6).
//  2. Spatial estimate, high band ("temporal high-frequency compensation"): the opposite field at line m exists in
//     the fields just before and just after this one. A symmetric 5-tap high-pass on that field (lines m, m+-2,
//     m+-4), Hh(w) = c0 + 2 c1 cos 2w + 2 c2 cos 4w, is chosen so that Hs + Hh = 1 + O(w^6), i.e. it supplies the
//     detail the cubic loses: Hh(0) = 0 and no w^2 term give c1 = -4 c2 and c0 = 6 c2; matching (3/8) w^4 gives
//     16 c2 = 3/8. So taps (3, -12, 18, -12, 3) / 128. It is taken from the before and after fields separately and
//     combined by min-mod (zero when they disagree in sign, else the smaller), so only detail both fields agree on
//     is added and moving edges don't ghost.
//  3. Edge direction: if one of the two diagonals through m (+-1 pixel) matches the lines above and below clearly
//     better than the vertical (sum of absolute differences over three pixels, by a margin), the diagonal average
//     replaces the vertical estimate, which keeps slanted edges free of stair steps.
//  4. Temporal estimate T: the mean of the before and after fields at m (exact for a still picture).
//  5. Motion: the largest of half the change of the opposite field across this field, and the mean change of the
//     kept field's lines m-1 and m+1 from two fields earlier and from two fields later. Plus a spatial check of our
//     own: if T sticks out above (or below) both kept neighbours m-1 and m+1, by more than the woven estimates at
//     m-2 and m+2 stick out from those same neighbours, the excess counts as motion. Real line-pair detail is woven
//     consistently and passes; an isolated woven spike is treated as a comb tooth. A comb needs motion, so the
//     excess counts only up to twice the temporal change seen at m, m-2 and m+2: a still picture (thin static
//     text, one-line highlights) always weaves back exactly.
//  6. Output: the spatial estimate clamped to T +- motion. A still area weaves exactly; a moving one interpolates.
//
//  4:2:0 interlaced chroma: in MPEG-2 interlaced 4:2:0 each field has its own chroma rows, alternating like luma
//  rows (chroma row r belongs to the field of parity r % 2) and sited so that, in frame coordinates, they land where
//  progressive 4:2:0 chroma sits (row r at luma row 2r + 1/2). So chroma is deinterlaced per field on its own grid
//  with the same steps, and a progressive frame comes out correctly sited. Chroma has too little vertical resolution
//  to judge motion well, so its motion is the larger of its own and the luma motion over the 2x2 luma pairs it
//  covers (the luma pass writes a motion map; luma field pairs 2j and 2j+1 sit under chroma field pair j).
//
//  Sources: NV12 pictures bind one CbCr texture per picture. libavcodec's planar pictures are read in place through
//  R8 textures over their planes, so the chroma pass binds a Cb and a Cr texture per picture instead; the same source
//  compiled with PLANAR_CHROMA=1 gives that variant of the chroma kernel (`SOURCE`, `PASS` and `SAMPLE` hide the
//  difference). Luma is one R8 texture either way.
//
//  Layout: one thread per field-line pair (a kept line and the missing line next to it), so each thread copies one
//  line and interpolates one. A 32x8 threadgroup loads the kept field's lines (with a 2-pixel, 2-line apron) and the
//  before and after opposite-field lines into threadgroup memory once. Arithmetic is `half`: inputs are 8-bit, the
//  weights are dyadic and every intermediate stays within +-2, so rounding stays well under one code value.
//

nonisolated enum DeinterlaceShader {
    /// Threadgroup size the kernels are written for (TILE_W x TILE_H in the source).
    static let tileWidth = 32
    static let tileHeight = 8

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    #ifndef PLANAR_CHROMA
    #define PLANAR_CHROMA 0
    #endif

    #define TILE_W 32
    #define TILE_H 8
    #define KEPT_W (TILE_W + 4)
    #define ROWS (TILE_H + 4)

    struct DeinterlaceParams {
        uint keepParity;   // lines with y % 2 == keepParity come from the current frame
    };

    struct FieldEstimate {
        half2 spatial;
        half2 temporal;
        half2 motion;
    };

    static inline half2 texel(texture2d<half, access::read> tex, int x, int row) {
        int width = int(tex.get_width());
        int height = int(tex.get_height());
        return tex.read(uint2(uint(clamp(x, 0, width - 1)), uint(clamp(row, 0, height - 1)))).xy;
    }

    #if PLANAR_CHROMA
    #define SOURCE(name) texture2d<half, access::read> name, texture2d<half, access::read> name##Red
    #define PASS(name) name, name##Red
    #define SAMPLE(name, SX, SY) half2(texel(name, SX, SY).x, texel(name##Red, SX, SY).x)
    #else
    #define SOURCE(name) texture2d<half, access::read> name
    #define PASS(name) name
    #define SAMPLE(name, SX, SY) texel(name, SX, SY)
    #endif

    // Frame row of line `index` of the field with `parity`, clamped to that field's `lines`.
    static inline int fieldRow(int index, int parity, int lines) {
        return 2 * clamp(index, 0, lines - 1) + parity;
    }

    static inline half score(half2 lhs, half2 rhs) {
        half2 diff = abs(lhs - rhs);
        return diff.x + diff.y;
    }

    // Loads the kept field's lines origin.y-2 ..< origin.y+TILE_H+2 (columns origin.x-2 ..< origin.x+TILE_W+2) and
    // the before and after opposite fields' lines over the same line range (columns origin.x ..< origin.x+TILE_W).
    static inline void loadTiles(threadgroup half2 *kept, threadgroup half2 *beforeTile, threadgroup half2 *afterTile,
                                 SOURCE(current), SOURCE(before), SOURCE(after), int2 origin, uint flat, int parity) {
        int height = int(current.get_height());
        int keptLines = (height + 1 - parity) / 2;
        int oppositeLines = (height + parity) / 2;
        for (uint item = flat; item < uint(KEPT_W * ROWS); item += TILE_W * TILE_H) {
            int column = int(item % KEPT_W);
            int line = int(item / KEPT_W);
            kept[item] = SAMPLE(current, origin.x - 2 + column, fieldRow(origin.y - 2 + line, parity, keptLines));
        }
        for (uint item = flat; item < uint(TILE_W * ROWS); item += TILE_W * TILE_H) {
            int column = int(item % TILE_W);
            int row = fieldRow(origin.y - 2 + int(item / TILE_W), 1 - parity, oppositeLines);
            beforeTile[item] = SAMPLE(before, origin.x + column, row);
            afterTile[item] = SAMPLE(after, origin.x + column, row);
        }
    }

    // Steps 1-5 for the missing line of the pair at `local` (see DeinterlaceShader.swift).
    static inline FieldEstimate estimate(threadgroup const half2 *kept, threadgroup const half2 *beforeTile,
                                         threadgroup const half2 *afterTile, int2 local, int parity,
                                         half2 earlierAbove, half2 earlierBelow,
                                         half2 laterAbove, half2 laterBelow) {
        int up1 = (local.y + 2 - parity) * KEPT_W + local.x + 2;
        int dn1 = up1 + KEPT_W;
        half2 above = kept[up1];
        half2 below = kept[dn1];
        half2 vertical = 0.5625h * (above + below) - 0.0625h * (kept[up1 - KEPT_W] + kept[dn1 + KEPT_W]);

        int mid = (local.y + 2) * TILE_W + local.x;
        half2 before0 = beforeTile[mid];
        half2 after0 = afterTile[mid];
        half2 beforeHigh = 0.140625h * before0 - 0.09375h * (beforeTile[mid - TILE_W] + beforeTile[mid + TILE_W])
                         + 0.0234375h * (beforeTile[mid - 2 * TILE_W] + beforeTile[mid + 2 * TILE_W]);
        half2 afterHigh = 0.140625h * after0 - 0.09375h * (afterTile[mid - TILE_W] + afterTile[mid + TILE_W])
                        + 0.0234375h * (afterTile[mid - 2 * TILE_W] + afterTile[mid + 2 * TILE_W]);
        half2 agree = sign(beforeHigh) * sign(afterHigh);
        half2 high = select(half2(0.0h), sign(beforeHigh) * min(abs(beforeHigh), abs(afterHigh)), agree > 0.0h);

        FieldEstimate result;
        result.spatial = vertical + high;
        half bestScore = score(kept[up1 - 1], kept[dn1 - 1]) + score(above, below) + score(kept[up1 + 1], kept[dn1 + 1])
                       - 0.03h;
        for (int dir = -1; dir <= 1; dir += 2) {
            half candidate = score(kept[up1 - 1 + dir], kept[dn1 - 1 - dir]) + score(kept[up1 + dir], kept[dn1 - dir])
                           + score(kept[up1 + 1 + dir], kept[dn1 + 1 - dir]);
            if (candidate < bestScore) {
                bestScore = candidate;
                result.spatial = (kept[up1 + dir] + kept[dn1 - dir]) * 0.5h;
            }
        }

        result.temporal = (before0 + after0) * 0.5h;
        half2 wovenAbove = (beforeTile[mid - TILE_W] + afterTile[mid - TILE_W]) * 0.5h;
        half2 wovenBelow = (beforeTile[mid + TILE_W] + afterTile[mid + TILE_W]) * 0.5h;
        half2 motion = abs(before0 - after0) * 0.5h;
        motion = max(motion, (abs(earlierAbove - above) + abs(earlierBelow - below)) * 0.5h);
        motion = max(motion, (abs(laterAbove - above) + abs(laterBelow - below)) * 0.5h);
        half2 peak = result.temporal - max(above, below)
                   - max(half2(0.0h), min(wovenAbove - above, wovenBelow - below));
        half2 trough = min(above, below) - result.temporal
                     - max(half2(0.0h), min(above - wovenAbove, below - wovenBelow));
        // A comb needs motion: the spatial check widens the range by at most twice the change seen here or on the
        // woven lines just above and below, so a truly still picture always weaves back exactly.
        half2 nearby = max(abs(beforeTile[mid - TILE_W] - afterTile[mid - TILE_W]),
                           abs(beforeTile[mid + TILE_W] - afterTile[mid + TILE_W])) * 0.5h;
        half2 gate = 2.0h * max(motion, nearby);
        result.motion = max(motion, min(max(peak, trough), gate));
        return result;
    }

    #define DEINTERLACE_PROLOGUE \\
        threadgroup half2 kept[KEPT_W * ROWS]; \\
        threadgroup half2 beforeTile[TILE_W * ROWS]; \\
        threadgroup half2 afterTile[TILE_W * ROWS]; \\
        int parity = int(params.keepParity); \\
        int2 origin = int2(group) * int2(TILE_W, TILE_H); \\
        loadTiles(kept, beforeTile, afterTile, PASS(current), PASS(before), PASS(after), origin, flat, parity); \\
        threadgroup_barrier(mem_flags::mem_threadgroup); \\
        int2 tile = int2(local); \\
        int x = origin.x + tile.x; \\
        int pair = origin.y + tile.y; \\
        int height = int(out.get_height()); \\
        if (x >= int(out.get_width()) || 2 * pair >= height) { return; } \\
        int keptRow = 2 * pair + parity; \\
        int missingRow = 2 * pair + 1 - parity; \\
        half2 keptValue = kept[(tile.y + 2) * KEPT_W + tile.x + 2]; \\
        if (keptRow < height) { out.write(half4(keptValue, 0.0h, 1.0h), uint2(uint(x), uint(keptRow))); } \\
        if (missingRow >= height) { return; } \\
        int keptLines = (height + 1 - parity) / 2; \\
        int rowAbove = fieldRow(pair - parity, parity, keptLines); \\
        int rowBelow = fieldRow(pair + 1 - parity, parity, keptLines); \\
        FieldEstimate field = estimate(kept, beforeTile, afterTile, tile, parity, \\
                                       SAMPLE(earlier, x, rowAbove), SAMPLE(earlier, x, rowBelow), \\
                                       SAMPLE(later, x, rowAbove), SAMPLE(later, x, rowBelow));

    #if !PLANAR_CHROMA
    kernel void deinterlaceLuma(texture2d<half, access::read> before [[texture(0)]],
                                texture2d<half, access::read> current [[texture(1)]],
                                texture2d<half, access::read> after [[texture(2)]],
                                texture2d<half, access::read> earlier [[texture(3)]],
                                texture2d<half, access::read> later [[texture(4)]],
                                texture2d<half, access::write> out [[texture(5)]],
                                texture2d<half, access::write> motionMap [[texture(6)]],
                                constant DeinterlaceParams &params [[buffer(0)]],
                                uint2 group [[threadgroup_position_in_grid]],
                                uint2 local [[thread_position_in_threadgroup]],
                                uint flat [[thread_index_in_threadgroup]]) {
        DEINTERLACE_PROLOGUE
        half motion = field.motion.x;
        motionMap.write(half4(motion), uint2(uint(x), uint(pair)));
        half value = clamp(field.spatial.x, field.temporal.x - motion, field.temporal.x + motion);
        out.write(half4(value), uint2(uint(x), uint(missingRow)));
    }
    #endif

    static inline half lumaMotion(texture2d<half, access::read> motionMap, int x, int pair) {
        half2 top = half2(texel(motionMap, 2 * x, 2 * pair).x, texel(motionMap, 2 * x + 1, 2 * pair).x);
        half2 bottom = half2(texel(motionMap, 2 * x, 2 * pair + 1).x, texel(motionMap, 2 * x + 1, 2 * pair + 1).x);
        half2 larger = max(top, bottom);
        return max(larger.x, larger.y);
    }

    kernel void deinterlaceChroma(texture2d<half, access::read> before [[texture(0)]],
                                  texture2d<half, access::read> current [[texture(1)]],
                                  texture2d<half, access::read> after [[texture(2)]],
                                  texture2d<half, access::read> earlier [[texture(3)]],
                                  texture2d<half, access::read> later [[texture(4)]],
                                  texture2d<half, access::write> out [[texture(5)]],
                                  texture2d<half, access::read> motionMap [[texture(6)]],
    #if PLANAR_CHROMA
                                  texture2d<half, access::read> beforeRed [[texture(7)]],
                                  texture2d<half, access::read> currentRed [[texture(8)]],
                                  texture2d<half, access::read> afterRed [[texture(9)]],
                                  texture2d<half, access::read> earlierRed [[texture(10)]],
                                  texture2d<half, access::read> laterRed [[texture(11)]],
    #endif
                                  constant DeinterlaceParams &params [[buffer(0)]],
                                  uint2 group [[threadgroup_position_in_grid]],
                                  uint2 local [[thread_position_in_threadgroup]],
                                  uint flat [[thread_index_in_threadgroup]]) {
        DEINTERLACE_PROLOGUE
        half motion = max(max(field.motion.x, field.motion.y), lumaMotion(motionMap, x, pair));
        half2 value = clamp(field.spatial, field.temporal - motion, field.temporal + motion);
        out.write(half4(value, 0.0h, 1.0h), uint2(uint(x), uint(missingRow)));
    }

    // Bob (grid tiles): only the field of parity `keepParity`, its lines copied and the other field's lines
    // interpolated from it with step 1's cubic (-1, 9, 9, -1) / 16. One thread per output sample; chroma uses its own
    // field rows (4:2:0 interlaced), which sit on the same grid, so the midpoint is correctly sited.
    static inline half2 bobValue(SOURCE(current), int x, int y, int parity) {
        if ((y & 1) == parity) { return SAMPLE(current, x, y); }
        int lines = (int(current.get_height()) + 1 - parity) / 2;
        int above = (y + 1 - parity) / 2 - 1;
        half2 inner = SAMPLE(current, x, fieldRow(above, parity, lines))
                    + SAMPLE(current, x, fieldRow(above + 1, parity, lines));
        half2 outer = SAMPLE(current, x, fieldRow(above - 1, parity, lines))
                    + SAMPLE(current, x, fieldRow(above + 2, parity, lines));
        return 0.5625h * inner - 0.0625h * outer;
    }

    #if !PLANAR_CHROMA
    kernel void bobLuma(texture2d<half, access::read> current [[texture(0)]],
                        texture2d<half, access::write> out [[texture(1)]],
                        constant DeinterlaceParams &params [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        half value = bobValue(current, int(gid.x), int(gid.y), int(params.keepParity)).x;
        out.write(half4(value), gid);
    }
    #endif

    kernel void bobChroma(texture2d<half, access::read> current [[texture(0)]],
                          texture2d<half, access::write> out [[texture(1)]],
    #if PLANAR_CHROMA
                          texture2d<half, access::read> currentRed [[texture(2)]],
    #endif
                          constant DeinterlaceParams &params [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        half2 value = bobValue(PASS(current), int(gid.x), int(gid.y), int(params.keepParity));
        out.write(half4(value, 0.0h, 1.0h), gid);
    }
    """
}
