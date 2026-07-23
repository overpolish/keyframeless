/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "GlowInspectorView.h"
#import "GlowMiniViewerRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// Glow-specific subclass storage. The generic toolbar / tab bar / basic view /
// detached-copy ivars all live on the KKTimelineInspectorView superclass; only
// Glow's mini-viewer renderer belongs here.
@interface GlowInspectorView () {
@protected
  GlowMiniViewerRenderer *_miniViewerRenderer;
}
@end

NS_ASSUME_NONNULL_END
