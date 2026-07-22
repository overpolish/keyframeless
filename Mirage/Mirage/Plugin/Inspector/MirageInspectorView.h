/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirage's plugin-specific timeline inspector. Subclasses the generic
/// `KKTimelineInspectorView` (which owns the play/loop/reset toolbar, tab
/// bar, content area, detach plumbing and live-push setters) and adds only
/// the Mirage shader + tour hooks: the shader mini-viewer renderer,
/// the joyride autostart and per-instance tour configuration.
///
/// The basic/advanced timing walkthroughs and the constants guide live on the
/// `MirageInspectorView` guide categories - import
/// `MirageInspectorView+Guides.h` to call them.
@interface MirageInspectorView : KKTimelineInspectorView

/// Where this clip starts in TIMELINE seconds (FCP's clock, timecode included).
/// Pushed from the plugin's render tick - the only place the clip's position on
/// the timeline surfaces - and combined with the playhead fraction to tell the
/// mini viewer WHEN it is, so its `// #audio` preview samples the same instant
/// the viewer shows. Negative = not known yet, which previews as silence rather
/// than the first frame.
@property(nonatomic) double clipTimelineStartSec;
@end

NS_ASSUME_NONNULL_END
