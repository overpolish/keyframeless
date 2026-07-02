/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The DRAW-ON reveal + endpoint-marker animation: reads a stroked layer's
// markers + draw-on lanes and resolves the visible line window plus each end's
// animated marker (riding the tip, spinning with an offset, or growing in at a
// fixed end). The most-iterated stroke logic, lifted out of
// CanvasLayerRender.m's per-layer encoder.

#import "CanvasLayerRenderInternal.h"
#import "CanvasLayerTransform.h"
#import "CanvasMarkerTessellate.h"
#import "CanvasStrokeTessellate.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

// One end's resolved marker animation for a NON-offset draw-on reveal. `reveal`
// is how far THIS end is drawn (end side: drawOn.end; start side:
// 1-drawOn.start
// - so both ends share one symmetric formula). Arrow / Arrowhead (marker 1 / 4)
// RIDE the visible tip pointing in the drawing direction, growing in over their
// footprint as the line leaves the start; the others sit FIXED at the true end
// and animate in from one stroke-width over the reveal tail. `lineBound` is the
// (possibly ramped-to-complete-early) reveal to feed the line for this end (end
// side -> lineEnd; start side -> 1-lineBound).
typedef struct {
  uint8_t marker; // 0 = suppressed
  float sizePx;
  float pullback;
  float trim;      // marker anchor: arc trimmed from this end (0 = true end)
  float lineBound; // reveal to render the line to for this end
} CanvasEndMarkerAnim;

static CanvasEndMarkerAnim CanvasResolveEndMarker(uint8_t marker, float fullPx,
                                                  float fullPullback,
                                                  float reveal, float totalArc,
                                                  float strokeWidthPx,
                                                  float visibleLen) {
  const float kMarkerReveal = 0.15f; // reveal tail a fixed marker grows in over
  CanvasEndMarkerAnim r = {marker, fullPx, fullPullback, 0.0f, reveal};
  if (marker == 0)
    return r;
  if (marker == 1 || marker == 4) { // Arrow / Arrowhead: ride the visible tip
    float window = fmaxf(fullPullback, fullPx);
    float p = window > 0.0f ? fminf(1.0f, visibleLen / window) : 1.0f;
    r.sizePx = fullPx * p;
    r.pullback = fullPullback * p;
    r.trim = (1.0f - reveal) * totalArc; // ride the tip
    if (p <= 0.001f)
      r.marker = 0;
    return r;
  }
  // Circle / Square / Line: fixed at the true end, grow in from 100%.
  float p = fminf(
      1.0f, fmaxf(0.0f, (reveal - (1.0f - kMarkerReveal)) / kMarkerReveal));
  if (p <= 0.001f) {
    r.marker = 0;
    return r;
  }
  r.sizePx = strokeWidthPx + (fullPx - strokeWidthPx) * p; // 100% -> configured
  // Complete the line to the true end over the first half of the tail so the
  // fixed marker sits on the finished tip (identity below the tail = no
  // over-draw).
  r.lineBound = fminf(1.0f, (1.0f - kMarkerReveal) +
                                (reveal - (1.0f - kMarkerReveal)) * 2.0f);
  return r;
}

