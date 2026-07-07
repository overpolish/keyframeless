/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerCropEditor.h"

// Min crop extent as a fraction of the image, so handles stay grabbable.
static const CGFloat kMinCropFrac = 0.05;
static const CGFloat kHandleHitTolPt = 12.0;

// 8 crop handles in KKCropOSC order. y-up overlay points: "Top" == maxY.
typedef NS_ENUM(NSInteger, KKCropPt) {
  KKCropPt_TopLeft = 0,
  KKCropPt_TopCenter,
  KKCropPt_TopRight,
  KKCropPt_RightCenter,
  KKCropPt_BottomRight,
  KKCropPt_BottomCenter,
  KKCropPt_BottomLeft,
  KKCropPt_LeftCenter,
  KKCropPtCount
};

static CGPoint KKCropPointPos(NSInteger idx, CGRect r) {
  CGFloat minX = CGRectGetMinX(r), maxX = CGRectGetMaxX(r);
  CGFloat minY = CGRectGetMinY(r), maxY = CGRectGetMaxY(r);
  CGFloat mx = CGRectGetMidX(r), my = CGRectGetMidY(r);
  switch (idx) {
  case KKCropPt_TopLeft:
    return CGPointMake(minX, maxY);
  case KKCropPt_TopCenter:
    return CGPointMake(mx, maxY);
  case KKCropPt_TopRight:
    return CGPointMake(maxX, maxY);
  case KKCropPt_RightCenter:
    return CGPointMake(maxX, my);
  case KKCropPt_BottomRight:
    return CGPointMake(maxX, minY);
  case KKCropPt_BottomCenter:
    return CGPointMake(mx, minY);
  case KKCropPt_BottomLeft:
    return CGPointMake(minX, minY);
  case KKCropPt_LeftCenter:
    return CGPointMake(minX, my);
  }
  return CGPointZero;
}

