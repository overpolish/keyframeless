/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

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
}
@end

NS_ASSUME_NONNULL_END
