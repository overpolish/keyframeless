/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MeshInspectorView.h"
#import "MeshMiniViewerRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// Mesh-specific subclass storage. The generic toolbar / tab bar / basic
// view / detached-copy ivars all live on the `KKTimelineInspectorView`
// superclass (including the shared timing-guide host); only Mesh's
// mini-viewer renderer belongs here.
@interface MeshInspectorView () {
@protected
  MeshMiniViewerRenderer *_miniViewerRenderer;
}
@end

NS_ASSUME_NONNULL_END
