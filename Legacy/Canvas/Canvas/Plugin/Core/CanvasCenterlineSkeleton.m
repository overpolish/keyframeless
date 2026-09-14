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

static const int kNX[8] = {0, 1, 1, 1, 0, -1, -1, -1}; // P2..P9 clockwise

static const int kNY[8] = {-1, -1, 0, 1, 1, 1, 0, -1};

// One Zhang-Suen sub-iteration (step 0 or 1). Returns the number of pixels
// removed so the caller can stop when the skeleton stops changing.
static long ZhangSuenPass(uint8_t *g, int W, int H, int step) {
  uint8_t *toClear = calloc((size_t)W * H, 1);
  if (!toClear)
    return 0;
  long removed = 0;
  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      if (!g[y * W + x])
        continue;
      int p[8];
      for (int k = 0; k < 8; k++)
        p[k] = g[(y + kNY[k]) * W + (x + kNX[k])] ? 1 : 0;
      int B = 0;
      for (int k = 0; k < 8; k++)
        B += p[k];
      if (B < 2 || B > 6)
        continue;
      int A = 0; // 0->1 transitions around the ring P2,P3,...,P9,P2
      for (int k = 0; k < 8; k++)
        if (p[k] == 0 && p[(k + 1) % 8] == 1)
          A++;
      if (A != 1)
        continue;
      // p[0]=P2(N) p[2]=P4(E) p[4]=P6(S) p[6]=P8(W)
      if (step == 0) {
        if (p[0] * p[2] * p[4] != 0)
          continue;
        if (p[2] * p[4] * p[6] != 0)
          continue;
      } else {
        if (p[0] * p[2] * p[6] != 0)
          continue;
        if (p[0] * p[4] * p[6] != 0)
          continue;
      }
      toClear[y * W + x] = 1;
    }
  }
  for (int i = 0; i < W * H; i++)
    if (toClear[i]) {
      g[i] = 0;
      removed++;
    }
  free(toClear);
  return removed;
}

void CenterlineThin(uint8_t *g, int W, int H) {
  long removed;
  int guard = 0;
  do {
    removed = ZhangSuenPass(g, W, H, 0);
    removed += ZhangSuenPass(g, W, H, 1);
  } while (removed > 0 && ++guard < 1000);
}

// Crossing number: 0->1 transitions around the ordered 8-ring (N,NE,E,...,NW).
// This is how skeleton pixels are correctly classified: 1 = endpoint,
// 2 = pass-through, >=3 = junction. Unlike a raw neighbour count it is immune
// to the diagonal "staircase" adjacencies that make a straight pixel look like
// a junction and shatter the trace into hundreds of fragments.
static inline int CenterlineCrossing(const uint8_t *g, int W, int x, int y) {
  int p[8];
  for (int k = 0; k < 8; k++)
    p[k] = g[(y + kNY[k]) * W + (x + kNX[k])] ? 1 : 0;
  int c = 0;
  for (int k = 0; k < 8; k++)
    if (!p[k] && p[(k + 1) % 8])
      c++;
  return c;
}

// Pick the next skeleton pixel while walking a corridor: a foreground
// 8-neighbour that isn't where we came from and (when `visited` is given)
// hasn't already been consumed, preferring an orthogonal (4-connected) step so
// we never skip a pixel across a diagonal staircase triangle. Skipping consumed
// pixels is what keeps a 2px-wide thinning artifact from splitting one path
// into two chains.
static BOOL CenterlineNextStep(const uint8_t *g, const uint8_t *visited, int W,
                               int cx, int cy, int px, int py, int *nx,
                               int *ny) {
  int diagX = -1, diagY = -1;
  for (int k = 0; k < 8; k++) {
    int ax = cx + kNX[k], ay = cy + kNY[k];
    if (!g[ay * W + ax] || (ax == px && ay == py))
      continue;
    if (visited && visited[ay * W + ax])
      continue;
    if (kNX[k] == 0 || kNY[k] == 0) { // orthogonal: take it immediately
      *nx = ax;
      *ny = ay;
      return YES;
    }
    if (diagX < 0) {
      diagX = ax;
      diagY = ay;
    }
  }
  if (diagX < 0)
    return NO;
  *nx = diagX;
  *ny = diagY;
  return YES;
}

long CenterlineCountFg(const uint8_t *g, int W, int H) {
  long n = 0;
  for (int i = 0; i < W * H; i++)
    n += g[i] ? 1 : 0;
  return n;
}

// Thinning a thick/rough blob leaves short barbs (spurs) hanging off the true
// skeleton; each one is a false branch that fragments the main centerline.
// Iteratively walk every endpoint (degree 1) to its first junction and erase
// the barb when it is shorter than maxLen px. Real branches (longer than
// maxLen, or ending at another endpoint) are kept.
void CenterlinePruneSpurs(uint8_t *g, int W, int H, int maxLen) {
  if (maxLen < 1)
    return;
  int *bx = malloc((size_t)(maxLen + 2) * sizeof(int));
  int *by = malloc((size_t)(maxLen + 2) * sizeof(int));
  BOOL changed = YES;
  int guard = 0;
  while (changed && ++guard < 256) {
    changed = NO;
    for (int y = 1; y < H - 1; y++) {
      for (int x = 1; x < W - 1; x++) {
        if (!g[y * W + x] || CenterlineCrossing(g, W, x, y) != 1)
          continue;
        // Walk the barb from this endpoint up to maxLen steps.
        int len = 0, px = -1, py = -1, cx = x, cy = y;
        bx[len] = cx;
        by[len] = cy;
        len++;
        BOOL hitJunction = NO;
        while (len <= maxLen) {
          int nxx = -1, nyy = -1;
          if (!CenterlineNextStep(g, NULL, W, cx, cy, px, py, &nxx, &nyy))
            break; // dead-end barb (isolated stub): leave it
          if (CenterlineCrossing(g, W, nxx, nyy) >= 3) {
            hitJunction = YES;
            break; // reached the junction - stop before it
          }
          px = cx;
          py = cy;
          cx = nxx;
          cy = nyy;
          bx[len] = cx;
          by[len] = cy;
          len++;
        }
        if (hitJunction && len <= maxLen) {
          for (int i = 0; i < len; i++)
            g[by[i] * W + bx[i]] = 0; // erase the barb (not the junction)
          changed = YES;
        }
      }
    }
  }
  free(bx);
  free(by);
}

