/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKGradientControl;
@class KKPlugin;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Per-plugin-instance state for the multi-stage timing system. Keyed by a
/// UUID stored in `kKKParamInstanceID` so multiple copies of a plugin on
/// the same timeline don't clobber each other via process-wide statics.
///
/// Thread notes: fields are written on the main thread (parameterChanged +
/// custom-view callbacks); weak view refs are ARC atomic.
@interface KKPluginInstanceState : NSObject

/// Live gradient bar for this instance (weak). Used by the color sync pump
/// to push undo/redo-restored stops back into the UI.
@property(nonatomic, weak, nullable) KKGradientControl *gradientControl;

/// Last-known gradient JSON. Set by the custom UI and by the color sync
/// pump; used to diff against the persisted param on sync ticks so self-
/// writes are ignored and undo/redo changes are detected.
@property(nonatomic, copy, nullable) NSString *gradientJSONSnapshot;

/// Whether the sequencer's loop-playback toggle is on. Session-scoped (not
/// persisted across FCP restarts, not written to a param). Written from the
/// ruler's loop button, consulted by the render pump to decide whether to
/// wrap playback back to the effect start when the playhead passes the end.
@property(nonatomic) BOOL loopEnabled;

/// Master "on-screen controls visible" tick. Per-instance runtime cache the
/// OSC's draw tick reads to gate handle visibility (the OSC can't read the
/// host's UI-state blob from its own apiManager scope). Seeded from the
/// persisted blob at custom-UI creation / parameterChanged and written on
/// toggle. Defaults YES so a control-less cold-boot tick still shows the OSC.
@property(nonatomic) BOOL oscMasterVisible;

/// Per-element OSC visibility: the set of element keys (lane labels, e.g.
/// @"Position", @"Rotation") the user has individually hidden via the
/// settings popover's pills. nil/empty = every element shown. Gated under
/// `oscMasterVisible` (master off hides all regardless). Same per-instance
/// rail as `oscMasterVisible`.
@property(nonatomic, copy, nullable) NSSet<NSString *> *hiddenOSCElements;

/// Optional PER-OWNER OSC element maps, for multi-owner plugins (Canvas) that
/// keep a separate hidden set per layer: keyed by owner id (layerID), each
/// value an element-key -> visible(BOOL) dictionary (the same shape persisted
/// under `oscElements`). `hiddenOSCElements` above stays the ACTIVE owner's
/// resolved set; this map is the store the host loads the active set from when
/// selection changes. nil for single-owner plugins (they use the global set).
@property(nonatomic, copy, nullable)
    NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *>
        *oscElementsByOwner;

/// The rack entry the user last clicked in a chained-shader plugin's rack list
/// (Mirage). SESSION-ONLY on purpose: it is not undoable, not persisted, and
/// not part of the timeline blob - selecting a row changes what the UI talks
/// about, never what renders. Kept here rather than only on the inspector view
/// so the other consumers in this process (the OSC's element routing, the AI
/// authoring target) can ask which entry is being edited. nil = the first
/// entry.
@property(nonatomic, copy, nullable) NSString *selectedRackEntryID;

/// Mirage's compare toolbar is viewer chrome, not project data. These flags
/// let the inspector mini-viewer and the FxPlug OSC show one shared session
/// state without writing a parameter (and therefore without adding undo
/// entries). Other plugins leave them at their zero defaults.
@property(nonatomic) BOOL mirageCompareBypassing;
@property(nonatomic) BOOL mirageCompareSplitEnabled;
@property(nonatomic) CGFloat mirageCompareSplitFraction;
@property(nonatomic) BOOL mirageCompareSelectionEnabled;
/// Which repeatable qualifier key the main viewer's selection matte shows.
/// Zero means the union of all keys. The Color panel keeps this in sync with
/// its active puck; like the other compare fields it is session-only.
@property(nonatomic) NSInteger mirageCompareActiveKey;
/// MirageViewerPickMode, kept integer here so the shared kit does not depend
/// on Mirage's Constants.h. Session-only and cleared after one click/Escape.
@property(nonatomic) NSInteger mirageViewerPickMode;

/// Mirage's shader-rack preview is the same kind of session-only viewer state
/// as the compare toolbar above. The inspector writes the enum's integer value
/// plus its focused rack entry; both the mini renderer and the main FxPlug
/// render read them. Zero / nil means the complete enabled chain.
@property(nonatomic) NSInteger mirageRackPreviewMode;
@property(nonatomic, copy, nullable) NSString *mirageRackPreviewEntryID;

