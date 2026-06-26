/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasCenterline.h"
#import "CanvasLocalized.h" // CLoc
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKShape.h> // KKRectShape min/max
#import <simd/simd.h>

#import "CanvasCenterlineInternal.h"

static void CenterlineCopyStyle(KKBezierPath *dst, KKBezierPath *src) {
  dst.parentGroupID = src.parentGroupID; // stay in the source's group
  dst.opacity = src.opacity;
  dst.transformEnabled = src.transformEnabled;
  dst.translateX = src.translateX;
  dst.translateY = src.translateY;
  dst.scaleX = src.scaleX;
  dst.scaleY = src.scaleY;
  dst.rotationZ = src.rotationZ;
  dst.anchorX = src.anchorX;
  dst.anchorY = src.anchorY;
}

// Is `pt` shared with any OTHER chain's endpoint (i.e. a junction)? Used to
// tell a free tip (extend it) from a junction end (don't - it'd overshoot).
static BOOL CenterlineEndShared(CenterlineChain *chains, int chainCount,
                                int self, KKBezierPoint pt, double tol,
                                int contentW, int contentH) {
  for (int d = 0; d < chainCount; d++) {
    if (d == self || chains[d].count < 2)
      continue;
    KKBezierPoint a = chains[d].pts[0];
    KKBezierPoint b = chains[d].pts[chains[d].count - 1];
    if (hypot((double)(pt.x - a.x) * contentW,
              (double)(pt.y - a.y) * contentH) < tol ||
        hypot((double)(pt.x - b.x) * contentW,
              (double)(pt.y - b.y) * contentH) < tol)
      return YES;
  }
  return NO;
}

// Append one fitted chain as a contour, optionally extrapolating a free end out
// by `ext` (content px, along its tangent) so the stroke reaches the shape's
// tip.
static void CenterlineAddContour(KKBezierPath *line, CenterlineChain *chain,
                                 BOOL extendStart, BOOL extendEnd, double ext,
                                 int contentW, int contentH) {
  if (line.count > 0)
    [line beginContour];
  int cnt = chain->count;
  if (extendStart) {
    KKBezierPoint a = chain->pts[0], b = chain->pts[1];
    double dx = (double)(a.x - b.x) * contentW,
           dy = (double)(a.y - b.y) * contentH;
    double l = hypot(dx, dy);
    if (l > 1e-6)
      [line insertAtIndex:line.count
                 position:simd_make_float2(
                              a.x + (float)(dx / l * ext / contentW),
                              a.y + (float)(dy / l * ext / contentH))];
  }
  for (int i = 0; i < cnt; i++) {
    KKBezierPoint kp = chain->pts[i];
    NSUInteger idx = line.count;
    [line insertAtIndex:idx position:simd_make_float2(kp.x, kp.y)];
    if (kp.type == KKBezierPointBezier) {
      [line setType:KKBezierPointBezier atIndex:idx];
      [line setInHandle:simd_make_float2(kp.inX, kp.inY) atIndex:idx];
      [line setOutHandle:simd_make_float2(kp.outX, kp.outY) atIndex:idx];
    }
  }
  if (extendEnd) {
    KKBezierPoint a = chain->pts[cnt - 1], b = chain->pts[cnt - 2];
    double dx = (double)(a.x - b.x) * contentW,
           dy = (double)(a.y - b.y) * contentH;
    double l = hypot(dx, dy);
    if (l > 1e-6)
      [line insertAtIndex:line.count
                 position:simd_make_float2(
                              a.x + (float)(dx / l * ext / contentW),
                              a.y + (float)(dy / l * ext / contentH))];
  }
}

