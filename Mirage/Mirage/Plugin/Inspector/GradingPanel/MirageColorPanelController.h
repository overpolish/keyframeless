/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

NS_ASSUME_NONNULL_BEGIN

/// Shows the Color panel beside an open value-editing popover, for shaders
/// that declare `// #color-surface`.
///
/// Companion to MirageBrowserController and observes the same popover
/// notifications, but its panel is draggable and remembers where the user left
/// it - the browser is a list you glance at, this is a panel you work in while
/// dragging controls in the inspector.
@interface MirageColorPanelController : NSObject

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView
                       apiManager:(id)apiManager;

/// Whether the loaded shader opted in.
///
/// PUSHED on every timeline apply so a recompile that adds or drops the
/// directive takes effect at once. It is not the only source of truth though:
/// the controller also RESOLVES this from the lanes view when a popover opens,
/// because -applyTimeline: has not necessarily run by then - on a cold FCP boot
/// it demonstrably has not, which is why the panel used to miss the first
/// popover after launch.
@property(nonatomic) BOOL surfaceEnabled;
/// Fired whenever the selected shader gains or loses a usable grading panel.
@property(nonatomic, copy, nullable) void (^onSurfaceAvailabilityChanged)
    (BOOL available);

/// User-facing right-panel toggle. Independent of shader capability: off hides
/// the panel even for a grading shader; on immediately restores it when the
/// current shader and editor support it. Defaults to YES.
@property(nonatomic, getter=isUserVisible) BOOL userVisible;

/// Which shader in the rack the panel is talking about: the entry the strip has
/// selected. Everything the panel derives - the rings, the pucks, the picks,
/// the `#slots` group it adds to - comes from THAT entry's source, and every
/// control it reads or writes is that entry's lane.
///
/// nil / the sentinel id is the pre-rack answer, i.e. the bare "Mirage" code
/// lane and bare lane keys, so a project that has never been racked behaves
/// exactly as it did. Setting it re-derives and, for an entry whose template
/// declares no `#color-surface`, takes the panel off screen - the same absence
/// a non-grading template has always had.
@property(nonatomic, copy, nullable) NSString *selectedRackEntryID;

/// Whether the shader's selection - its matte - is showing in the preview.
///
/// PUSHED IN from the compare row that lives on the mini viewer, which owns the
/// switch: every template has a preview, only a `#color-surface` one has this
/// panel, and the switch matters most on the templates that never had it (a
/// denoise is nothing but its selection). The panel holds a copy because the
/// preview's overrides are asserted in ONE push that also carries the active
/// key the pucks decide - see -reassertPreviewOverrides.
@property(nonatomic) BOOL showSelectionActive;

/// Assert the preview's overrides again. Idempotent, and cheap when nothing
/// moved: the record of what is already asserted is compared first.
///
/// Called when something the overrides are keyed against moves without either
/// of their values moving - the playhead above all, since the override only
/// answers at the fraction it was pushed for.
- (void)reassertPreviewOverrides;

/// YES while a puck drag or a write group is open, so a bare-letter shortcut
/// somewhere else in the inspector knows to keep its hands off the keyboard.
@property(nonatomic, readonly) BOOL gestureInFlight;

/// Persist a timeline the puck has edited, and bracket a drag so its burst of
/// writes collapses into ONE undo entry. Wired by the inspector to the same
/// chain the mini-viewer handles use.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

/// Re-read the shader's surface spec and re-derive the puck. Called from
/// -applyTimeline: so a recompile updates the ring and labels without the panel
/// having to be closed and reopened.
- (void)timelineDidChange;

/// Make the handle belonging to `instanceID` the one the panel is talking
/// about, for a `#slots` instance that arrived from OUTSIDE the panel.
///
/// The add and remove buttons place their own selection, because they know what
/// they just did. An undo that restores a removed instance has the same claim
/// on the selection and no way to say so - the instance comes back through the
/// blob, and without this the handle reappears while a neighbour stays active,
/// so the first thing the user has to do after un-deleting something is find it
/// again. Call AFTER -timelineDidChange: the handle has to exist before it can
/// be selected.
- (void)selectSlotInstance:(NSString *)instanceID;

/// Tear down observers and hide. Called from the inspector's dealloc, matching
/// how the browser controller is retired.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
