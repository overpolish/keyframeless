/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Rounded's plugin-specific timeline inspector. Subclasses the generic
/// `KKTimelineInspectorView` (which owns the play/loop/reset toolbar, tab
/// bar, content area, detach plumbing and live-push setters) and adds only
/// the Rounded shader + tour hooks: the Radius/Crop mini-viewer renderer,
/// the joyride autostart and per-instance tour configuration.
///
/// The basic/advanced timing walkthroughs and the constants guide live on the
/// `RoundedInspectorView` guide categories - import
/// `RoundedInspectorView+Guides.h` to call them.
@interface RoundedInspectorView : KKTimelineInspectorView
@end

NS_ASSUME_NONNULL_END
