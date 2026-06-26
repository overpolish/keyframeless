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

// Fitting runs in double precision (object coords are tiny, ~0-1) for stable
// Newton-Raphson reparameterisation; handles are cast back to float on output.
typedef simd_double2 P2;

typedef struct {
  P2 (*segs)[4]; // each cubic: p0, c1, c2, p3
  int count;
  int cap;
} CenterlineSegList;

static void CenterlineSegPush(CenterlineSegList *L, const P2 bez[4]) {
  if (L->count == L->cap) {
    L->cap = L->cap ? L->cap * 2 : 8;
    L->segs = realloc(L->segs, (size_t)L->cap * sizeof(P2[4]));
  }
  for (int i = 0; i < 4; i++)
    L->segs[L->count][i] = bez[i];
  L->count++;
}

static P2 CenterlineBezierEval(int degree, const P2 *V, double t) {
  P2 tmp[4];
  for (int i = 0; i <= degree; i++)
    tmp[i] = V[i];
  for (int i = 1; i <= degree; i++)
    for (int j = 0; j <= degree - i; j++)
      tmp[j] = (1.0 - t) * tmp[j] + t * tmp[j + 1];
  return tmp[0];
}

static inline P2 CenterlineNormalize(P2 v) {
  double l = simd_length(v);
  return l > 1e-12 ? v / l : v;
}

static double CenterlineB0(double u) {
  double t = 1 - u;
  return t * t * t;
}

static double CenterlineB1(double u) {
  double t = 1 - u;
  return 3 * u * t * t;
}

static double CenterlineB2(double u) {
  double t = 1 - u;
  return 3 * u * u * t;
}

static double CenterlineB3(double u) { return u * u * u; }

static double *CenterlineChordParam(const P2 *d, int first, int last) {
  int n = last - first + 1;
  double *u = malloc((size_t)n * sizeof(double));
  u[0] = 0.0;
  for (int i = 1; i < n; i++)
    u[i] = u[i - 1] + simd_length(d[first + i] - d[first + i - 1]);
  if (u[n - 1] > 1e-12)
    for (int i = 1; i < n; i++)
      u[i] /= u[n - 1];
  return u;
}

static void CenterlineGenBezier(const P2 *d, int first, int last,
                                const double *uPrime, P2 tHat1, P2 tHat2,
                                P2 bez[4]) {
  int n = last - first + 1;
  // Least-squares solve for the two handle lengths (Graphics Gems).
  double c00 = 0, c01 = 0, c11 = 0, x0 = 0, x1 = 0;
  for (int i = 0; i < n; i++) {
    P2 a0 = tHat1 * CenterlineB1(uPrime[i]);
    P2 a1 = tHat2 * CenterlineB2(uPrime[i]);
    c00 += simd_dot(a0, a0);
    c01 += simd_dot(a0, a1);
    c11 += simd_dot(a1, a1);
    P2 base = d[first] * (CenterlineB0(uPrime[i]) + CenterlineB1(uPrime[i])) +
              d[last] * (CenterlineB2(uPrime[i]) + CenterlineB3(uPrime[i]));
    P2 tmp = d[first + i] - base;
    x0 += simd_dot(a0, tmp);
    x1 += simd_dot(a1, tmp);
  }
  double detCC = c00 * c11 - c01 * c01;
  double detCX = c00 * x1 - c01 * x0;
  double detXC = x0 * c11 - x1 * c01;
  double alphaL = fabs(detCC) < 1e-18 ? 0 : detXC / detCC;
  double alphaR = fabs(detCC) < 1e-18 ? 0 : detCX / detCC;
  double segLen = simd_length(d[last] - d[first]);
  double eps = 1e-6 * segLen;
  if (alphaL < eps || alphaR < eps)
    alphaL = alphaR = segLen / 3.0; // degenerate: Wu-Barsky heuristic
  bez[0] = d[first];
  bez[3] = d[last];
  bez[1] = d[first] + tHat1 * alphaL;
  bez[2] = d[last] + tHat2 * alphaR;
}

