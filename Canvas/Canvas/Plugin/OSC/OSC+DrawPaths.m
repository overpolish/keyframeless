/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "LayerList_Private.h"
#import "OSC_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (DrawPaths)

- (void)drawFilledPath:(KKBezierPath *)path
                 color:(simd_float4)color
      destinationImage:(FxImageTile *)dest {
  NSUInteger nc = path.contourCount;

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = dest.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:dest];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframelesskit.FillPreview"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"co.overpolish"
                                                ".keyframeless"
                                                ".KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!ps)
    return;

  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger cStart = r.location;
    NSUInteger cLen = r.length;
    if (cLen < 3)
      continue;

    NSUInteger segCount = cLen;
    NSUInteger maxPoints = segCount * 32 + 2;
    CGPoint *points = malloc(sizeof(CGPoint) * maxPoints);
    NSUInteger pointCount = 0;

    for (NSUInteger i = 0; i < segCount; i++) {
      NSUInteger idx = cStart + i;
      NSUInteger nextIdx = cStart + ((i + 1) % cLen);
      NSUInteger startS = (pointCount > 0 && i > 0) ? 1 : 0;
      for (NSUInteger s = startS; s <= 32; s++) {
        float t = (float)s / 32.0f;
        simd_float2 pos = [path evaluatePointAtIndex:idx
                                           nextIndex:nextIdx
                                                 atT:t];
        points[pointCount++] = [self canvasPointFromObjectPoint:pos];
      }
    }

    if (pointCount < 3) {
      free(points);
      continue;
    }

    float ioW = [dest.ioSurface width];
    float ioH = [dest.ioSurface height];

    // Build triangle fan from centroid.
    float cx = 0, cy = 0;
    for (NSUInteger i = 0; i < pointCount; i++) {
      cx += points[i].x;
      cy += points[i].y;
    }
    cx /= pointCount;
    cy /= pointCount;

    simd_float2 center = {(float)(cx - ioW / 2.0), (float)(ioH / 2.0 - cy)};

    NSUInteger triCount = pointCount;
    NSUInteger vertCount = triCount * 3;
    KKVertex2D *verts = malloc(sizeof(KKVertex2D) * vertCount);
    for (NSUInteger i = 0; i < triCount; i++) {
      NSUInteger next = (i + 1) % pointCount;
      simd_float2 a = {(float)(points[i].x - ioW / 2.0),
                       (float)(ioH / 2.0 - points[i].y)};
      simd_float2 b = {(float)(points[next].x - ioW / 2.0),
                       (float)(ioH / 2.0 - points[next].y)};
      verts[i * 3 + 0] = (KKVertex2D){center, {0, 0}};
      verts[i * 3 + 1] = (KKVertex2D){a, {0, 0}};
      verts[i * 3 + 2] = (KKVertex2D){b, {0, 0}};
    }

    simd_float4 fillColor = color;
    id<MTLRenderPipelineState> fillPS = ps;

    [self
        encodeRenderCommandsForDestinationImage:dest
                                 canvasPosition:CGPointZero
                               clearDestination:NO
                                       commands:^(
                                           id<MTLRenderCommandEncoder> encoder,
                                           CGPoint metalPosition,
                                           simd_uint2 viewportSize) {
                                         [encoder
                                             setRenderPipelineState:fillPS];
                                         NSUInteger byteLen =
                                             sizeof(KKVertex2D) * vertCount;
                                         if (byteLen <= 4096) {
                                           [encoder
                                               setVertexBytes:verts
                                                       length:byteLen
                                                      atIndex:
                                                          KKVertexInputIndex_Vertices];
                                         } else {
                                           id<MTLDevice> dev = encoder.device;
                                           id<MTLBuffer> buf = [dev
                                               newBufferWithBytes:verts
                                                           length:byteLen
                                                          options:
                                                              MTLResourceStorageModeShared];
                                           [encoder
                                               setVertexBuffer:buf
                                                        offset:0
                                                       atIndex:
                                                           KKVertexInputIndex_Vertices];
                                         }
                                         [encoder
                                             setFragmentBytes:&fillColor
                                                       length:sizeof(fillColor)
                                                      atIndex:0];
                                         [encoder drawPrimitives:
                                                      MTLPrimitiveTypeTriangle
                                                     vertexStart:0
                                                     vertexCount:vertCount];
                                       }];
    free(verts);
    free(points);
  }
}