// Assemble traced+fitted chains into ONE open multi-contour stroked path (each
// branch a contour), styled from the source. Read-only on chains (caller
// frees).
static KKBezierPath *CenterlineAssemblePath(CenterlineChain *chains,
                                            int chainCount, KKBezierPath *src,
                                            float sw, int contentW,
                                            int contentH, double thickPx) {
  // A lone contour whose ends nearly meet is a closed outline (e.g. a state
  // border): build it, drop the duplicate end, and close it - no extrapolation.
  int validCount = 0, onlyChain = -1;
  for (int c = 0; c < chainCount; c++)
    if (chains[c].count >= 2) {
      validCount++;
      onlyChain = c;
    }
  BOOL closeLoop = NO;
  if (validCount == 1) {
    KKBezierPoint a = chains[onlyChain].pts[0];
    KKBezierPoint b = chains[onlyChain].pts[chains[onlyChain].count - 1];
    if (hypot((double)(a.x - b.x) * contentW, (double)(a.y - b.y) * contentH) <
        fmax(3.0, thickPx * 1.5))
      closeLoop = YES;
  }

  // Extrapolate FREE tips (medial axis stops ~half a thickness short of a flat
  // end) but never junction ends (shared by multiple branches - would overshoot
  // the joint). A straight line / arc has two free ends; a plus extends its
  // four outer tips and leaves the shared centre alone.
  double ext = thickPx * 0.5;
  double tipTol = fmax(2.0, thickPx * 0.4);
  KKBezierPath *line = [[KKBezierPath alloc] init];
  line.closed = NO;
  for (int c = 0; c < chainCount; c++) {
    if (chains[c].count < 2)
      continue;
    BOOL es = !closeLoop &&
              !CenterlineEndShared(chains, chainCount, c, chains[c].pts[0],
                                   tipTol, contentW, contentH);
    BOOL ee =
        !closeLoop && !CenterlineEndShared(chains, chainCount, c,
                                           chains[c].pts[chains[c].count - 1],
                                           tipTol, contentW, contentH);
    CenterlineAddContour(line, &chains[c], es, ee, ext, contentW, contentH);
  }
  if (line.count < 2)
    return nil;
  if (closeLoop && line.count >= 4) {
    [line removeAtIndex:line.count - 1];
    line.closed = YES;
  }
  CenterlineCopyStyle(line, src);
  line.fillEnabled = NO;
  line.strokeEnabled = YES;
  if (src.isImage) { // an image has no meaningful fill colour
    line.strokeR = line.strokeG = line.strokeB = 1.0f;
    line.opacity = 1.0f;
  } else {
    line.strokeR = src.fillR;
    line.strokeG = src.fillG;
    line.strokeB = src.fillB;
  }
  line.lineCap = 0;  // butt
  line.lineJoin = 0; // miter: crisp corners (e.g. the L's 90 deg)
  line.strokeWidth = sw;
  line.endWidth = sw;
  return line;
}

// Open CGPath (content-px coords, CG y-up so the readback matches the mask
// grid) from a fitted centerline path - subpaths stay OPEN so stroking gives a
// line.
static CGPathRef CenterlineOpenCGPath(KKBezierPath *path, int contentW,
                                      int contentH) {
  CGMutablePathRef cg = CGPathCreateMutable();
  NSUInteger nc = path.contourCount;
  for (NSUInteger c = 0; c < nc; c++) {
    NSRange r = [path contourRangeAtIndex:c];
    if (r.length < 2)
      continue;
    KKBezierPoint f = [path pointAtIndex:r.location];
    CGPathMoveToPoint(cg, NULL, f.x * contentW, f.y * contentH);
    for (NSUInteger i = 1; i < r.length; i++) {
      KKBezierPoint p = [path pointAtIndex:r.location + i];
      KKBezierPoint pv = [path pointAtIndex:r.location + i - 1];
      if (pv.type == KKBezierPointBezier || p.type == KKBezierPointBezier)
        CGPathAddCurveToPoint(
            cg, NULL, (pv.x + pv.outX) * contentW, (pv.y + pv.outY) * contentH,
            (p.x + p.inX) * contentW, (p.y + p.inY) * contentH, p.x * contentW,
            p.y * contentH);
      else
        CGPathAddLineToPoint(cg, NULL, p.x * contentW, p.y * contentH);
    }
  }
  return cg;
}

