/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKJoyrideController_Internal.h"

NS_ASSUME_NONNULL_BEGIN

@interface _KKJoyrideOverlayView () {
@protected
  __weak NSView *_targetView;
  NSString *_message;
  NSAttributedString *_attributedMessage;
  NSRect _actionRect;
  NSRect _nextRect;
  NSInteger _step;
  NSInteger _totalSteps;
  BOOL _drawsBackground;
  NSRect (^_screenRectBlock)(void);
  BOOL _spotlightCircular;
  BOOL _spotlightPassThrough;
  NSRect (^_pillToScreenRectBlock)(void);
  NSTimer *_pulseTimer;
  NSRect _lastSpotRect;
  BOOL _haveLastSpot;
  BOOL _frozen;
}

// Geometry helpers implemented in the primary @implementation; called by
// the Drawing category's -drawRect:/-_drawTargetGlow.
- (NSRect)spotRectInSelf;
- (NSRect)_pillSecondaryLocalRect;
@end

/// Spotlight cutout, target glow, and tooltip-bubble rendering (-drawRect:
/// and its helpers). Split out of KKJoyrideOverlayView.m for file size;
/// implemented in KKJoyrideOverlayView+Drawing.m.
@interface _KKJoyrideOverlayView (Drawing)
@end

NS_ASSUME_NONNULL_END
