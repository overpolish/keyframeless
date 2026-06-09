/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Glow's plugin-specific timeline inspector. Subclasses the generic
/// `KKTimelineInspectorView` (toolbar, tab bar, content area, detach, live
/// setters) and adds only Glow's mini-viewer renderer.
@interface GlowInspectorView : KKTimelineInspectorView
@end

NS_ASSUME_NONNULL_END
