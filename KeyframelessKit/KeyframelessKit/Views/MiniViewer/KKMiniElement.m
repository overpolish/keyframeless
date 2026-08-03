/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniElement.h"

@implementation KKMiniElement

- (instancetype)init {
  if ((self = [super init])) {
    _alpha = 1.0;
    _sizeScale = 1.0;
  }
  return self;
}

+ (instancetype)glyphAt:(CGPoint)center
                  style:(NSInteger)style
                  alpha:(CGFloat)alpha {
  KKMiniElement *e = [[self alloc] init];
  e.kind = KKMiniElementKindGlyph;
  e.center = center;
  e.style = style;
  e.alpha = alpha;
  return e;
}

+ (instancetype)boxWithRect:(CGRect)rect
              handleCenters:(NSArray<NSValue *> *)handleCenters
                    readout:(NSString *)readout
                      alpha:(CGFloat)alpha {
  KKMiniElement *e = [[self alloc] init];
  e.kind = KKMiniElementKindBox;
  e.rect = rect;
  e.handleCenters = handleCenters;
  e.readout = readout;
  e.alpha = alpha;
  return e;
}

+ (instancetype)ringAt:(CGPoint)center
               radiusX:(CGFloat)radiusX
               radiusY:(CGFloat)radiusY
              emphasis:(NSInteger)emphasis
                 alpha:(CGFloat)alpha {
  KKMiniElement *e = [[self alloc] init];
  e.kind = KKMiniElementKindRing;
  e.center = center;
  e.radiusX = radiusX;
  e.radiusY = radiusY;
  e.emphasis = emphasis;
  e.alpha = alpha;
  return e;
}

+ (instancetype)rotationAt:(CGPoint)center
                  radiusPx:(CGFloat)radiusPx
                    params:(KKRotationOSCParams)params {
  KKMiniElement *e = [[self alloc] init];
  e.kind = KKMiniElementKindRotation;
  e.center = center;
  e.radiusPx = radiusPx;
  e.rotationParams = params;
  return e;
}

+ (instancetype)motionPathWithPolyline:(NSArray<NSValue *> *)polyline
                        handleSegments:(NSArray<NSValue *> *)handleSegments
                               anchors:(NSArray<NSValue *> *)anchors
                                 alpha:(CGFloat)alpha {
  KKMiniElement *e = [[self alloc] init];
  e.kind = KKMiniElementKindMotionPath;
  e.polyline = polyline;
  e.handleSegments = handleSegments;
  e.anchors = anchors;
  e.alpha = alpha;
  return e;
}

@end
