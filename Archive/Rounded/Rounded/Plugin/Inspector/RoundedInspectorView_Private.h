/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorView.h"
#import "RoundedMiniViewerRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// Rounded-specific subclass storage. The generic toolbar / tab bar / basic
// view / detached-copy ivars all live on the `KKTimelineInspectorView`
// superclass (including the shared timing-guide host); only Rounded's
// mini-viewer renderer belongs here.
@interface RoundedInspectorView () {
@protected
  RoundedMiniViewerRenderer *_miniViewerRenderer;
}
@end

NS_ASSUME_NONNULL_END