static double CenterlineNewton(const P2 Q[4], P2 P, double u) {
  P2 Q1[3], Q2[2];
  for (int i = 0; i < 3; i++)
    Q1[i] = (Q[i + 1] - Q[i]) * 3.0;
  for (int i = 0; i < 2; i++)
    Q2[i] = (Q1[i + 1] - Q1[i]) * 2.0;
  P2 qu = CenterlineBezierEval(3, Q, u);
  P2 q1 = CenterlineBezierEval(2, Q1, u);
  P2 q2 = CenterlineBezierEval(1, Q2, u);
  double num = simd_dot(qu - P, q1);
  double den = simd_dot(q1, q1) + simd_dot(qu - P, q2);
  return fabs(den) < 1e-18 ? u : u - num / den;
}

static double CenterlineMaxError(const P2 *d, int first, int last,
                                 const P2 bez[4], const double *u,
                                 int *splitPoint) {
  *splitPoint = (last - first + 1) / 2 + first;
  double maxDist = 0;
  for (int i = first + 1; i < last; i++) {
    P2 p = CenterlineBezierEval(3, bez, u[i - first]);
    double dist = simd_length_squared(p - d[i]);
    if (dist >= maxDist) {
      maxDist = dist;
      *splitPoint = i;
    }
  }
  return maxDist;
}

// Backward (toward `first`) unit tangent at `center`, averaged over a window so
// single-pixel staircase steps don't tilt it.
static P2 CenterlineCenterTangent(const P2 *d, int center, int first,
                                  int last) {
  int lo = center - 6, hi = center + 6;
  if (lo < first)
    lo = first;
  if (hi > last)
    hi = last;
  return CenterlineNormalize(d[lo] - d[hi]);
}

// Recursively fit cubics to d[first..last] within errSq (squared object-space
// tolerance), pushing each accepted segment to L.
static void CenterlineFitCubic(const P2 *d, int first, int last, P2 tHat1,
                               P2 tHat2, double errSq, CenterlineSegList *L) {
  if (last - first == 1) {
    double dist = simd_length(d[last] - d[first]) / 3.0;
    P2 bez[4] = {d[first], d[first] + tHat1 * dist, d[last] + tHat2 * dist,
                 d[last]};
    CenterlineSegPush(L, bez);
    return;
  }
  double *u = CenterlineChordParam(d, first, last);
  P2 bez[4];
  CenterlineGenBezier(d, first, last, u, tHat1, tHat2, bez);
  int split = 0;
  double maxErr = CenterlineMaxError(d, first, last, bez, u, &split);
  if (maxErr < errSq) {
    CenterlineSegPush(L, bez);
    free(u);
    return;
  }
  if (maxErr < errSq * 4.0) {
    for (int iter = 0; iter < 4; iter++) {
      double *uPrime = malloc((size_t)(last - first + 1) * sizeof(double));
      for (int i = first; i <= last; i++)
        uPrime[i - first] = CenterlineNewton(bez, d[i], u[i - first]);
      CenterlineGenBezier(d, first, last, uPrime, tHat1, tHat2, bez);
      maxErr = CenterlineMaxError(d, first, last, bez, uPrime, &split);
      free(u);
      u = uPrime;
      if (maxErr < errSq) {
        CenterlineSegPush(L, bez);
        free(u);
        return;
      }
    }
  }
  free(u);
  P2 tHatC = CenterlineCenterTangent(d, split, first, last);
  CenterlineFitCubic(d, first, split, tHat1, tHatC, errSq, L);
  CenterlineFitCubic(d, split, last, -tHatC, tHat2, errSq, L);
}

typedef struct {
  KKBezierPoint *pts;
  int count, cap;
} CenterlinePtList;

static void CenterlinePtPush(CenterlinePtList *V, P2 pos, P2 in, P2 out,
                             uint32_t type) {
  if (V->count == V->cap) {
    V->cap = V->cap ? V->cap * 2 : 16;
    V->pts = realloc(V->pts, (size_t)V->cap * sizeof(KKBezierPoint));
  }
  KKBezierPoint kp = {(float)pos.x, (float)pos.y, (float)in.x, (float)in.y,
                      (float)out.x, (float)out.y, type};
  V->pts[V->count++] = kp;
}

