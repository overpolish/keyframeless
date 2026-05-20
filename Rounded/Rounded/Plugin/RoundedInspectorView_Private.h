/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorView.h"
#import "RoundedMiniCanvasRenderer.h"
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>
#import <KeyframelessKit/KKJoyrideOSCSegment.h>

NS_ASSUME_NONNULL_BEGIN

@class KKMiniCanvasGuideScroll;

// Rounded-specific subclass storage. The generic toolbar / tab bar / basic
// view / detached-copy ivars all live on the `KKTimelineInspectorView`
// superclass; only Rounded's mini-canvas renderer + the joyride state
// belong here.
@interface RoundedInspectorView () {
@protected
  RoundedMiniCanvasRenderer *_miniCanvasRenderer;
  // One host serves all guides — they're mutually exclusive (only one at a
  // time runs), so a single host owns the live controller/binder/saved
  // timeline. Lazy-initialised in -_guideHost.
  KKJoyrideGuideHost *_guideHost;
  KKJoyrideOSCSegment *_oscSegment;
  KKMiniCanvasGuideScroll *_constantsScrollFwd;
  // YES from when restartOSCGuide kicks off until the OSC guide's onComplete
  // — drives the help-button spinner during the zoom-to-fit warm-up.
  BOOL _oscGuideActive;
}
@end

NS_ASSUME_NONNULL_END
