/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMPropertyLane.h"
#import "MMOSCShaderTypes.h"
#import "MagicMoveOSC_Private.h"

// Ring drag state, captured at press so a tick stays consistent even if the
// pose moves under it. Euler angles are radians in X, Y, Z order; `last`
// anchors the next tick's decomposition so a long sweep stays continuous.
typedef struct {
  NSInteger axis; // OSCRingAxis*, or -1 when no ring is being dragged
  double press[3];
  double last[3];
  double tangentX, tangentY;
  CGPoint pressCanvas;
} MMRingDrag;

@interface MagicMoveOSC ()
@property(nonatomic) BOOL showRings;
@property(nonatomic) NSInteger hoveredRing;
@property(nonatomic) MMRingDrag ringDrag;
@property(nonatomic) MMPropertyPoseCache *rotationCache;
@end

// The rotation gizmo: three rings on the image's pivot, each dragging one
// object axis. Split out because it owns its own drawing, hit test and write
// path, none of which the box outline and scale handles share.
@interface MagicMoveOSC (Rotation)
// Gizmo quad and shader parameters for this tick, or NO when the rings are
// hidden. `surface` is the destination surface, whose size lays out canvas
// space; `activePart` is the host's, so a dragged ring keeps its highlight.
- (BOOL)ringQuad:(MMOSCVertex[6])quad params:(MMOSCRingParams *)params pose:(OSCBoxPose)pose
       imageSize:(CGSize)imageSize surface:(CGSize)surface activePart:(NSInteger)activePart
          atTime:(CMTime)time;
// The ring under the pointer, or -1. Only the visible hemisphere is grabbable,
// and a hidden gizmo is not hit at all. `cursor` receives what to show over it.
- (NSInteger)ringAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
              cursor:(MMOSCCursorKind *)cursor atTime:(CMTime)time;
// Captures the press baseline: the pose's Euler angles and the grabbed ring's
// on-screen tangent, plus the cache the drag writes through.
- (BOOL)beginRingDragAtX:(double)x y:(double)y part:(NSInteger)part pose:(OSCBoxPose)pose
               imageSize:(CGSize)imageSize atTime:(CMTime)time;
// One tick: all three axes in one host write, measured from the press point.
- (BOOL)dragRingAtX:(double)x y:(double)y modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time;
- (void)clearRingDrag;
@end