// Append one run's fitted cubics as anchors+handles. The run's first anchor is
// shared with the previous run's last anchor (a corner): set its out-handle in
// place rather than pushing a duplicate. `firstRun` pushes the very first
// anchor of the whole chain.
static void CenterlineAppendRun(CenterlinePtList *V, const P2 (*segs)[4],
                                int segCount, BOOL firstRun) {
  if (segCount == 0)
    return;
  if (firstRun)
    CenterlinePtPush(V, segs[0][0], simd_make_double2(0, 0),
                     simd_make_double2(0, 0), KKBezierPointBezier);
  for (int j = 0; j < segCount; j++) {
    KKBezierPoint *last = &V->pts[V->count - 1];
    P2 out = segs[j][1] - segs[j][0];
    last->outX = (float)out.x;
    last->outY = (float)out.y;
    last->type = KKBezierPointBezier;
    P2 in = segs[j][2] - segs[j][3];
    CenterlinePtPush(V, segs[j][3], in, simd_make_double2(0, 0),
                     KKBezierPointBezier);
  }
}

// Ramer-Douglas-Peucker on double points; marks indices to keep. Drops vertices
// within `eps` of the chord (skeleton wobble) while keeping the points that
// define real curvature and corners - unlike averaging it never rounds a corner
// or flattens an arc.
static void CenterlineRDP(const P2 *pts, int s, int e, double eps,
                          uint8_t *keep) {
  if (e <= s + 1)
    return;
  P2 a = pts[s], b = pts[e], ab = b - a;
  double abLen = simd_length(ab);
  double maxD = 0;
  int maxI = s;
  for (int i = s + 1; i < e; i++) {
    double dd;
    if (abLen < 1e-12)
      dd = simd_length(pts[i] - a);
    else {
      P2 ap = pts[i] - a;
      dd = fabs(ap.x * ab.y - ap.y * ab.x) / abLen;
    }
    if (dd > maxD) {
      maxD = dd;
      maxI = i;
    }
  }
  if (maxD > eps) {
    keep[maxI] = 1;
    CenterlineRDP(pts, s, maxI, eps, keep);
    CenterlineRDP(pts, maxI, e, eps, keep);
  }
}

// Fit a dense object-space polyline (float) to cubic beziers, preserving sharp
// corners (split the fit there so each side keeps its own tangent). Returns a
// malloc'd KKBezierPoint array, or NO if nothing usable. rdpMult/cornerCos/
// fitMult are the per-detail-level knobs (RDP denoise tol, corner turn cosine,
// fit tolerance), all relative to the ribbon thickness.
// Max perpendicular deviation (content px) of a run d[a..b] from its chord.
// Near zero -> the run is straight and should be a line, not a wobble-following
// cubic.
static double CenterlineRunDeviation(const P2 *d, int a, int b, int contentW,
                                     int contentH) {
  P2 A = simd_make_double2(d[a].x * contentW, d[a].y * contentH);
  P2 B = simd_make_double2(d[b].x * contentW, d[b].y * contentH);
  P2 ab = B - A;
  double abLen = simd_length(ab);
  double maxD = 0;
  for (int i = a + 1; i < b; i++) {
    P2 Pi = simd_make_double2(d[i].x * contentW, d[i].y * contentH);
    double dev = abLen < 1e-9
                     ? simd_length(Pi - A)
                     : fabs((Pi.x - A.x) * ab.y - (Pi.y - A.y) * ab.x) / abLen;
    if (dev > maxD)
      maxD = dev;
  }
  return maxD;
}