static inline CGFloat KKClampF(CGFloat v, CGFloat lo, CGFloat hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

@implementation KKMiniViewerCropEditor {
  NSInteger _part;    // -1 none, 0 body, 1+idx handle
  CGRect _rectAtGrab; // overlay points, for rect-body translate
  CGPoint _grabPoint; // overlay points, for rect-body translate
}

- (instancetype)init {
  self = [super init];
  if (self)
    _part = -1;
  return self;
}

- (NSInteger)activePart {
  return _part;
}

// Crop box in overlay points (y-up). Model +y is up, but the mini viewer
// displays the shader output V-flipped, so the rendered crop-box centre
// lands at midY(cr) - y·height - match it so handles sit on the crop.
- (CGRect)cropRectForValues:(NSArray<NSNumber *> *)v contentRect:(CGRect)cr {
  if (v.count < 4)
    return CGRectZero;
  double w = v[0].doubleValue, h = v[1].doubleValue;
  double x = v[2].doubleValue, y = v[3].doubleValue;
  CGFloat cw = (CGFloat)w * cr.size.width;
  CGFloat ch = (CGFloat)h * cr.size.height;
  CGFloat midx = CGRectGetMidX(cr) + (CGFloat)x * cr.size.width;
  CGFloat midy = CGRectGetMidY(cr) - (CGFloat)y * cr.size.height;
  return CGRectMake(midx - cw / 2.0, midy - ch / 2.0, cw, ch);
}

- (NSArray<NSValue *> *)handleCentersForValues:(NSArray<NSNumber *> *)v
                                   contentRect:(CGRect)cr {
  CGRect R = [self cropRectForValues:v contentRect:cr];
  NSMutableArray<NSValue *> *pts =
      [NSMutableArray arrayWithCapacity:KKCropPtCount];
  for (NSInteger i = 0; i < KKCropPtCount; i++)
    [pts addObject:[NSValue valueWithPoint:KKCropPointPos(i, R)]];
  return pts;
}

- (NSInteger)partAtPoint:(CGPoint)p
                  values:(NSArray<NSNumber *> *)v
             contentRect:(CGRect)cr {
  CGRect R = [self cropRectForValues:v contentRect:cr];
  for (NSInteger i = 0; i < KKCropPtCount; i++) {
    CGPoint hp = KKCropPointPos(i, R);
    if (hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt)
      return 1 + i;
  }
  if (CGRectContainsPoint(R, p))
    return 0;
  return -1;
}

- (NSInteger)beginDragAtPoint:(CGPoint)p
                       values:(NSArray<NSNumber *> *)v
                  contentRect:(CGRect)cr {
  _part = [self partAtPoint:p values:v contentRect:cr];
  if (_part >= 0) {
    _rectAtGrab = [self cropRectForValues:v contentRect:cr];
    _grabPoint = p;
  }
  return _part;
}

- (void)endDrag {
  _part = -1;
}

- (NSArray<NSNumber *> *)valuesForDragToPoint:(CGPoint)p
                                  contentRect:(CGRect)cr {
  if (_part < 0 || cr.size.width <= 0 || cr.size.height <= 0)
    return nil;
  CGFloat crMinX = CGRectGetMinX(cr), crMaxX = CGRectGetMaxX(cr);
  CGFloat crMinY = CGRectGetMinY(cr), crMaxY = CGRectGetMaxY(cr);
  CGFloat minW = kMinCropFrac * cr.size.width;
  CGFloat minH = kMinCropFrac * cr.size.height;
  CGFloat minX, maxX, minY, maxY;

  if (_part == 0) {
    // Rect body: translate the grab-time rect, clamped within the image.
    CGRect R = _rectAtGrab;
    R.origin.x += p.x - _grabPoint.x;
    R.origin.y += p.y - _grabPoint.y;
    R.origin.x = KKClampF(R.origin.x, crMinX, crMaxX - R.size.width);
    R.origin.y = KKClampF(R.origin.y, crMinY, crMaxY - R.size.height);
    minX = CGRectGetMinX(R);
    maxX = CGRectGetMaxX(R);
    minY = CGRectGetMinY(R);
    maxY = CGRectGetMaxY(R);
  } else {
    // A corner/edge handle: move only its edge(s); the cursor is clamped to
    // the image so the crop can never exceed it.
    minX = _rectAtGrab.origin.x;
    maxX = CGRectGetMaxX(_rectAtGrab);
    minY = _rectAtGrab.origin.y;
    maxY = CGRectGetMaxY(_rectAtGrab);
    CGFloat px = KKClampF(p.x, crMinX, crMaxX);
    CGFloat py = KKClampF(p.y, crMinY, crMaxY);
    NSInteger idx = _part - 1;
    BOOL movedMinX = (idx == KKCropPt_TopLeft || idx == KKCropPt_BottomLeft ||
                      idx == KKCropPt_LeftCenter);
    BOOL movedMaxX = (idx == KKCropPt_TopRight || idx == KKCropPt_RightCenter ||
                      idx == KKCropPt_BottomRight);
    BOOL movedMinY =
        (idx == KKCropPt_BottomLeft || idx == KKCropPt_BottomCenter ||
         idx == KKCropPt_BottomRight);
    BOOL movedMaxY = (idx == KKCropPt_TopLeft || idx == KKCropPt_TopCenter ||
                      idx == KKCropPt_TopRight);
    if (movedMinX)
      minX = px;
    if (movedMaxX)
      maxX = px;
    if (movedMinY)
      minY = py;
    if (movedMaxY)
      maxY = py;
    // Keep min extent by pushing the edge that moved (never the anchor).
    if (maxX - minX < minW) {
      if (movedMinX)
        minX = maxX - minW;
      else
        maxX = minX + minW;
    }
    if (maxY - minY < minH) {
      if (movedMinY)
        minY = maxY - minH;
      else
        maxY = minY + minH;
    }
  }

  double w = KKClampF((maxX - minX) / cr.size.width, kMinCropFrac, 1.0);
  double h = KKClampF((maxY - minY) / cr.size.height, kMinCropFrac, 1.0);
  double x = KKClampF(((minX + maxX) * 0.5 - CGRectGetMidX(cr)) / cr.size.width,
                      -0.5, 0.5);
  // Inverse of cropRectForValues' flipped Y term.
  double y = KKClampF(
      (CGRectGetMidY(cr) - (minY + maxY) * 0.5) / cr.size.height, -0.5, 0.5);
  return @[ @(w), @(h), @(x), @(y) ];
}

@end
