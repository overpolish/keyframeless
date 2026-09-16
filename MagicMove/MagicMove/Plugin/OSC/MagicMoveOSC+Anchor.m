/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MagicMoveOSC+Anchor.h"
#import "Constants.h"
#import "MMAnchorPose.h"
#import <math.h>

// Vertex kind for the rounded-square glyph (see MMOSCShaderTypes.h).
static const float MMAnchorVertexKind = 3;

@implementation MagicMoveOSC (Anchor)

- (BOOL)anchorVisibleAtTime:(CMTime)time {
  BOOL cached = self.showAnchor;
  BOOL visible = [self visible:MMShowAnchorOSC cached:&cached atTime:time];
  self.showAnchor = cached;
  return visible;
}

- (BOOL)appendAnchorSquare:(NSMutableData *)vertices pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
                   surface:(CGSize)surface activePart:(NSInteger)activePart atTime:(CMTime)time {
  if (![self anchorVisibleAtTime:time]) return NO;
  BOOL active = activePart == OSCBoxPartAnchor || self.hoveredAnchor;
  float halfExtent = (float)OSCAnchorHalfExtent + (active ? MMOSCActiveGlyphGrowth : 0);
  CGPoint centre = [self pivotCanvasForPose:pose imageSize:imageSize];
  simd_float2 metalCentre = {(float)centre.x - (float)surface.width / 2,
                             (float)surface.height / 2 - (float)centre.y};
  // Room for the shadow, which falls below the square and blurs outward, plus
  // the anti-aliased edge.
  float pad = halfExtent + (float)(OSCAnchorShadowOffset + OSCAnchorShadowRadius) + 1.5f;
  // `local` runs screen-up, like the Metal position it is built from, so the
  // shader offsets the shadow the other way.
  const float sx[4] = {-pad, pad, -pad, pad}, sy[4] = {-pad, -pad, pad, pad};
  MMOSCVertex quad[4];
  for (int i = 0; i < 4; ++i)
    quad[i] = (MMOSCVertex){.position = {metalCentre.x + sx[i], metalCentre.y + sy[i]},
                            .local = {sx[i], sy[i]},
                            .shade = (float)OSCAnchorShadowOffset,
                            .kind = MMAnchorVertexKind,
                            .shape = {halfExtent, (float)OSCAnchorCornerRadius,
                                      (float)OSCAnchorOutlineWidth, (float)OSCAnchorShadowRadius},
                            .fill = MMOSCGlyphFill, .stroke = MMOSCGlyphStroke};
  const MMOSCVertex triangles[6] = {quad[0], quad[1], quad[2], quad[1], quad[3], quad[2]};
  [vertices appendBytes:triangles length:sizeof(triangles)];
  return YES;
}

- (BOOL)anchorAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize atTime:(CMTime)time {
  if (![self anchorVisibleAtTime:time]) return NO;
  CGPoint centre = [self pivotCanvasForPose:pose imageSize:imageSize];
  return hypot(x - centre.x, y - centre.y) <= OSCAnchorHitRadius;
}

- (void)beginAnchorDragAtTime:(CMTime)time {
  self.anchorCache = MMPropertyEditingCache(MMAnchorLane(), self.apiManager, time);
}

- (BOOL)dragAnchorFromPose:(OSCBoxPose)press byPixels:(CGPoint)deltaPixels atTime:(CMTime)time {
  BOOL explicitCreation = NO;
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (![get getBoolValue:&explicitCreation fromParameter:MMExplicitCreation atTime:time]) return NO;
  OSCBoxPose moved = OSCBoxPoseWithAnchorMovedBy(press, deltaPixels);
  return [MMAnchorLane() writeValues:@[@(moved.anchorX), @(moved.anchorY)]
                             manager:self.apiManager
                               cache:self.anchorCache
                                time:time
                            explicit:explicitCreation];
}

- (void)clearAnchorDrag { self.anchorCache = nil; }

@end
