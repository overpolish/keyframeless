/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderBrowserController.h"
#import "ShaderInspectorView.h"
#import "ShaderMiniViewerRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// Shader-specific subclass storage. The generic toolbar / tab bar / basic
// view / detached-copy ivars all live on the `KKTimelineInspectorView`
// superclass (including the shared timing-guide host); only Shader's
// mini-viewer renderer belongs here.
@interface ShaderInspectorView () {
@protected
  ShaderMiniViewerRenderer *_miniViewerRenderer;
  ShaderBrowserController *_browserController;
  /// Where this clip starts in TIMELINE seconds (FCP's clock, timecode
  /// included), pushed from the render tick (the only place trims surface).
  /// Negative = not known yet.
  double _clipTimelineStartSec;
  double _playheadFraction;
  /// The effective shader source last seen by -applyTimeline:, so a timeline
  /// change that swaps the shader (incl. a guide seed dropping the code lane =>
  /// the baked default) re-wires the source-derived OSC set exactly once.
  NSString *_lastEffectiveShaderSource;
}

@end

NS_ASSUME_NONNULL_END
