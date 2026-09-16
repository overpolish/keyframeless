/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "OSCViewerControl_Private.h"

// The rotation gizmo: three rings on the image's pivot, each dragging one
// object axis. Split out because it owns its own drawing and hit test, none of
// which the box outline and scale handles share.
@interface OSCViewerControl (Rotation)
// Gizmo quad and shader parameters for this tick, or NO when the rings are
// hidden. `surface` is the destination surface, whose size lays out canvas
// space; `activePart` is the host's, so a dragged ring keeps its highlight.
- (BOOL)ringQuad:(RSOSCVertex[6])quad params:(RSOSCRingParams *)params pose:(OSCBoxPose)pose
       imageSize:(CGSize)imageSize surface:(CGSize)surface activePart:(NSInteger)activePart
          atTime:(CMTime)time;
// The ring under the pointer, or -1. Only the visible hemisphere is grabbable,
// and a hidden gizmo is not hit at all. `cursor` receives what to show over it.
- (NSInteger)ringAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
              cursor:(OSCCursorKind *)cursor atTime:(CMTime)time;
// Captures the press baseline: the pose's Euler angles and the grabbed ring's
// on-screen tangent.
- (BOOL)beginRingDragAtX:(double)x y:(double)y part:(NSInteger)part pose:(OSCBoxPose)pose
               imageSize:(CGSize)imageSize atTime:(CMTime)time;
// One tick: the rotated pose, measured from the press point.
- (BOOL)dragRingAtX:(double)x y:(double)y modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time;
@end
