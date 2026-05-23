/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineZoomPan.h"

#import "../Math/KKTimelineScale.h"

@implementation KKTimelineZoomPan

- (instancetype)init {
  self = [super init];
  if (self) {
    _zoom = 1.0;
    _panOffset = 0.0;
    _maxZoom = 20.0;
  }
  return self;
}

- (BOOL)isZoomed {
  return (_zoom > 1.0001) || (_panOffset > 0.0001);
}

- (BOOL)reset {
  if (_zoom == 1.0 && _panOffset == 0.0)
    return NO;
  _zoom = 1.0;
  _panOffset = 0.0;
  return YES;
}

- (BOOL)magnifyBy:(CGFloat)magnification atX:(CGFloat)x inRect:(NSRect)g {
  if (NSWidth(g) <= 0.0)
    return NO;
  double z = _zoom > 0.0 ? _zoom : 1.0;
  double uUnder = _panOffset + (x - NSMinX(g)) / (z * NSWidth(g));
  _zoom = MAX(1.0, MIN(_maxZoom, _zoom * (1.0 + magnification)));
  _panOffset = uUnder - (x - NSMinX(g)) / (_zoom * NSWidth(g));
  _panOffset = KKTimelineScaleClampPan(_panOffset, _zoom);
  return YES;
}

- (BOOL)panByScrollDeltaX:(CGFloat)dx precise:(BOOL)precise inRect:(NSRect)g {
  if (NSWidth(g) <= 0.0)
    return NO;
  double z = _zoom > 0.0 ? _zoom : 1.0;
  if (precise)
    _panOffset -= dx / (z * NSWidth(g));
  else
    _panOffset -= dx * 0.01 / z;
  _panOffset = KKTimelineScaleClampPan(_panOffset, _zoom);
  return YES;
}

@end