// Map a grid pixel (1px padded) to object space (0-1, Y-up). The bitmap buffer
// is top-down (row 0 = top = max CG-y), so flip Y back to object space.
static inline simd_float2 CenterlinePixelToObject(int gx, int gy, int contentW,
                                                  int contentH) {
  float ox = ((float)(gx - 1) + 0.5f) / (float)contentW;
  float oy = 1.0f - ((float)(gy - 1) + 0.5f) / (float)contentH;
  return simd_make_float2(ox, oy);
}

// Trace the thinned skeleton into branch polylines (object space), splitting at
// endpoints (crossing 1) and junctions (crossing >= 3). *outSkelLen accumulates
// the total skeleton length in raster px (for the stroke-width estimate).
// Caller frees each chain's pts and the returned array.
CenterlineChain *CenterlineTrace(const uint8_t *g, int W, int H, int contentW,
                                 int contentH, double thickPx, double rdpMult,
                                 double cornerCos, double fitMult,
                                 int *outCount, double *outSkelLen) {
  uint8_t *visited = calloc((size_t)W * H, 1); // consumed degree-2 pixels
  __block CenterlineChain *chains = NULL;
  __block int chainCount = 0, chainCap = 0;
  simd_float2 *buf = malloc((size_t)W * H * sizeof(simd_float2));
  __block double skelLen = 0;
  if (!visited || !buf) {
    free(visited);
    free(buf);
    *outCount = 0;
    *outSkelLen = 0;
    return NULL;
  }

  void (^emit)(int) = ^(int n) {
    if (n < 2)
      return;
    KKBezierPoint *pts = NULL;
    int cnt = 0;
    if (!CenterlineFitChain(buf, n, contentW, contentH, thickPx, rdpMult,
                            cornerCos, fitMult, &pts, &cnt))
      return;
    if (chainCount == chainCap) {
      chainCap = chainCap ? chainCap * 2 : 8;
      chains = realloc(chains, (size_t)chainCap * sizeof(CenterlineChain));
    }
    chains[chainCount].pts = pts;
    chains[chainCount].count = cnt;
    chainCount++;
  };

  // Walk a pass-through corridor (crossing number 2) from node (nx,ny) through
  // neighbour (qx,qy) until the next node, filling buf (object space) and
  // accumulating raster length.
  int (^walk)(int, int, int, int) = ^int(int nx, int ny, int qx, int qy) {
    int n = 0;
    buf[n++] = CenterlinePixelToObject(nx, ny, contentW, contentH);
    int px = nx, py = ny, cx = qx, cy = qy;
    int guard = 0;
    while (++guard < W * H) {
      buf[n++] = CenterlinePixelToObject(cx, cy, contentW, contentH);
      skelLen += (px != cx && py != cy) ? 1.41421356 : 1.0;
      if (CenterlineCrossing(g, W, cx, cy) != 2)
        break; // reached a node (endpoint or junction)
      visited[cy * W + cx] = 1;
      int nxt_x = -1, nxt_y = -1;
      // visited-aware: never step onto a consumed pixel, so a 2px-wide spot
      // can't dead-end the walk and split the path.
      if (!CenterlineNextStep(g, visited, W, cx, cy, px, py, &nxt_x, &nxt_y))
        break;
      px = cx;
      py = cy;
      cx = nxt_x;
      cy = nxt_y;
    }
    return n;
  };

  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      if (!g[y * W + x])
        continue;
      if (CenterlineCrossing(g, W, x, y) == 2)
        continue; // start only from nodes (endpoints / junctions / isolated)
      for (int k = 0; k < 8; k++) {
        int qx = x + kNX[k], qy = y + kNY[k];
        if (!g[qy * W + qx])
          continue;
        if (CenterlineCrossing(g, W, qx, qy) != 2) {
          // Adjacent node: emit the 2-pixel edge once (lower index wins).
          if (y * W + x < qy * W + qx) {
            buf[0] = CenterlinePixelToObject(x, y, contentW, contentH);
            buf[1] = CenterlinePixelToObject(qx, qy, contentW, contentH);
            skelLen += (x != qx && y != qy) ? 1.41421356 : 1.0;
            emit(2);
          }
          continue;
        }
        if (visited[qy * W + qx])
          continue; // corridor already traced from the far node
        emit(walk(x, y, qx, qy));
      }
    }
  }

  // Pure loops: corridors with no node. Walk any remaining pass-through pixel.
  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      if (!g[y * W + x] || visited[y * W + x])
        continue;
      if (CenterlineCrossing(g, W, x, y) != 2)
        continue;
      int qx = -1, qy = -1;
      for (int k = 0; k < 8; k++)
        if (g[(y + kNY[k]) * W + (x + kNX[k])]) {
          qx = x + kNX[k];
          qy = y + kNY[k];
          break;
        }
      if (qx < 0)
        continue;
      visited[y * W + x] = 1;
      emit(walk(x, y, qx, qy));
    }
  }

  free(visited);
  free(buf);
  *outCount = chainCount;
  *outSkelLen = skelLen;
  return chains;
}
