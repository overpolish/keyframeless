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

/// The shader-rack row the user last clicked, or nil for "the first entry".
///
/// PERSISTED and UNDOABLE, the way a layer selection is in every editor: a
/// user-driven move writes `selectedRackEntryID` into the UI-state blob, so
/// Cmd-Z after clicking dither then grade puts the user back on dither with the
/// rows, the color panel and the OSC handles following. Programmatic moves (a
/// stale selection healed after an undo, a cold-boot resolve) only set this and
/// the per-instance mirror - they never write, so they cost no undo entry.
/// Mirrored onto `KKPluginInstanceState` so the OSC and the AI author can read
/// it from elsewhere in this process.
@property(nonatomic, copy, nullable) NSString *selectedRackEntryID;

/// The selection MOVED (never fired for a re-select of the same entry). The
/// plugin's hook for everything that is scoped to the entry but lives outside
/// the inspector: the OSC-visibility checklist and the mini viewer's on-screen
/// controls. Fires after `selectedRackEntryID` and the per-instance mirror are
/// both current, so a handler can read either.
@property(nonatomic, copy, nullable) void (^onRackSelectionChanged)
    (NSString *entryID);

/// Persist a USER-driven selection move, which is what puts it on FCP's undo
/// stack. The handler patches one key into the UI-state blob inside its own
/// action scope - one honoured write, one undo entry. Never fired for a
/// programmatic move (see `selectedRackEntryID`).
@property(nonatomic, copy, nullable) void (^onRackSelectionPersist)
    (NSString *entryID);

/// A rack mutation that also moves the selection: the timeline blob and the
/// selection go into ONE action scope, so undoing an append restores both the
/// chain and the entry the user was on with a single Cmd-Z. Falls back to
/// `onTimelineMutated` when unset.
@property(nonatomic, copy, nullable) void (^onRackTimelineMutatedSelecting)
    (KKTimeline *updated, NSString *entryID);

/// Re-evaluate grading-panel controls that depend on compact/OSC presentation.
- (void)refreshColorReferencePickerAvailability;

@end

/// The one rack-selection entry point the PLUGIN calls (parameterChanged for
/// the UI-state blob). Declared as its own category because the implementation
/// lives with the rest of the selection logic in
/// MirageInspectorView+RackSelection.m - a
/// primary-class declaration would leave the primary @implementation warning
/// that the definition is missing.
@interface MirageInspectorView (RackSelection)
/// The selection the host just restored under us (undo/redo of a selection or
/// of a mutation that carried one). Syncs the property, the per-instance mirror
/// and every scoped surface WITHOUT writing - the value already came from the
/// param, so writing it back would stack a second undo entry. An entry the
/// current timeline does not describe yet (the blob change is still in flight)
/// is held and adopted by the next -refreshRack that sees it.
- (void)applyPersistedRackSelection:(nullable NSString *)entryID;
@end

NS_ASSUME_NONNULL_END
