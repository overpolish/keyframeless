/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageBrowserController.h"
#import "MirageColorPanelController.h"
#import "MirageInspectorView.h"
#import "MirageMiniCompareControls.h"
#import "MirageMiniViewerRenderer.h"
#import "MirageShaderRackView.h"

@class MirageCatalogEntry;

NS_ASSUME_NONNULL_BEGIN

// Mirage-specific subclass storage. The generic toolbar / tab bar / basic
// view / detached-copy ivars all live on the `KKTimelineInspectorView`
// superclass (including the shared timing-guide host); only Mirage's
// mini-viewer renderer belongs here.
@interface MirageInspectorView () {
@protected
  MirageMiniViewerRenderer *_miniViewerRenderer;
  MirageBrowserController *_browserController;
  MirageColorPanelController *_colorPanelController;
  /// Before / Split / Show Selection, on the mini viewer. Every template has
  /// the preview, so unlike the panel this is built for all of them.
  MirageMiniCompareControls *_compareControls;
  /// Where this clip starts in TIMELINE seconds (FCP's clock, timecode
  /// included), pushed from the render tick (the only place trims surface).
  /// Negative = not known yet.
  double _clipTimelineStartSec;
  // This subclass keeps its own _playheadFraction for the audio (spectrogram)
  // preview. The base KKTimelineInspectorView separately tracks its own
  // _playheadFraction (private to the kit) to feed-lock parameter-link timing;
  // both are set to the same value in the respective setPlayheadFraction:.
  double _playheadFraction;
  // Motion-blur state mirrored for the preview (see
  // -_pushMotionBlurToMiniViewer): the shutter only reaches a `native` shader,
  // but the inspector is where the persisted values arrive.
  BOOL _mbPreviewEnabled;
  double _mbPreviewShutterAngle;
  NSInteger _mbPreviewSamples;
  /// The effective shader source last seen by -applyTimeline:, so a timeline
  /// change that swaps the shader (incl. a guide seed dropping the code lane =>
  /// the baked default) re-wires the source-derived OSC set exactly once.
  NSString *_lastEffectiveShaderSource;
  /// The slot registry the lane templates were last derived from, as a
  /// fingerprint. The source is not enough on its own: a `#slots` instance
  /// added or removed changes how many lane sets that same source stands for,
  /// and an undo brings the change back through the blob without a single
  /// character of the shader moving.
  NSString *_lastSlotSignature;
  /// Kept so the link-thumbnail bake can resolve this instance's UUID
  /// (KKInstanceUUIDForAPI) - the SAME key the render-side manifest uses.
  id<PROAPIAccessing> _thumbAPIManager;
  /// Bumped each time a thumbnail bake is scheduled (on appear + on content
  /// change); the deferred bake only fires if it's still the latest, so a burst
  /// coalesces into one. No repeating poll.
  NSInteger _thumbBakeGeneration;
  /// The shader chain strip inside the static-values popover. WEAK: the
  /// popover owns it and drops it on close, and -refreshRack is a no-op
  /// between opens rather than talking to an orphan.
  __weak MirageShaderRackView *_rackView;
  /// The mini viewer's chain preview: which of the two questions is being
  /// asked, and of which entry. SESSION-ONLY, like the compare row's split and
  /// matte - no lane, no parameter, no undo entry - and cleared with every
  /// popover, so a session always opens on the whole chain.
  MirageRackPreviewMode _rackPreviewMode;
  NSString *_rackPreviewEntryID;
  /// A selection restored by the host that the timeline in hand does not
  /// describe yet. Undo of an append reverts TWO params, and the UI-state one
  /// can land first: the entry it names is real, but the registry still says
  /// otherwise for a moment. Held here and adopted by the -refreshRack that
  /// first sees it, so the restore is not thrown away by the stale-selection
  /// fallback.
  NSString *_pendingRackSelectionID;
  /// Guides seed the legacy/default shader's bare lane keys. Temporarily pin
  /// that rack entry while a guide runs, then restore the user's entry only
  /// after the real timeline has been restored.
  NSString *_guideSavedRackSelectionID;
  BOOL _guideRackSelectionActive;
}

@end

/// Hosting the rack strip in the static-values popover: building it, keeping
/// its boxes in step with the timeline, and the session-only chain preview.
/// Implemented in MirageInspectorView+Rack.m.
@interface MirageInspectorView (Rack)
/// Build the strip the popover mounts between the mini viewer and the rows,
/// wired to the mutations and already populated. One per popover.
- (NSView *)buildRackStrip;
/// Rebuild the boxes from the lanes view's current timeline. Cheap and
/// idempotent - called from every apply, and a no-op with no popover open.
- (void)refreshRack;
/// Where the playhead is in the clip, as the fraction every rack question about
/// "now" (which keypose an enable edits, which entries are switched on) is
/// answered at.
- (double)playheadFractionForRack;
/// Arm / disarm the mini viewer's chain preview. NOT a write: no lane, no
/// parameter, no undo entry. `MirageRackPreviewModeOff` (or re-asking for the
/// mode already running on that entry) goes back to the whole chain.
- (void)_rackSetPreviewMode:(MirageRackPreviewMode)mode
                      entry:(nullable NSString *)entryID;
@end

/// The four things the user can do to the chain, and the single write path they
/// all land through. Implemented in MirageInspectorView+RackMutations.m.
@interface MirageInspectorView (RackMutations)
- (void)_rackAddFromView:(nullable NSView *)sourceView;
- (void)_rackRemoveEntry:(NSString *)entryID;
- (void)_rackMoveEntry:(NSString *)entryID toIndex:(NSInteger)index;
- (void)_rackSetEntry:(NSString *)entryID enabled:(BOOL)enabled;
/// The one write path for a rack mutation. `selectEntryID` non-nil folds the
/// selection into the SAME action scope as the timeline blob, so the pair is
/// one undo entry.
- (void)commitRackTimeline:(KKTimeline *)updated
                 selecting:(nullable NSString *)selectEntryID;
- (void)commitRackTimeline:(KKTimeline *)updated;
@end

/// Which entry the inspector is on: moving it, everything that re-derives from
/// it, and restoring it from the host. Implemented in
/// MirageInspectorView+RackSelection.m. Named apart from the PUBLIC
/// (RackSelection) category in MirageInspectorView.h - one category name may
/// only be declared once, and the public header owns that name for the one
/// method the plugin calls.
@interface MirageInspectorView (RackSelectionInternal)
/// Move the selection and, when it actually moved, re-drive the scoped UI.
/// `persist` YES = a USER-driven move, which is written to the UI-state blob
/// and therefore costs one undo entry; NO = memory only (a programmatic heal,
/// a cold-boot resolve, or a move whose write is folded into a mutation's
/// action scope). Also the entry point for a keypose click on another entry's
/// lane - the kit reports it through onKeyposeLayerActivated.
- (void)_rackSelectEntry:(NSString *)entryID persist:(BOOL)persist;
/// Re-drive everything scoped to the selected entry (lane templates, the rows
/// and the open constants popover, the Color panel). Never writes.
- (void)rackSelectionDidChange;
/// The lane-key filter the constants popover is scoped by: YES for a lane
/// belonging to the SELECTED entry (and for every lane of a project with no
/// rack registry, which is what keeps a legacy project's popover unchanged).
- (BOOL)rackShowsLaneInConstants:(KKLane *)lane;
@end

NS_ASSUME_NONNULL_END