CanvasDrawOnRender CanvasResolveStrokeDrawOn(
    KKBezierPath *path, KKBezierPath *geom, double evalFrac,
    NSString *overrideLayerID, KKTimeline *overrideTimeline, float strokeStart,
    float strokeEnd, float strokeScale, float imageWidth, float imageHeight) {
  uint8_t startMarker = 0, endMarker = 0;
  float startMul = path.startMarkerSize, endMul = path.endMarkerSize;
  CanvasStrokeMarkersAtFraction(path, evalFrac, overrideLayerID,
                                overrideTimeline, &startMarker, &endMarker,
                                &startMul, &endMul);
  float sMarkerPxFull = strokeStart * strokeScale * startMul;
  float eMarkerPxFull = strokeEnd * strokeScale * endMul;
  float startPullbackFull =
      startMarker ? CanvasMarkerPullback(startMarker, sMarkerPxFull) : 0.0f;
  float endPullbackFull =
      endMarker ? CanvasMarkerPullback(endMarker, eMarkerPxFull) : 0.0f;
  CanvasStrokeDrawOn drawOn = CanvasStrokeDrawOnAtFraction(
      path, evalFrac, overrideLayerID, overrideTimeline);
  float totalArc = CanvasContourTotalArc(geom, imageWidth, imageHeight);

  CanvasDrawOnRender r = {drawOn.start,
                          drawOn.end,
                          drawOn.offset,
                          startMarker,
                          endMarker,
                          sMarkerPxFull,
                          eMarkerPxFull,
                          startPullbackFull,
                          endPullbackFull,
                          0.0f,
                          0.0f,
                          NO,
                          NO};
  r.active = totalArc > 0.0f &&
             (drawOn.start > 0.0f || drawOn.end < 1.0f || drawOn.offsetEngaged);
  r.collapsed =
      totalArc > 0.0f &&
      (drawOn.start + (1.0f - drawOn.end)) * totalArc >= totalArc - 0.5f;

  if (drawOn.offsetEngaged) {
    // An OFFSET spin rotates the visible window around the path: keep the
    // markers on its (shifted) ends, full size, riding the spin - at full
    // reveal too (the cut/seam stays where the offset puts it).
    float L = totalArc;
    float a = drawOn.start * L;
    float visLen = (drawOn.end - drawOn.start) * L;
    if (L > 0.0f && visLen > 0.5f) {
      float winStart = fmodf(drawOn.offset * L + a, L);
      if (winStart < 0.0f)
        winStart += L;
      // endPos uses the SAME wrap decision the stroke tessellator does, so the
      // markers land on the rendered window ends (no mismatch at the wrap or a
      // wrapped-0 full reveal).
      float w1 = winStart + visLen;
      float endPos = (w1 > L + 0.5f) ? (w1 - L) : w1;
      r.markerStartTrim = winStart;
      r.markerEndTrim = fmaxf(0.0f, L - endPos);
      float wsS = fmaxf(sMarkerPxFull, 1.0f);
      float wsE = fmaxf(eMarkerPxFull, 1.0f);
      // GROW-IN as the visible span opens (animate in, not pop) + SEAM
      // smoothing on PARTIAL reveals only (a full reveal's ends sit AT the
      // natural endpoints and must not shrink - that was the flash-disappear).
      float sf = fminf(1.0f, visLen / wsS);
      float ef = fminf(1.0f, visLen / wsE);
      if (visLen < L - 0.5f) {
        sf *= fminf(1.0f, fminf(winStart, L - winStart) / wsS);
        ef *= fminf(1.0f, fminf(endPos, L - endPos) / wsE);
      }
      r.sMarkerPx = sMarkerPxFull * sf;
      r.eMarkerPx = eMarkerPxFull * ef;
      r.startPullback = startPullbackFull * sf;
      r.endPullback = endPullbackFull * ef;
      if (sf <= 0.001f)
        r.startMarker = 0;
      if (ef <= 0.001f)
        r.endMarker = 0;
    } else {
      r.startMarker = 0;
      r.endMarker = 0;
    }
  } else if (r.active) {
    float visibleLen = fmaxf(0.0f, (drawOn.end - drawOn.start) * totalArc);
    CanvasEndMarkerAnim e = CanvasResolveEndMarker(
        endMarker, eMarkerPxFull, endPullbackFull, drawOn.end, totalArc,
        strokeEnd * strokeScale, visibleLen);
    r.endMarker = e.marker;
    r.eMarkerPx = e.sizePx;
    r.endPullback = e.pullback;
    r.markerEndTrim = e.trim;
    r.lineEnd = e.lineBound;
    CanvasEndMarkerAnim s = CanvasResolveEndMarker(
        startMarker, sMarkerPxFull, startPullbackFull, 1.0f - drawOn.start,
        totalArc, strokeStart * strokeScale, visibleLen);
    r.startMarker = s.marker;
    r.sMarkerPx = s.sizePx;
    r.startPullback = s.pullback;
    r.markerStartTrim = s.trim;
    r.lineStart = 1.0f - s.lineBound;
  }
  return r;
}