// Verification score: stroke the candidate at the recovered width into a mask
// and return its IoU (intersection-over-union) with the source silhouette. The
// candidate that best reconstructs the source wins the multi-fit.
static double CenterlineScoreIoU(KKBezierPath *path, double swPx,
                                 const uint8_t *srcGrid, int contentW,
                                 int contentH, int W) {
  uint8_t *buf = calloc((size_t)contentW * contentH, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx =
      CGBitmapContextCreate(buf, contentW, contentH, 8, (size_t)contentW, cs,
                            (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    free(buf);
    return 0.0;
  }
  CGPathRef cg = CenterlineOpenCGPath(path, contentW, contentH);
  CGContextSetLineWidth(ctx, fmax(1.0, swPx));
  CGContextSetLineCap(ctx, kCGLineCapRound);
  CGContextSetLineJoin(ctx, kCGLineJoinRound);
  CGContextSetGrayStrokeColor(ctx, 1.0, 1.0);
  CGContextAddPath(ctx, cg);
  CGContextStrokePath(ctx);
  CGPathRelease(cg);
  CGContextRelease(ctx);
  // buf row r = top (CG y-up readback), srcGrid padded row (r+1) = same content
  // row, so the two align pixel-for-pixel.
  long inter = 0, uni = 0;
  for (int r = 0; r < contentH; r++)
    for (int c = 0; c < contentW; c++) {
      BOOL a = buf[r * contentW + c] > 127;
      BOOL b = srcGrid[(r + 1) * W + (c + 1)] != 0;
      if (a && b)
        inter++;
      if (a || b)
        uni++;
    }
  free(buf);
  return uni > 0 ? (double)inter / (double)uni : 0.0;
}

// Trace the source fill's centerline into one stroked layer PER branch,
// coloured from the source fill, with the recovered stroke width. nil if the
// trace produced nothing usable.
static NSArray<KKBezierPath *> *CenterlinePathsFromSource(KKBezierPath *src,
                                                          CGFloat aspect,
                                                          CGFloat refWidth,
                                                          CGFloat refHeight) {
  int contentW = 0, contentH = 0, W = 0, H = 0;
  long filled = 0;
  uint8_t *grid = src.isImage
                      ? CenterlineBuildImageMask(src, aspect, &contentW,
                                                 &contentH, &W, &H, &filled)
                      : CenterlineRasterize(src, aspect, &contentW, &contentH,
                                            &W, &H, &filled);
  if (!grid || filled == 0) {
    free(grid);
    return nil;
  }
  // Keep the filled silhouette for scoring candidates (thinning mutates grid).
  uint8_t *srcMask = malloc((size_t)W * H);
  if (srcMask)
    memcpy(srcMask, grid, (size_t)W * H);
  CenterlineThin(grid, W, H);

  // Estimate ribbon thickness (area / skeleton length) and prune barbs shorter
  // than ~one thickness - they are thinning artifacts, not real branches.
  long skelPixels = CenterlineCountFg(grid, W, H);
  double thickRough =
      skelPixels > 0 ? (double)filled / (double)skelPixels : 4.0;
  int maxSpur = (int)lround(fmin(40.0, fmax(4.0, thickRough)));
  CenterlinePruneSpurs(grid, W, H, maxSpur);

  // Re-estimate thickness after pruning (barb length no longer inflates the
  // skeleton), and use it to drive the fit's smoothing + tolerance.
  long skelPruned = CenterlineCountFg(grid, W, H);
  double thickPx = skelPruned > 0 ? (double)filled / (double)skelPruned : 4.0;

  // Recovered stroke width: ribbon thickness (diagonal-aware length, not pixel
  // count) scaled into output px. One representative trace gives skelLen for
  // the width; the multi-fit below re-traces per detail level.
  int probeCount = 0;
  double skelLen = 0;
  CenterlineChain *probe =
      CenterlineTrace(grid, W, H, contentW, contentH, thickPx, 0.2, 0.57, 0.45,
                      &probeCount, &skelLen);
  for (int c = 0; c < probeCount; c++)
    free(probe[c].pts);
  free(probe);
  double thickForWidth = skelLen > 1.0 ? (double)filled / skelLen : thickPx;
  double scale = refHeight > 0 ? refHeight / (double)contentH : 1.0;
  float sw = (float)fmax(1.0, fmin(400.0, thickForWidth * scale));
  double swContentPx =
      thickForWidth; // stroke width in content px (for scoring)
  NSString *base = src.name.length ? src.name : @"Path";

  // Multi-fit: trace+fit at a few detail levels (sharp -> smooth), re-stroke
  // each candidate and score it by overlap (IoU) with the source silhouette,
  // then keep the best (tie-break toward fewer nodes). This auto-selects sharp
  // for thin shapes and smooth for thick/wandering ones - no global threshold
  // to mis-tune.
  const struct {
    double rdpMult, cornerCos, fitMult;
  } levels[] = {
      {0.10, 0.80, 0.18}, // sharp: keep corners/detail
      {0.20, 0.57, 0.35}, // medium
      {0.35, 0.40, 0.55}, // smooth: absorb wander
  };
  KKBezierPath *best = nil;
  double bestScore = -1.0;
  for (int li = 0; li < (int)(sizeof(levels) / sizeof(levels[0])); li++) {
    int cn = 0;
    double sl = 0;
    CenterlineChain *chains = CenterlineTrace(
        grid, W, H, contentW, contentH, thickPx, levels[li].rdpMult,
        levels[li].cornerCos, levels[li].fitMult, &cn, &sl);
    KKBezierPath *cand =
        cn > 0 ? CenterlineAssemblePath(chains, cn, src, sw, contentW, contentH,
                                        thickPx)
               : nil;
    for (int c = 0; c < cn; c++)
      free(chains[c].pts);
    free(chains);
    if (!cand)
      continue;
    double iou = srcMask ? CenterlineScoreIoU(cand, swContentPx, srcMask,
                                              contentW, contentH, W)
                         : 0.0;
    // Levels run sharp -> smooth; keep the sharper one unless a smoother level
    // is CLEARLY better (margin). This preserves fine detail (Texas notches)
    // while still letting a thick wandering shape (arc) pick smooth, where its
    // sharp fit scores distinctly worse.
    if (best == nil || iou > bestScore + 0.02) {
      best = cand;
      bestScore = iou;
    }
  }
  free(grid);
  free(srcMask);
  if (!best)
    return nil;
  best.name = [NSString
      stringWithFormat:CLoc(@"%@ Centerline",
                            @"Layer name for a centerline-traced stroke (%@ = "
                            @"source layer name)"),
                       base];
  return @[ best ];
}

NSArray<NSString *> *
CanvasApplyCenterlineOp(NSMutableArray<KKBezierPath *> *paths,
                        NSArray<NSString *> *selIDs, CGFloat refWidth,
                        CGFloat refHeight) {
  if (selIDs.count == 0)
    return nil;
  CGFloat aspect = refHeight > 0 ? refWidth / refHeight : 16.0 / 9.0;
  NSMutableArray<NSNumber *> *srcIdx = [NSMutableArray array];
  NSMutableArray<NSArray<KKBezierPath *> *> *results = [NSMutableArray array];
  for (NSUInteger i = 0; i < paths.count; i++) {
    KKBezierPath *p = paths[i];
    // Trace a filled vector shape, or an image (its alpha/luminance
    // silhouette).
    BOOL vectorFill = !p.isImage && !p.isGroup && p.fillEnabled;
    BOOL image = p.isImage && p.imagePath.length &&
                 [p.shape isKindOfClass:[KKRectShape class]];
    if (!vectorFill && !image)
      continue;
    if (![selIDs containsObject:(p.layerID ?: @"")])
      continue;
    NSArray<KKBezierPath *> *lines =
        CenterlinePathsFromSource(p, aspect, refWidth, refHeight);
    if (!lines.count)
      continue;
    [srcIdx addObject:@(i)];
    [results addObject:lines];
  }
  if (results.count == 0)
    return nil;

  NSMutableArray<NSString *> *newSel = [NSMutableArray array];
  // Process descending so earlier indices stay valid. A vector source is
  // CONSUMED (like a boolean op) and its branches take its slot - nothing empty
  // left behind, result stays in any group. An IMAGE source is KEPT (it's a
  // real asset) with the traced stroke inserted just above it.
  for (NSInteger k = (NSInteger)results.count - 1; k >= 0; k--) {
    NSUInteger idx = [srcIdx[(NSUInteger)k] unsignedIntegerValue];
    NSArray<KKBezierPath *> *lines = results[(NSUInteger)k];
    if (!paths[idx].isImage)
      [paths removeObjectAtIndex:idx]; // consume the source blob
    for (NSInteger b = (NSInteger)lines.count - 1; b >= 0; b--) {
      KKBezierPath *line = lines[(NSUInteger)b];
      [paths insertObject:line
                  atIndex:idx]; // source's slot (above a kept image)
      if (line.layerID.length)
        [newSel addObject:line.layerID];
    }
  }
  return newSel;
}
