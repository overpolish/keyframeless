/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the chrome-less Layers panel that appears beside a value/constants
/// editing popover. Observes the kit's static-values popover open/close
/// notifications (scoped to one lanes view) and shows the panel to the LEFT of
/// the popover as a child window, registered keep-alive so clicking it doesn't
/// dismiss the popover. Increment 1: placeholder content (positioning only).
@protocol PROAPIAccessing;

@interface CanvasLayerListController : NSObject
- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView
                       apiManager:(id<PROAPIAccessing>)apiManager;
- (void)invalidate;
/// Host-recognized object (the plugin) to open parameter actions with;
/// forwarded to the layer list so its param writes actually persist.
@property(nonatomic, weak, nullable) id paramActionTarget;
/// Number of template (animatable) params per layer, so the panel can tell when
/// a layer is fully animated (no constants) and gray it in the Constants popover.
@property(nonatomic) NSUInteger templateLaneCount;
/// The host's currently-selected layer, used to pre-highlight the panel when it
/// opens beside a popover that doesn't drive the highlight itself (e.g. the
/// Animated dropdown).
@property(nonatomic, copy, nullable) NSString *selectedLayerID;
/// Re-read the layer blob and rebuild the panel (forwarded on undo/redo). A
/// no-op if the panel hasn't been created yet.
- (void)reload;
/// The current decoded layer stack, read straight from the param (works even
/// while the panel is closed). Used to feed the mini-viewer renderer.
- (NSArray<KKBezierPath *> *)currentLayerPaths;
/// Persist `paths` to kParamLayerData in one undo action (works whether or not
/// the panel is open). Used by the mini-viewer pen tool to commit drawn layers.
- (void)writePaths:(NSArray<KKBezierPath *> *)paths;
/// Fired when the panel's primary selection changes (that layer's layerID, or
/// nil). The host uses it to switch which layer the inspector timeline edits.
@property(nonatomic, copy, nullable) void (^onPrimaryLayerSelected)
    (NSString *_Nullable layerID);
/// Highlight `layerID` in the panel's list WITHOUT firing onPrimaryLayerSelected
/// (mirrors a keypose popover's active layer into the list).
- (void)highlightLayerID:(nullable NSString *)layerID;
/// "Auto-select layers" toggle state, mirrored onto the panel's checkbox when it
/// (re)opens. Setting it does NOT fire onAutoSelectToggled.
@property(nonatomic) BOOL autoSelect;
/// Fired when the user flips the panel's "Auto-select layers" checkbox.
@property(nonatomic, copy, nullable) void (^onAutoSelectToggled)(BOOL on);
/// Fired when the set of non-selectable layers changes (a popover opened with
/// its gating, or closed -> nil). Lets the host mirror the same gating onto the
/// mini-viewer's auto-select. Same set passed to the panel's grayed rows.
@property(nonatomic, copy, nullable) void (^onNonSelectableLayersChanged)
    (NSSet<NSString *> *_Nullable layerIDs);
@end

NS_ASSUME_NONNULL_END
