/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MagicMoveOSCMath.h"
#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

enum {
  kOSCPositionPart = 1,
  kOSCRotationPart = 2,
  kOSCPathHandlePart = 3,
  kOSCScalePart = 4,
  kOSCAnchorPart = 5,
};

@interface MagicMoveOSC () <KKPositionGuideProvider>
/// The reusable Position control (arc handle + motion path + drag/snap/smooth),
/// composed into this host OSC. Owns all the Position glue that used to live in
/// the +Drawing / +HitTest / +MouseHandlers categories.
@property(nonatomic, retain) KKPositionOSC *positionController;
@property(nonatomic, retain) KKRotationOSC *rotationOSC;
/// Feed one drawOSC tick to the shared guide bridge so it can compute the
/// viewer screen rect (for the timing guide's watch-back cutout). `pos` is the
/// current Position in canvas space. Cheap; called every drawOSC tick.
- (void)_ingestGuideDrawTickWithPosition:(CGPoint)pos;

/// Feed one hit-test sample (screen + canvas coords together) to the guide
/// bridge. This is the ONLY place the screen<->canvas anchor + a valid canvas
/// scale arrive, so it's what bootstraps `estimatedViewerScreenRect` (the draw
/// tick alone can't). Called at the top of hitTestOSCAtMousePositionX.
- (void)_ingestGuideHitTestAtCanvasX:(double)cx y:(double)cy;

/// Canvas-space corners of the clip's frame (OBJECT (0,0)/(1,1) -> CANVAS),
/// used by both guide-bridge feeds. NO if the OSC API is unavailable.
- (BOOL)_guideCanvasTopRight:(CGPoint *)outTR bottomLeft:(CGPoint *)outBL;
/// Scale transform-box gizmo: the shared KKBoxOSC (border + 8 corner/edge
/// handles + a "X% x Y%" readout). Sized via KKScaleGizmo from the Scale lane,
/// centred on Position, drawn outside the rotation rings.
@property(nonatomic, retain) KKBoxOSC *scaleBox;
/// Anchor-point pivot: a draggable square at the clip's rotation/scale pivot
/// (Position + Anchor offset). Snaps to the clip's center / corners / edges /
/// thirds unless Cmd is held. anchorGrabVal + anchorPressObject give it the
/// same delta-based drag as Position.
@property(nonatomic, retain) KKSquarePointOSC *anchorPointOSC;
@property(nonatomic, retain) KKSnapEngine *anchorSnap;
@property(nonatomic) BOOL anchorHovered;
// YES while we've forced the move cursor over a draggable point (anchor /
// position / path); reset to the arrow when the pointer leaves them. The scale
// box self-manages its resize cursor (KKBoxOSC), rotation has none yet.
@property(nonatomic) BOOL pointCursorSet;
@property(nonatomic) double anchorGrabValX;
@property(nonatomic) double anchorGrabValY;
@property(nonatomic) simd_float2 anchorPressObject;
/// Which scale handle (0-7) the hit-test last landed on, and the one currently
/// grabbed for a drag. -1 = none.
@property(nonatomic) NSInteger scaleHitHandle;
@property(nonatomic) NSInteger scaleGrabHandle;
/// Press state captured at scale mouseDown: the box centre (= Position) and the
/// scale percents, so the drag preserves ratio / inverts the gizmo curve from a
/// stable reference rather than tick-to-tick.
@property(nonatomic) CGPoint scalePressCenter;
@property(nonatomic) double scalePressSclX;
@property(nonatomic) double scalePressSclY;
/// Absolute drag state: the "effective" cursor canvas point that drives the
/// value (initialised to the grabbed handle so there is no press snap, then
/// moved by the raw cursor delta - scaled down while Cmd-fine is held), plus
/// the previous raw cursor for that per-tick delta. Written values round to
/// integers.
@property(nonatomic) CGPoint scaleEffCursor;
@property(nonatomic) CGPoint scaleLastCursor;
@property(nonatomic)
    CGPoint rotPressCanvas;            // canvas pixel where rot drag began
@property(nonatomic) double rotPressX; // rotation values (rad) at press
@property(nonatomic) double rotPressY;
@property(nonatomic) double rotPressZ;
// Per-drag continuity anchor: last-written Euler values. The Euler
// decomposition has two valid reps and as drag accumulates past ~270° the
// "nearest to press" rule starts picking the wrong one (because press is
// far away). Using the previous tick's output as the anchor keeps the
// per-tick angular step small and unambiguous.
@property(nonatomic) double rotLastWrittenX;
@property(nonatomic) double rotLastWrittenY;
@property(nonatomic) double rotLastWrittenZ;

// Geometry / evaluation helpers implemented in the primary @implementation
// (OSC.m); the HitTest helpers live in MagicMoveOSC+HitTest.m. Declared here so
// the Drawing / HitTest / MouseHandlers categories can call across files.
- (double)_fractionAtTime:(CMTime)time;
- (CGPoint)oscPositionAtTime:(CMTime)time;
- (CGPoint)_canvasFromObjX:(double)ox y:(double)oy;
- (CGPoint)_anchorCanvasAtFraction:(double)frac;
- (BOOL)_configureRotationRingsAtFraction:(double)frac dragging:(BOOL)dragging;
- (void)_syncRotationColorsFromLane;
- (void)_scaleGizmoE0:(double *)outE0 span:(double *)outSpan;
@end

@interface MagicMoveOSC (Drawing)
@end

@interface MagicMoveOSC (HitTest)
@end

@interface MagicMoveOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
