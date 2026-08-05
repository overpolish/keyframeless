/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

#import "MirageRack.h" // MirageRackPreviewMode

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const MirageMiniViewerDescriptorPath;

/// Reverse channel: the boundary-value popover (ViewBridge side) writes the
/// requested clip fraction here; the render side reads it in
/// `-scheduleInputs:` to also pull that frame for the preview.
extern NSString *const MirageMiniViewerRequestPath;

/// Per-instance rendezvous paths keyed by the instance UUID. Two stacked
/// Mirage clips must read/write distinct `/tmp` files, otherwise the top
/// clip's render pollutes the feed the clip below reads (its mini-viewer shows
/// the wrong source). Falls back to the static path when `uuid` is empty.
NSString *MirageMiniViewerDescriptorPathForUUID(NSString *_Nullable uuid);
NSString *MirageMiniViewerRequestPathForUUID(NSString *_Nullable uuid);

/// Mirage's mini-viewer delegate: the generic handle/timeline scaffolding lives
/// in `KKMiniViewerRenderer`; this subclass only supplies the Mirage render.
/// The legacy Origin / Scale / Rotation on-screen controls have been removed
/// pending shader-exposed OSCs. MRR (non-ARC).
@interface MirageMiniViewerRenderer : KKMiniViewerRenderer
/// The plugin's lane templates (`+[MiragePlugin availableLanes]`), set by the
/// inspector. Used by `-templateLaneForLabel:` for not-yet-in-timeline constant
/// lane defaults.
@property(nonatomic, copy, nullable) NSArray<KKLane *> *laneTemplates;

/// SHADER RACK: which entry the preview's ON-SCREEN CONTROLS belong to - the
/// rack row the inspector has selected. Pushed by the plugin, because the
/// mini's control sets are built once per source change rather than re-derived
/// per tick like the viewer's.
///
/// The OSC side reads this, and the render uses it as the endpoint while a
/// selection matte is active so later shaders cannot alter the diagnostic.
///
/// nil / the sentinel id is what an unracked project has, and resolves exactly
/// as it did before the rack.
@property(nonatomic, copy, nullable) NSString *rackEntryID;

/// Whether the selected shader's diagnostic matte is currently shown. Kept
/// separately from the value override so the mini render graph can stop at
/// the selected entry before downstream shaders process the matte.
@property(nonatomic) BOOL selectionMatteActive;

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

/// The Motion Blur shutter as a 0..1 fraction of a frame (1.0 == 360deg), and
/// the sample count, pushed by the inspector.
///
/// These reach the shader as `iMotionBlur` / `iMotionBlurSamples`, and ONLY for
/// a `// #motionblur native` source - exactly as in the FCP render. A native
/// shader treats the shutter as a LOOK control (a trail's decay), so without
/// them the preview isn't merely unblurred, it shows a different image: the
/// trail sits at its floor value however the slider is set. Every other mode
/// leaves iMotionBlur at 0 in both paths, so they already agree.
///
/// This is NOT the mini rendering motion blur - it deliberately doesn't. It is
/// handing the shader the same number the viewer hands it.
@property(nonatomic) float motionBlurShutterFraction;
@property(nonatomic) int motionBlurSamples;

/// Which part of the shader rack the preview is showing, and the entry that
/// mode is about. SESSION-ONLY: pushed in by the rack strip, shared with Final
/// Cut's main viewer, dropped when the editor closes, and never persisted.
/// `Off` (the default) renders every enabled entry.
@property(nonatomic) MirageRackPreviewMode rackPreviewMode;
@property(nonatomic, copy, nullable) NSString *rackPreviewEntryID;

// clipDurationSeconds + clipTimelineStartSec are inherited from
// KKMiniViewerRenderer (hoisted there so every plugin's mini gets
// parameter-link feed-locking). The preview's `iTime` still reads
// clipDurationSeconds (see -generateIntoTexture: `timeSec`).

/// Blit-scale `src` into `dest` (format-converting to dest's format, aspect
/// from dest's dimensions). Used by the thumbnail bake to capture the rendered
/// final frame into a readable target.
- (void)blitFrom:(id<MTLTexture>)src
             into:(id<MTLTexture>)dest
    commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
@end

NS_ASSUME_NONNULL_END
