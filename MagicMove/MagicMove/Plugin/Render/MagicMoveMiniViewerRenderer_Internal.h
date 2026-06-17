/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MagicMoveMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Shared lane lookup against a timeline (defined in the core .m).
KKLane *_Nullable MMMiniLaneNamed(KKTimeline *timeline, NSString *label);

@interface MagicMoveMiniViewerRenderer () {
  // Pipeline cache keyed by (device, pixelFormat) - the plugin's own metallib
  // is in this XPC process's bundle, so we build a real PSO and apply the
  // shader source → dest locally. No FxPlug round-trip = no Flexo lock
  // contention = no deadlock during live drag.
  id<MTLRenderPipelineState> _pipeline;
  id<MTLDevice> _pipelineDevice;
  MTLPixelFormat _pipelineFormat;
  // Anchor-square drag: delta-based like Position (snap off unless Cmd).
  BOOL _anchorGrabbed;
  double _anchorGrabValX;
  double _anchorGrabValY;
  double _anchorPressNX;
  double _anchorPressNY;
}
// Reusable Position + motion-path controller (owns the shared snap engine,
// which the anchor drag and snap-guide reporting also read).
@property(nonatomic, strong) KKPositionMiniController *positionMini;
// Reusable Scale transform-box controller (geometry + hit-test + drag).
@property(nonatomic, strong) KKScaleMiniController *scaleMini;
// Geometry helper defined in the primary @implementation (the core .m); called
// across the Interaction category.
- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos;
@end

@interface MagicMoveMiniViewerRenderer (Interaction)
@end

NS_ASSUME_NONNULL_END
