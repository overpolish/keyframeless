/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// The Layers panel content: a "Layers" header over a scrollable well of layer
/// rows. Ported from the old Canvas layer list as the VIEW + minimal IO - no
/// KKCanvasStore / param-sync / OSC pump. Layers are a KKBezierPath blob in the
/// `kParamLayerData` string param; this view reads/writes it directly (via the
/// action-scope APIs) and rebuilds rows. Drop image files to add layers.
@interface CanvasLayerListView : NSView
/// Setting this reads the current layers and builds the rows.
@property(nonatomic, weak, nullable) id<PROAPIAccessing> apiManager;
/// The object passed to startAction:/endAction: when reading/writing params.
/// Must be a host-recognized parameter editor (the plugin instance); a plain
/// view the host doesn't know about opens a throwaway action whose writes are
/// discarded. Falls back to self if unset.
@property(nonatomic, weak, nullable) id paramActionTarget;
/// Re-read the layer blob and rebuild (call from the host's parameterChanged:
/// so undo/redo of the layer data is reflected here).
- (void)reloadFromParam;
/// Layers that can't be selected as the edit target right now (grayed out): a
/// keypose popover passes the layers with no keypose at its time. Every other
/// interaction stays live. Pass nil/empty to make all layers selectable (the
/// Constants popover, or no popover open).
- (void)setNonSelectableLayerIDs:(nullable NSSet<NSString *> *)layerIDs;

/// Tooltip shown on a grayed (non-selectable) row, explaining WHY it can't be
/// edited here (e.g. "no keypose at the current frame"). Reason depends on the
/// open popover's kind, so the controller sets it alongside the set above.
@property(nonatomic, copy, nullable) NSString *nonSelectableReason;
/// Highlight the row for `layerID` as the selection WITHOUT firing
/// onPrimaryLayerSelected (used to mirror a keypose popover's active layer into
/// the list). nil clears the selection.
- (void)highlightLayerID:(nullable NSString *)layerID;
/// Fired when the primary (single) selection changes, with that layer's
/// layerID (nil when the selection is cleared / multi). Drives which layer the
/// inspector timeline edits.
@property(nonatomic, copy, nullable) void (^onPrimaryLayerSelected)
    (NSString *_Nullable layerID);
/// Fired as the pointer enters / leaves a row, with that row's layerID (nil on
/// exit). Drives the mini-viewer's transient hover highlight so it's clear which
/// layer a row is. Pure UI state - never persisted.
@property(nonatomic, copy, nullable) void (^onLayerHovered)
    (NSString *_Nullable layerID);
/// The layerIDs of every currently-selected row, top-to-bottom. Drives the
/// viewer's path-operation buttons (which need the full multi-selection, not
/// just the primary). Empty when nothing is selected.
- (NSArray<NSString *> *)selectedLayerIDs;
/// Set the multi-selection to exactly these layerIDs (unknown ids ignored),
/// WITHOUT firing onPrimaryLayerSelected - used to mirror a mini-viewer multi
/// select onto the panel rows.
- (void)setSelectionToLayerIDs:(NSArray<NSString *> *)layerIDs;
/// "Auto-select layers" toggle state (clicking a layer in the viewer selects
/// it). Drives the checkbox above the list; setting it updates the checkbox
/// without firing onAutoSelectToggled.
@property(nonatomic) BOOL autoSelect;
/// Fired when the user flips the "Auto-select layers" checkbox.
@property(nonatomic, copy, nullable) void (^onAutoSelectToggled)(BOOL on);
@end

NS_ASSUME_NONNULL_END
