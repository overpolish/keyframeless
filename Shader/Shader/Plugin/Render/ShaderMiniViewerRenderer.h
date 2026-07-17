/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const ShaderMiniViewerDescriptorPath;

/// Reverse channel: the boundary-value popover (ViewBridge side) writes the
/// requested clip fraction here; the render side reads it in
/// `-scheduleInputs:` to also pull that frame for the preview.
extern NSString *const ShaderMiniViewerRequestPath;

/// Per-instance rendezvous paths keyed by the instance UUID. Two stacked
/// Shader clips must read/write distinct `/tmp` files, otherwise the top
/// clip's render pollutes the feed the clip below reads (its mini-viewer shows
/// the wrong source). Falls back to the static path when `uuid` is empty.
NSString *ShaderMiniViewerDescriptorPathForUUID(NSString *_Nullable uuid);
NSString *ShaderMiniViewerRequestPathForUUID(NSString *_Nullable uuid);

/// Shader's mini-viewer delegate: the generic handle/timeline scaffolding lives
/// in `KKMiniViewerRenderer`; this subclass only supplies the Shader render.
/// The legacy Origin / Scale / Rotation on-screen controls have been removed
/// pending shader-exposed OSCs. MRR (non-ARC).
@interface ShaderMiniViewerRenderer : KKMiniViewerRenderer
/// The plugin's lane templates (`+[ShaderPlugin availableLanes]`), set by the
/// inspector. Used by `-templateLaneForLabel:` for not-yet-in-timeline constant
/// lane defaults.
@property(nonatomic, copy, nullable) NSArray<KKLane *> *laneTemplates;

/// TIMELINE seconds to sample `// #audio` at, from the inspector's playhead.
///
/// The preview can't use `editFraction` for this: that's the keypose being
/// edited, not where the playhead is, and it's 0 unless a boundary popover is
/// open - so the bars would sit on the clip's first frame forever. Negative =
/// unknown (no timing yet), which reads as silence rather than the first frame.
@property(nonatomic) double audioTimelineTimeSec;

/// The playhead's 0..1 position through the clip, pushed by the inspector.
/// Drives `iProgress` in the preview, so a transition shader shows the same
/// blend the viewer is showing.
///
/// NOT `editFraction`: that's the keypose whose popover is open, and it stays 0
/// the rest of the time - which pinned `iProgress` to 0 and made every
/// transition preview as its outgoing clip forever. Same reasoning as
/// `audioTimelineTimeSec` above: the preview has to agree with the viewer.
@property(nonatomic) double playheadFraction;
@end

NS_ASSUME_NONNULL_END
