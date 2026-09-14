/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>

@class KKPositionMiniController;

NS_ASSUME_NONNULL_BEGIN

/// Manages 1..N mini-viewer Position OSCs at once - the mini sibling of a
/// viewer that draws every KKPositionOSC in a loop. A plugin whose renderer
/// exposes several point OSCs (e.g. Shader's `#point osc` lanes, or a single
/// Position) owns one of these, feeds it the lane labels, and forwards its
/// KKMiniViewerDelegate methods to the matching call here. There is no
/// "primary" handle: every point draws through `extraPointHandleCenters` /
/// `extraMotionPaths` and drags through one shared active-controller pointer,
/// so N points behave identically.
///
/// Each point is gated exactly like the main viewer's KKPositionOSC:
/// - PATH (line + anchors) shows when the lane matches the editing context
///   (`isConstantLabel:`) and its "<lane> Path" element isn't hidden, at EVERY
///   fraction (KKPositionOSC.drawPath gates on pathEnabled, not keypose-time);
/// - the ARC HANDLE additionally requires the lane's own visibility AND the
/// lane
///   sitting exactly ON a keypose at editFraction (KKLaneKeyedAtFraction), so a
///   lane between/past its keyposes shows just its path + anchors, no arc.
///
/// Reads the host via KKMiniViewerRenderer's public hooks (`isConstantLabel:`,
/// `labelVisibleOrRevealing:`, `editFraction`, `timeline`,
/// `ghostAlphaForLabel:`, `kkVisibilityCursorForLabel:`,
/// `onHandleVisibilityToggled`, `onTimelinePersist`) plus each controller's
/// KKPositionMiniController.
@interface KKPointOSCSet : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Rebuild the controllers to match `laneLabels` (each lane's path label is
/// "<label> Path"). Reuses an existing controller when its label survives so an
/// in-flight drag / snap state isn't dropped; cheap no-op when the set is
/// unchanged. Pass empty to clear.
- (void)setLaneLabels:(NSArray<NSString *> *)laneLabels;

/// The controllers in `laneLabels` order (for a host that needs the first for a
/// guide target, etc.). Empty when no point OSC is declared.
@property(nonatomic, copy, readonly)
    NSArray<KKPositionMiniController *> *controllers;

#pragma mark Draw geometry (forward the matching delegate methods here)

/// One `@{@"center", @"alpha"}` glyph per point active in the current context -
/// feed to `-miniViewer:extraPointHandleGlyphsForContentRect:`. The alpha dims
/// an Opt-revealed hidden handle.
- (NSArray<NSDictionary<NSString *, id> *> *)handleGlyphsForContentRect:
    (CGRect)cr;
/// One `@{@"poly", @"segs", @"anchors", @"alpha"}` bundle per point whose path
/// is active - feed to `-miniViewer:extraMotionPathsForContentRect:`.
- (NSArray<NSDictionary<NSString *, id> *> *)motionPathBundlesForContentRect:
    (CGRect)cr;

/// The active point handle's centre - the first controller whose arc handle is
/// drawn in the current editing context (same gate as
/// `handleGlyphsForContentRect`). For a host that needs to spotlight or target
/// the handle from a guide; forward the base renderer's
/// `pointHandleCenter:forContentRect:` hook here. NO when no handle is active.
- (BOOL)activeHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr;
/// Where that same active controller's handle *would* sit at explicit lane
/// values - the guide's drag destination. Forward `pointHandleCenter:forValues:
/// forContentRect:` here.
- (BOOL)activeHandleCenter:(out CGPoint *)outCenter
                 forValues:(NSArray<NSNumber *> *)values
            forContentRect:(CGRect)cr;

#pragma mark Interaction (forward the matching delegate methods here)

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Grab whatever point handle / path anchor / tangent is under `p`. YES if
/// claimed (the host should NOT fall through to super).
- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas;
/// Live-update the active drag. YES if a drag is active (host should not
/// fall through to super).
- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers;
/// End the active drag, persisting the blob for a path (anchor/tangent) drag.
/// YES if a drag was active (host should not call super).
- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas;
/// Toggle the smooth flag of the keypose under `p`. YES if one was toggled.
- (BOOL)doubleClickAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Opt-click to hide the handle / path element under `p`. YES if one toggled.
- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas;
/// Snap-guide read-back (proxies the active controller's shared snap engine).
- (void)snapGuideHasX:(out BOOL *)hasX
                    X:(out CGFloat *)outX
         fromKeyposeX:(out BOOL *)fromKeyposeX
                 hasY:(out BOOL *)hasY
                    Y:(out CGFloat *)outY
         fromKeyposeY:(out BOOL *)fromKeyposeY;

@end

NS_ASSUME_NONNULL_END
