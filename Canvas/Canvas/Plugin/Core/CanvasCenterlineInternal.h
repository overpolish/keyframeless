/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

@class KKBezierPath;

// A traced branch, fitted to cubic beziers (each entry an anchor + handles).
typedef struct {
  KKBezierPoint *pts;
  int count;
} CenterlineChain;

// Mask: rasterize a vector fill or an image silhouette into a 1px-padded binary
// grid (CanvasCenterlineMask.m).
uint8_t *CenterlineRasterize(KKBezierPath *path, CGFloat aspect,
                             int *outContentW, int *outContentH, int *outGridW,
                             int *outGridH, long *outFilled);
uint8_t *CenterlineBuildImageMask(KKBezierPath *src, CGFloat aspect,
                                  int *outContentW, int *outContentH,
                                  int *outGridW, int *outGridH,
                                  long *outFilled);

// Skeleton: thin, prune barbs, count, and trace into fitted branch chains
// (CanvasCenterlineSkeleton.m).
void CenterlineThin(uint8_t *g, int W, int H);
long CenterlineCountFg(const uint8_t *g, int W, int H);
void CenterlinePruneSpurs(uint8_t *g, int W, int H, int maxLen);
CenterlineChain *CenterlineTrace(const uint8_t *g, int W, int H, int contentW,
                                 int contentH, double thickPx, double rdpMult,
                                 double cornerCos, double fitMult,
                                 int *outCount, double *outSkelLen);

// Fit: dense object-space polyline -> cubic-bezier anchors
// (CanvasCenterlineFit.m).
BOOL CenterlineFitChain(const simd_float2 *P, int n, int contentW, int contentH,
                        double thickPx, double rdpMult, double cornerCos,
                        double fitMult, KKBezierPoint **outPts, int *outCount);
