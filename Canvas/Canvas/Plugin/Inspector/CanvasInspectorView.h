/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Canvas's plugin-specific timeline inspector. For now a thin subclass of the
/// generic `KKTimelineInspectorView` (toolbar, tab bar, content area, detach,
/// live setters). Canvas-specific extras (mini-viewer renderer, OSC, guides)
/// get added back as those features are rebuilt onto the v3 timing core.
@interface CanvasInspectorView : KKTimelineInspectorView
@end

NS_ASSUME_NONNULL_END