BOOL CenterlineFitChain(const simd_float2 *P, int n, int contentW, int contentH,
                        double thickPx, double rdpMult, double cornerCos,
                        double fitMult, KKBezierPoint **outPts, int *outCount) {
  if (n < 2)
    return NO;
  if (n == 2) {
    KKBezierPoint *pts = malloc(2 * sizeof(KKBezierPoint));
    pts[0] = (KKBezierPoint){P[0].x, P[0].y, 0, 0, 0, 0, KKBezierPointLinear};
    pts[1] = (KKBezierPoint){P[1].x, P[1].y, 0, 0, 0, 0, KKBezierPointLinear};
    *outPts = pts;
    *outCount = 2;
    return YES;
  }
  P2 *d = malloc((size_t)n * sizeof(P2));
  for (int i = 0; i < n; i++)
    d[i] = simd_make_double2(P[i].x, P[i].y);

  // RDP only LOCATES the significant vertices (drops sub-tolerance wobble); the
  // fit runs on the DENSE polyline so tangents/curvature stay accurate. The
  // 0.8px floor is just above staircase noise, so thin shapes keep fine detail
  // (the thickness term dominates on thick shapes, where the floor is
  // irrelevant).
  double tol = fmax(0.8, thickPx * rdpMult) / (double)contentH;
  uint8_t *keep = calloc((size_t)n, 1);
  keep[0] = 1;
  keep[n - 1] = 1;
  CenterlineRDP(d, 0, n - 1, tol, keep);
  int *K = malloc((size_t)n * sizeof(int));
  int m = 0;
  for (int i = 0; i < n; i++)
    if (keep[i])
      K[m++] = i;
  free(keep);

  // A corner is a turn sharper than cornerCos at an RDP vertex; split the fit
  // there so each leg keeps its own tangent. Gentler turns stay in one smooth
  // run. Corner indices are DENSE indices.
  int *corners = malloc((size_t)(m + 2) * sizeof(int));
  int cc = 0;
  corners[cc++] = 0;
  for (int j = 1; j < m - 1; j++) {
    P2 a = CenterlineNormalize(d[K[j]] - d[K[j - 1]]);
    P2 b = CenterlineNormalize(d[K[j + 1]] - d[K[j]]);
    if (simd_dot(a, b) < cornerCos)
      corners[cc++] = K[j];
  }
  corners[cc++] = n - 1;
  free(K);

  // Fit the RAW skeleton with a generous tolerance so a smooth run stays a
  // SINGLE least-squares cubic: least-squares averages the wander while keeping
  // the macro bulge. A real corner / pronounced S exceeds tolerance and splits.
  double fitTol = fmax(1.2, thickPx * fitMult) / (double)contentH;
  double errSq = fitTol * fitTol;
  int tw = (int)lround(thickPx * 0.25);
  if (tw < 6)
    tw = 6;
  CenterlinePtList V = {0};
  for (int r = 0; r + 1 < cc; r++) {
    int a = corners[r], b = corners[r + 1];
    if (b <= a)
      continue;
    // Window endpoint tangents over ~a quarter thickness so a single staircase
    // step can't tilt them (which elbowed the arc earlier).
    CenterlineSegList L = {0};
    // Straight run -> a clean line (a straight cubic with collinear handles),
    // not a cubic that chases skeleton wobble (which makes straight edges
    // sketchy and bows the L's legs). Threshold ~a fifth of the thickness; a
    // real curve (arc, Texas's bottom) deviates well past it and fits as a
    // bezier.
    double dev = CenterlineRunDeviation(d, a, b, contentW, contentH);
    if (dev < fmax(1.5, thickPx * 0.2)) {
      P2 chord = d[b] - d[a];
      P2 bez[4] = {d[a], d[a] + chord * (1.0 / 3.0), d[b] - chord * (1.0 / 3.0),
                   d[b]};
      CenterlineSegPush(&L, bez);
    } else {
      // Window endpoint tangents over ~a quarter thickness so a single
      // staircase step can't tilt them (which elbowed the arc earlier).
      int af = a + tw > b ? b : a + tw;
      int bb = b - tw < a ? a : b - tw;
      P2 tHat1 = CenterlineNormalize(d[af] - d[a]);
      P2 tHat2 = CenterlineNormalize(d[bb] - d[b]);
      CenterlineFitCubic(d, a, b, tHat1, tHat2, errSq, &L);
    }
    CenterlineAppendRun(&V, L.segs, L.count, r == 0);
    free(L.segs);
  }
  free(corners);
  free(d);
  if (V.count < 2) {
    free(V.pts);
    return NO;
  }

  *outPts = V.pts;
  *outCount = V.count;
  return YES;
}
