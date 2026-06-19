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
/// Scale transform-box gizmo: the shared kit KKScaleOSC (border + 8 corner/edge
/// handles + "X% x Y%" readout, the gizmo sizing, drag math and visibility
/// gating). Centred on Position each tick, drawn outside the rotation rings.
@property(nonatomic, retain) KKScaleOSC *scaleControl;
/// Anchor-point pivot: the shared kit KKAnchorOSC (a draggable square at the
/// clip's rotation/scale pivot, with its own delta drag + Cmd-snap + visibility
/// gating + persist). The pivot geometry (Position + Anchor offset, in clip
/// space) is injected via its anchorToCanvas / canvasToAnchor blocks.
@property(nonatomic, retain) KKAnchorOSC *anchorControl;
// YES while we've forced the move cursor over a draggable point (anchor /
// position / path); reset to the arrow when the pointer leaves them. The scale
// box self-manages its resize cursor (KKScaleOSC/KKBoxOSC), rotation none yet.
@property(nonatomic) BOOL pointCursorSet;

// Geometry / evaluation helpers implemented in the primary @implementation
// (OSC.m); the HitTest helpers live in MagicMoveOSC+HitTest.m. Declared here so
// the Drawing / HitTest / MouseHandlers categories can call across files.
- (double)_fractionAtTime:(CMTime)time;
- (CGPoint)oscPositionAtTime:(CMTime)time;
- (CGPoint)_canvasFromObjX:(double)ox y:(double)oy;
/// On-screen frame min side (canvas units), the reference dimension the scale
/// gizmo sizes against. Fed to `scaleControl.frameMin` each tick.
- (double)_onScreenFrameMin;
@end

@interface MagicMoveOSC (Drawing)
@end

@interface MagicMoveOSC (HitTest)
@end

@interface MagicMoveOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
