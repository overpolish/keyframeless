/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorView.h"
#import "RoundedMiniCanvasRenderer.h"
#import <KeyframelessKit/KKJoyrideController.h>
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
  KKJoyrideController *_introGuide;
  KKTimeline *_savedIntroTimeline;
  KKJoyrideController *_oscGuide;
  KKTimeline *_savedOSCTimeline;
  KKJoyrideController *_fullGuide;
  KKTimeline *_savedFullTimeline;
  KKJoyrideOSCSegment *_oscSegment;
  KKJoyrideController *_constantsGuide;
  KKTimeline *_savedConstantsTimeline;
  KKMiniCanvasGuideScroll *_constantsScrollFwd;
  KKJoyrideController *_basicTimingGuide;
  KKTimeline *_savedBasicTimingTimeline;
}
@end

NS_ASSUME_NONNULL_END
