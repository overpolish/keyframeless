/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveMiniCanvasRenderer.h"
#import <Metal/Metal.h>

NSString *const MagicMoveMiniCanvasDescriptorPath =
    @"/tmp/magicmove-minicanvas.json";
NSString *const MagicMoveMiniCanvasRequestPath =
    @"/tmp/magicmove-minicanvas-request.json";

static const CGFloat kHandleHitTolPt = 12.0;

@interface MagicMoveMiniCanvasRenderer () {
  KKSnapEngine *_snapEngine;
}
@end

@implementation MagicMoveMiniCanvasRenderer

- (instancetype)init {
  if ((self = [super init])) {
    _snapEngine = [[KKSnapEngine alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_snapEngine release];
  [super dealloc];
}

- (NSString *)pointLabel {
  return @"Position";
}

// MagicMove has no Crop lane - return nil so the base renderer doesn't try
// to draw the default crop corner handles (which were showing as a stray
// point in the bottom-left of the mini-canvas).
- (NSString *)cropLabel {
  return nil;
}

- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}

// Mini-canvas applies the Position translate so the preview reflects the
// edit instead of just blitting source unchanged. Pure blit copy with a
// pixel-space offset = no new shader needed. KKMiniCanvasView never clears
// `dest`, so we first clear via a render pass (avoids garbage on negative-
// offset corners) and then copy.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!source || !dest || !cb)
    return NO;

  // Clear dest to transparent first so areas the source doesn't cover after
  // translation don't show stale GPU memory.
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> clear =
      [cb renderCommandEncoderWithDescriptor:rpd];
  [clear endEncoding];

  NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  // Pixel-space offset. Position y=1 means "top" of clip (FCP OBJECT y-up),
  // and KKMiniCanvasView samples its processed texture y-up too (the vertex
  // setup maps tc.y=1 to the top of the view), so the row axis lines up:
  // increasing oy moves the image up.
  NSInteger W = (NSInteger)source.width;
  NSInteger H = (NSInteger)source.height;
  NSInteger ox = (NSInteger)llround((px - 0.5) * (double)W);
  NSInteger oy = (NSInteger)llround((py - 0.5) * (double)H);

  NSInteger srcX = MAX((NSInteger)0, -ox);
  NSInteger srcY = MAX((NSInteger)0, -oy);
  NSInteger dstX = MAX((NSInteger)0, ox);
  NSInteger dstY = MAX((NSInteger)0, oy);
  NSInteger copyW = MIN(W - srcX, (NSInteger)dest.width - dstX);
  NSInteger copyH = MIN(H - srcY, (NSInteger)dest.height - dstY);
  if (copyW <= 0 || copyH <= 0)
    return YES;

  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  [blit copyFromTexture:source
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake((NSUInteger)srcX, (NSUInteger)srcY, 0)
             sourceSize:MTLSizeMake((NSUInteger)copyW, (NSUInteger)copyH, 1)
              toTexture:dest
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake((NSUInteger)dstX, (NSUInteger)dstY, 0)];
  [blit endEncoding];
  return YES;
}

- (NSInteger)valueTypeForLabel:(NSString *)label {
  if ([label isEqualToString:@"Position"])
    return KKLaneValueTypeGeneric;
  return [super valueTypeForLabel:label];
}

- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  if ([label isEqualToString:@"Position"])
    return @[ @0.5, @0.5 ];
  return [super defaultValuesForLabel:label];
}

- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos {
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  return CGPointMake(CGRectGetMinX(cr) + px * cr.size.width,
                     CGRectGetMinY(cr) + py * cr.size.height);
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  *outCenter =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return YES;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)cr {
  // Position is 2D; no single-scalar guide target.
  return NO;
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint hp =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt;
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniCanvasView *)canvas {
  [self applyPointDragToPoint:p contentRect:cr canvas:canvas modifiers:0];
}

// Mirror of the viewer OSC snap: anchors at 0/0.25/0.5/0.75/1.0 plus every
// other keypose's stored position. Cmd bypasses (Canvas convention).
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniCanvasView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  if (!(modifiers & NSEventModifierFlagCommand)) {
    [self _snapPositionX:&nx Y:&ny contentRect:cr];
  } else {
    [_snapEngine reset];
  }
  [self commitValues:@[ @(nx), @(ny) ] forLabel:@"Position" canvas:canvas];
}

// Mini-canvas drag is also called via the delegate dispatcher in
// KKMiniCanvasView so the modifier variant takes precedence over the plain
// one.
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (![self pointHandleIsActive])
    return;
  [self applyPointDragToPoint:p
                  contentRect:cr
                       canvas:canvas
                    modifiers:modifiers];
}

- (void)_snapPositionX:(double *)nx Y:(double *)ny contentRect:(CGRect)cr {
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  // Snap threshold in mini-canvas view points; convert to normalized units
  // (per-axis since the mini may not be square).
  static const float kThreshPt = 6.0f;
  float thrX = cr.size.width > 0 ? kThreshPt / (float)cr.size.width : 0.01f;
  float thrY = cr.size.height > 0 ? kThreshPt / (float)cr.size.height : 0.01f;

  // Other keyposes on the Position lane. Identify the edited keypose by
  // closest-time match against editFraction (skipping by *value* would
  // unskip mid-drag the moment the edited keypose's value lines up with
  // another, producing a snap → unsnap → snap pingback).
  simd_float2 *objs = NULL;
  NSUInteger nObj = 0;
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:@"Position"])
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    NSInteger edited = -1;
    if (kps.count > 0) {
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - self.editFraction);
        if (d < bd) {
          bd = d;
          edited = k;
        }
      }
      objs = malloc(kps.count * sizeof(simd_float2));
    }
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      if (k == edited)
        continue;
      NSArray<NSNumber *> *v = kps[k].values;
      if (v.count < 2)
        continue;
      objs[nObj++] =
          (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
    }
    break;
  }
  simd_float2 snapped =
      [_snapEngine snapPoint:(simd_float2){(float)*nx, (float)*ny}
              canvasAnchorsX:anchors
                      countX:5
              canvasAnchorsY:anchors
                      countY:5
               objectTargets:objs
                       count:nObj
                  thresholdX:thrX
                  thresholdY:thrY];
  if (objs)
    free(objs);
  *nx = snapped.x;
  *ny = snapped.y;
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY {
  *hasX = _snapEngine.snappedX;
  *outX = (CGFloat)_snapEngine.snapValueX;
  *fromKeyposeX = _snapEngine.snapXFromObject;
  *hasY = _snapEngine.snappedY;
  *outY = (CGFloat)_snapEngine.snapValueY;
  *fromKeyposeY = _snapEngine.snapYFromObject;
}

- (void)miniCanvasEndHandleDrag:(KKMiniCanvasView *)canvas {
  [_snapEngine reset];
  [super miniCanvasEndHandleDrag:canvas];
}

@end
