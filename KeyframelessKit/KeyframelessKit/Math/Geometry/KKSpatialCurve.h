/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKTimeline.h>

NS_ASSUME_NONNULL_BEGIN

/// Curved (cubic-bezier) 2D motion path for a Position lane: the per-segment
/// curve, its arc-length reparameterisation (constant speed through bends), the
/// effective tangent handles, and the geometric polyline. Shared by the timing
/// evaluator (which renders the path) and the OSCs (which draw and edit it) so
/// they agree exactly.

/// Cubic-bezier point for the 2D spatial curve between keyposes `ia` and `ia+1`
/// at parameter `t`. A keypose that isn't spatialSmooth contributes a zero
/// handle on its side (a straight pull from the anchor), so "one corner, one
/// smooth" segments behave correctly. Caller guarantees both keyposes have at
/// least two value components.
FOUNDATION_EXPORT void KKLaneSpatialBezierXY(NSArray<KKKeyPose *> *kps,
                                             NSUInteger ia, double t,
                                             double *outX, double *outY);

/// Arc-length reparameterisation for segment `ia`: given a fraction `s` of the
/// curve's *length* (0..1), returns the bezier parameter `t` that lands there.
/// A cubic bezier in `t` does not move at uniform speed, so feeding eased
/// progress through this makes a tight bend and a gentle one pace evenly.
FOUNDATION_EXPORT double KKLaneSpatialArcParam(NSArray<KKKeyPose *> *kps,
                                               NSUInteger ia, double s);

/// Geometric points along a lane's 2D spatial path (Position), in object space,
/// IGNORING temporal easing - the clean route through the keyposes, with curved
/// (spatialSmooth) segments tessellated at `samplesPerSegment` and straight
/// segments contributing only their endpoints. Returns NSValue-wrapped CGPoints
/// in the lane's value units; empty for <1 keypose or <2-component values.
FOUNDATION_EXPORT NSArray<NSValue *> *
KKLanePositionPathPoints(KKLane *lane, NSUInteger samplesPerSegment);

/// KKLanePositionPathPoints plus each sample's clip FRACTION (segment keypose
/// times lerped by the tessellation parameter - approximate under easing),
/// so a warped position OSC can evaluate time-varying references per sample.
FOUNDATION_EXPORT NSArray<NSValue *> *KKLanePositionPathPointsWithFractions(
    KKLane *lane, NSUInteger samplesPerSegment,
    NSArray<NSNumber *> *_Nullable __autoreleasing *_Nullable outFractions);

/// Effective spatial tangent handles for keypose `index`, in object space, as
/// offsets from the anchor: the manual inHandle/outHandle when set, otherwise
/// the auto-derived (Catmull-Rom) tangent the curve actually uses. Lets the OSC
/// draw handles that match the rendered path. Pass nil for a side you don't
/// need; writes CGPointZero for an out-of-range index.
FOUNDATION_EXPORT void
KKLaneSpatialHandlesForKeypose(KKLane *lane, NSUInteger index,
                               CGPoint *_Nullable inHandle,
                               CGPoint *_Nullable outHandle);

/// The keypose anchor positions to draw for the motion path (NSValue-wrapped
/// CGPoints in object space). Drops the keypose at `skipIndex` and any keypose
/// coincident with it - so a linked partner collapses under the position handle
/// instead of drawing a redundant dot - and dedups any further coincident
/// anchors. Pass `skipIndex < 0` to keep every distinct position. Each surface
/// converts the returned object-space points into its own coordinate space.
FOUNDATION_EXPORT NSArray<NSValue *> *
KKLaneCoalescedAnchors(KKLane *lane, NSInteger skipIndex);

/// KKLaneCoalescedAnchors plus each kept anchor's keypose FRACTION, for the
/// warped position OSC's per-anchor mapping.
FOUNDATION_EXPORT NSArray<NSValue *> *KKLaneCoalescedAnchorsWithFractions(
    KKLane *lane, NSInteger skipIndex,
    NSArray<NSNumber *> *_Nullable __autoreleasing *_Nullable outFractions);

NS_ASSUME_NONNULL_END
