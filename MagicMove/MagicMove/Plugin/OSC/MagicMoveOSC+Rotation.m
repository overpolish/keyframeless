/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MagicMoveOSC+Rotation.h"
#import "Constants.h"
#import "MMInspectorColors.h"
#import "MMRotationPose.h"
#import <AppKit/AppKit.h>

static const double MMDegreesToRadians = M_PI / 180;
static const float MMRingDragBoost = 0.35f;
static const float MMRingHoverBoost = 0.15f;

// The pose the rings draw and drag in: the render's own Rz*Ry*Rx projection, so
// a ring lies where that axis' turn actually shows on screen.
static OSCRotationMatrix3 MMRingMatrix(OSCBoxPose pose) {
  return OSCRotationMatrixFromEuler(pose.rotationX * MMDegreesToRadians,
                                    pose.rotationY * MMDegreesToRadians,
                                    pose.rotation * MMDegreesToRadians);
}

static simd_float4 MMRingColor(NSColor *color) {
  NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!srgb) return (simd_float4){1, 1, 1, 1};
  CGFloat r = 0, g = 0, b = 0, a = 0;
  [srgb getRed:&r green:&g blue:&b alpha:&a];
  // The shader composites premultiplied fills, like the handle glyphs.
  return (simd_float4){(float)(r * a), (float)(g * a), (float)(b * a), (float)a};
}

@implementation MagicMoveOSC (Rotation)

- (BOOL)ringsVisibleAtTime:(CMTime)time {
  BOOL cached = self.showRings;
  BOOL visible = [self visible:MMShowRotationOSC cached:&cached atTime:time];
  self.showRings = cached;
  return visible;
}

- (BOOL)ringQuad:(MMOSCVertex[6])quad params:(MMOSCRingParams *)params pose:(OSCBoxPose)pose
       imageSize:(CGSize)imageSize surface:(CGSize)surface activePart:(NSInteger)activePart
          atTime:(CMTime)time {
  if (![self ringsVisibleAtTime:time]) return NO;
  OSCRotationMatrix3 matrix = MMRingMatrix(pose);
  NSArray<NSColor *> *colors = MMInspectorColors(MMRotationControls);
  if (colors.count < OSCRingCount) return NO;
  NSInteger dragged = activePart >= OSCBoxPartRingBase && activePart < OSCBoxPartAnchor
                          ? activePart - OSCBoxPartRingBase : -1;
  *params = (MMOSCRingParams){
      .outlineColor = {0, 0, 0, 0.75f},
      .radius = (float)OSCRingRadius,
      .ringHalfWidth = (float)OSCRingHalfWidth,
      .outlineWidth = (float)OSCRingOutlineWidth,
      .backDim = (float)OSCRingBackDim,
      .activeRing = (int)(dragged >= 0 ? dragged : self.hoveredRing),
      .activeBoost = dragged >= 0 ? MMRingDragBoost : (self.hoveredRing >= 0 ? MMRingHoverBoost : 0),
  };
  for (int axis = 0; axis < OSCRingCount; ++axis) {
    double u[3], v[3];
    OSCRingBasis(matrix, axis, u, v);
    params->ringU[axis] = (simd_float3){(float)u[0], (float)u[1], (float)u[2]};
    params->ringV[axis] = (simd_float3){(float)v[0], (float)v[1], (float)v[2]};
    params->ringColor[axis] = MMRingColor(colors[axis]);
  }
  // A quad big enough for the outermost ring pixels plus the anti-aliased edge.
  float half = (float)(OSCRingRadius + OSCRingHalfWidth + OSCRingOutlineWidth + 2);
  CGPoint centre = [self pivotCanvasForPose:pose imageSize:imageSize];
  simd_float2 metalCentre = {(float)centre.x - (float)surface.width / 2,
                             (float)surface.height / 2 - (float)centre.y};
  // `local` runs Y up like the ring geometry, which is Metal's Y flipped.
  const float ox[4] = {-half, half, -half, half}, oy[4] = {-half, -half, half, half};
  MMOSCVertex corners[4];
  for (int i = 0; i < 4; ++i)
    corners[i] = (MMOSCVertex){.position = {metalCentre.x + ox[i], metalCentre.y - oy[i]},
                               .local = {ox[i], oy[i]}};
  const MMOSCVertex triangles[6] = {corners[0], corners[1], corners[2],
                                    corners[1], corners[3], corners[2]};
  for (int i = 0; i < 6; ++i) quad[i] = triangles[i];
  return YES;
}