/// YES while a guide is transiently forcing OSC visibility (see
/// `-kkForceOSCForGuideKeepingLabels:...`). The UI-state OSC refresh checks
/// this and skips re-applying the saved visibility, so an async
/// `parameterChanged` the guide itself triggered (e.g. an `activeTab` write
/// when it switches tabs) can't clobber the forced state. Cleared by
/// `-kkRestoreOSCForGuide:`.
@property(nonatomic) BOOL guideForcingOSC;

/// Last-known full UI-state dict (the parsed `kParamUIState` blob), refreshed
/// in the effect's `parameterChanged` where the param reads fresh. The OSC
/// rewrites this blob when it opt-hides an element; it must NOT clobber
/// inspector-owned keys (activeTab, loopEnabled, renderMode) with a stale read
/// of its own scope, so it merges into THIS cached dict instead. Same process
/// as the OSC, so it's current.
@property(nonatomic, copy, nullable) NSDictionary *lastUIState;

/// Pointer of the api manager that "owns" this state. Used by
/// `KKInstanceStateEnsureForAPI` to detect duplicate-UUID clones (FCP
/// copy/paste/cut clones the `kKKParamInstanceID` value) and mint a fresh
/// UUID for the second instance. Stored unsafe-unretained: only ever
/// pointer-compared, never dereferenced.
@property(nonatomic, assign, nullable) void *ownerAPIPointer;

@end

/// Reads `kKKParamInstanceID` from the api, cached on the api via
/// associated object for fast re-reads. Returns nil if no UUID has been
/// assigned yet (the first `createViewForParameterID` call generates and
/// persists one inside an action scope - see KKPlugin+CustomViews.m).
NSString *_Nullable KKInstanceUUIDForAPI(id<PROAPIAccessing> api);

/// Returns (or lazy-creates) the state for a given UUID. Uses the
/// immutable-copy static-map pattern from project_fxplug_static_mutability.md.
KKPluginInstanceState *_Nullable KKInstanceStateForUUID(
    NSString *_Nullable uuid);

/// Convenience wrapper: UUID lookup + state lookup in one call.
KKPluginInstanceState *_Nullable KKInstanceStateForAPI(id<PROAPIAccessing> api);

/// Like `KKInstanceStateForAPI` but generates and persists a UUID to
/// `kKKParamInstanceID` if one is not yet set, so subsequent lookups across
/// fresh FxPlug plugin instances resolve to the same state entry. Must be
/// called inside an `startAction:/endAction:` scope (required for the
/// string-param write). Any custom-UI creation that stores per-instance
/// state (e.g. gradient bar) should use this - otherwise, if the custom UI
/// runs before the first sequencer is registered, the state assignment
/// silently no-ops on nil and the UI stays disconnected until a remount.
KKPluginInstanceState *_Nullable KKInstanceStateEnsureForAPI(
    id<PROAPIAccessing> api);

/// Call from the plugin's `parameterChanged:` with every parameter ID; acts
/// only on `kKKParamInstanceID`. Re-reads the param and replaces the per-api
/// cached UUID when it differs.
///
/// This is what keeps the RENDER process honest across a paste-attributes:
/// pasting clones `kKKParamInstanceID`, the duplicate-owner detection above
/// re-mints a fresh UUID for the pasted clip (in the inspector's ViewBridge
/// process, whose createView captures the fresh value) - but the render process
/// had already cached the cloned UUID at its first render, and the cache had no
/// invalidation. The render then published its mini-viewer feed under the OLD
/// UUID's rendezvous paths while the inspector listened on the new ones: a
/// preview frozen on a stale descriptor whose IOSurface no longer exists.
void KKInstanceUUIDHandleParameterChanged(id<PROAPIAccessing> api,
                                          UInt32 parameterID);

/// Snapshot of all live per-instance states. Used by the OSC flush pump to
/// broadcast view updates across every effect instance - any single running
/// `drawOSC` (the OSC-selected effect) can deliver updates to every live
/// sequencer view on the timeline, not just its own.
NSArray<KKPluginInstanceState *> *KKAllInstanceStates(void);

NS_ASSUME_NONNULL_END