- (void)drawPathSegmentsWithWidth:(KKBezierPath *)path
                            color:(simd_float4)color
                        halfWidth:(float)halfWidth
                 destinationImage:(FxImageTile *)dest {
  NSUInteger nc = path.contourCount;

  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger cStart = r.location;
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;

    BOOL contourClosed = path.closed;
    NSUInteger segCount = contourClosed ? cLen : (cLen - 1);
    NSUInteger maxPoints = segCount * 32 + 2;
    CGPoint *points = malloc(sizeof(CGPoint) * maxPoints);
    NSUInteger pointCount = 0;

    for (NSUInteger i = 0; i < segCount; i++) {
      NSUInteger idx = cStart + i;
      NSUInteger nextIdx = cStart + ((i + 1) % cLen);
      NSUInteger startS = (pointCount > 0 && i > 0) ? 1 : 0;
      for (NSUInteger s = startS; s <= 32; s++) {
        float t = (float)s / 32.0f;
        simd_float2 pos = [path evaluatePointAtIndex:idx
                                           nextIndex:nextIdx
                                                 atT:t];
        points[pointCount++] = [self canvasPointFromObjectPoint:pos];
      }
    }
    if (contourClosed && pointCount > 0) {
      simd_float2 firstPos = [path evaluatePointAtIndex:cStart
                                              nextIndex:cStart + 1
                                                    atT:0.0f];
      points[pointCount++] = [self canvasPointFromObjectPoint:firstPos];
    }

    [self drawLineStripWithPoints:points
                            count:pointCount
                            color:color
                        halfWidth:halfWidth
                 destinationImage:dest];
    free(points);
  }
}

- (void)drawPathSegments:(KKBezierPath *)path
                   color:(simd_float4)color
        destinationImage:(FxImageTile *)dest {
  NSUInteger nc = path.contourCount;

  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger cStart = r.location;
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;

    BOOL contourClosed = path.closed;
    NSUInteger segCount = contourClosed ? cLen : (cLen - 1);
    NSUInteger maxPoints = segCount * 32 + 2;
    CGPoint *points = malloc(sizeof(CGPoint) * maxPoints);
    NSUInteger pointCount = 0;

    for (NSUInteger i = 0; i < segCount; i++) {
      NSUInteger idx = cStart + i;
      NSUInteger nextIdx = cStart + ((i + 1) % cLen);
      NSUInteger startS = (pointCount > 0 && i > 0) ? 1 : 0;
      for (NSUInteger s = startS; s <= 32; s++) {
        float t = (float)s / 32.0f;
        simd_float2 pos = [path evaluatePointAtIndex:idx
                                           nextIndex:nextIdx
                                                 atT:t];
        points[pointCount++] = [self canvasPointFromObjectPoint:pos];
      }
    }
    if (contourClosed && pointCount > 0) {
      simd_float2 firstPos = [path evaluatePointAtIndex:cStart
                                              nextIndex:cStart + 1
                                                    atT:0.0f];
      points[pointCount++] = [self canvasPointFromObjectPoint:firstPos];
    }

    [self drawLineStripWithPoints:points
                            count:pointCount
                            color:color
                        halfWidth:1.5f
                 destinationImage:dest];
    free(points);
  }
}

- (BOOL)isPointVisuallySelected:(NSUInteger)pathIndex
                          point:(NSUInteger)i
                    canvasPoint:(CGPoint)ptCanvas {
  BOOL selected = [self isPointSelected:pathIndex point:i];
  if (self.dragIsMarquee) {
    CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
    CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);
    BOOL inside = (ptCanvas.x >= minX && ptCanvas.x <= maxX &&
                   ptCanvas.y >= minY && ptCanvas.y <= maxY);
    CGEventFlags mf =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL optHeld = (mf & kCGEventFlagMaskAlternate) != 0;
    if (inside)
      selected = !optHeld;
  }
  return selected;
}

@end
#pragma clang diagnostic pop