- (NSInteger)ringAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
              cursor:(MMOSCCursorKind *)cursor atTime:(CMTime)time {
  *cursor = MMOSCCursorArrow;
  if (![self ringsVisibleAtTime:time]) return -1;
  OSCRotationMatrix3 matrix = MMRingMatrix(pose);
  CGPoint centre = [self pivotCanvasForPose:pose imageSize:imageSize];
  CGPoint local = CGPointMake(x - centre.x, y - centre.y);
  NSInteger best = -1;
  double bestDistance = INFINITY, bestAngle = 0;
  // Strictly closer wins, so where an edge-on ring crosses another the earlier
  // axis takes the pixel in both the shader and here.
  for (int axis = 0; axis < OSCRingCount; ++axis) {
    OSCRingHit hit = OSCRingClosestAngle(matrix, axis, OSCRingRadius, local, OSCRingHitSamples);
    if (hit.frontDistance >= bestDistance) continue;
    bestDistance = hit.frontDistance;
    bestAngle = hit.frontAngle;
    best = axis;
  }
  if (best < 0 || bestDistance > OSCRingHitRadius) return -1;
  if (best == OSCRingAxisZ) {
    // Z spins in the screen plane, so the rotate cursor reads the hover
    // quadrant. X and Y drag along their ring, so they follow its tangent,
    // which stays correct however the gizmo is tilted.
    *cursor = MMRotateCursorKindForAngle(atan2(local.y, local.x));
  } else {
    double tangentX = 0, tangentY = 0;
    OSCRingScreenTangent(matrix, (int)best, bestAngle, &tangentX, &tangentY);
    *cursor = MMResizeCursorKindForAngle(atan2(tangentY, tangentX));
  }
  return best;
}

- (BOOL)beginRingDragAtX:(double)x y:(double)y part:(NSInteger)part pose:(OSCBoxPose)pose
               imageSize:(CGSize)imageSize atTime:(CMTime)time {
  NSInteger axis = part - OSCBoxPartRingBase;
  if (axis < 0 || axis >= OSCRingCount) return NO;
  OSCRotationMatrix3 matrix = MMRingMatrix(pose);
  CGPoint centre = [self pivotCanvasForPose:pose imageSize:imageSize];
  OSCRingHit hit = OSCRingClosestAngle(matrix, (int)axis, OSCRingRadius,
                                       CGPointMake(x - centre.x, y - centre.y), OSCRingHitSamples);
  MMRingDrag drag = {.axis = axis, .pressCanvas = CGPointMake(x, y)};
  drag.press[0] = pose.rotationX * MMDegreesToRadians;
  drag.press[1] = pose.rotationY * MMDegreesToRadians;
  drag.press[2] = pose.rotation * MMDegreesToRadians;
  for (int i = 0; i < 3; ++i) drag.last[i] = drag.press[i];
  OSCRingScreenTangent(matrix, (int)axis, hit.frontAngle, &drag.tangentX, &drag.tangentY);
  self.ringDrag = drag;
  self.rotationCache = MMPropertyEditingCache(MMRotationLane(), self.apiManager, time);
  return YES;
}

- (BOOL)dragRingAtX:(double)x y:(double)y modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time {
  MMRingDrag drag = self.ringDrag;
  if (drag.axis < 0) return NO;
  // Every tick measures from the press, so a dropped tick cannot accumulate
  // error; only the branch anchor carries over. Cmd snaps the dragged axis to
  // whole 15 degree marks, which is why the press angle goes in.
  double delta = OSCRingDragAngleDelta((int)drag.axis, x - drag.pressCanvas.x, y - drag.pressCanvas.y,
                                       drag.tangentX, drag.tangentY, OSCRingRadius,
                                       drag.press[drag.axis],
                                       (modifiers & kFxModifierKey_COMMAND) != 0);
  double euler[3];
  OSCRotationApplyRingDelta((int)drag.axis, delta, drag.press, drag.last, euler);
  self.ringDrag = drag;
  BOOL explicit = NO;
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return NO;
  const double degrees = 180 / M_PI;
  return [MMRotationLane() writeValues:@[@(euler[0] * degrees), @(euler[1] * degrees), @(euler[2] * degrees)]
                              manager:self.apiManager
                                cache:self.rotationCache
                                 time:time
                             explicit:explicit];
}

- (void)clearRingDrag {
  self.ringDrag = (MMRingDrag){.axis = -1};
  self.rotationCache = nil;
}

@end
