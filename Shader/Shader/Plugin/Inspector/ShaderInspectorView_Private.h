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
  // This subclass keeps its own _playheadFraction for the audio (spectrogram)
  // preview. The base KKTimelineInspectorView separately tracks its own
  // _playheadFraction (private to the kit) to feed-lock parameter-link timing;
  // both are set to the same value in the respective setPlayheadFraction:.
  double _playheadFraction;
  /// The effective shader source last seen by -applyTimeline:, so a timeline
  /// change that swaps the shader (incl. a guide seed dropping the code lane =>
  /// the baked default) re-wires the source-derived OSC set exactly once.
  NSString *_lastEffectiveShaderSource;
  /// Kept so the link-thumbnail bake can resolve this instance's UUID
  /// (KKInstanceUUIDForAPI) - the SAME key the render-side manifest uses.
  id<PROAPIAccessing> _thumbAPIManager;
  /// Bumped each time a thumbnail bake is scheduled (on appear + on content
  /// change); the deferred bake only fires if it's still the latest, so a burst
  /// coalesces into one. No repeating poll.
  NSInteger _thumbBakeGeneration;
}

@end

NS_ASSUME_NONNULL_END
