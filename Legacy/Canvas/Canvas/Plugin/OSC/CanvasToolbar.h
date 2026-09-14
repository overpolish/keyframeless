/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKPathBoolean.h> // KKBooleanOp

@class KKToolbar;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

// Combined toolbar item tags (screen chrome, not tied to a parameter). 100+ so
// they never collide with the gizmo's CanvasOSCPart values. Shared by the
// viewer OSC and the inspector mini-viewer so both bars use the same tags.
typedef NS_ENUM(NSInteger, CanvasToolbarTag) {
  CanvasToolbarBackground = 99, // body hit (swallow the click, no action)
  CanvasToolbarDragHandle = 100,
  // Drawing tools (radio group; UNWIRED for now - selecting one only stores +
  // highlights it, the behaviour comes back with the drawing increments).
  CanvasToolbarToolCursor = 101,
  CanvasToolbarToolPen = 102,
  CanvasToolbarToolRect = 103,
  CanvasToolbarToolEllipse = 104,
  // Grid controls (independent toggles + a spacing stepper).
  CanvasToolbarGrid = 110,
  CanvasToolbarGridAdaptive = 111,
  CanvasToolbarGridSpacing = 112,
  CanvasToolbarSnap = 113,
  // Path operations: conditional groups inserted between the tool radio and the
  // grid group. Outline shows when one stroke-bearing path is selected; the
  // booleans show when two or more paths are selected.
  CanvasToolbarPathOutline = 120,
  CanvasToolbarPathUnion = 121,
  CanvasToolbarPathSubtract = 122,
  CanvasToolbarPathIntersect = 123,
  CanvasToolbarPathXOR = 124,
  // Centerline tracing: the inverse of outline. Shows when a filled vector
  // path is selected (a filled blob that should collapse to a centerline).
  CanvasToolbarPathCenterline = 125,
};

/// Builds the combined Canvas toolbar (drag handle | tool radio |
/// [outline] | [booleans] | separator | grid toggles) with localized hover
/// tooltips. Shared so the viewer OSC and the inspector mini render an
/// identical bar. `apiManager` may be nil (KKToolbar only stores it).
/// `includeOutline` inserts the stroke-to-outline button (one stroke path
/// selected); `includeBooleans` inserts the union/subtract/intersect/exclude
/// group (two or more paths selected). The caller drives per-frame state
/// (activeTags, the adaptive icon swap, the spacing number, position) on the
/// returned bar and rebuilds it when the include flags change.
KKToolbar *CanvasMakeToolbar(id<PROAPIAccessing> _Nullable apiManager,
                             BOOL includeOutline, BOOL includeBooleans,
                             BOOL includeCenterline);

/// Applies the per-frame toolbar state shared by the viewer OSC and the mini:
/// the active-highlight set (the radio tool + whichever grid toggles are on),
/// the adaptive icon swap, and the spacing number label. Both surfaces call
/// this so a single rule drives both bars.
void CanvasToolbarApplyState(KKToolbar *toolbar, NSInteger tool, BOOL gridOn,
                             BOOL adaptive, BOOL snap, NSInteger spacing);

/// The grid cell-size value after the spacing stepper is clicked once, cycling
/// through the shared preset list. Both surfaces use this so they never drift.
NSInteger CanvasToolbarNextGridSpacing(NSInteger current);

/// Maps a tool keyboard shortcut letter (lowercase v/x/b/g) to its toolbar tag,
/// or 0 if the letter isn't a tool shortcut. One table for both surfaces.
CanvasToolbarTag CanvasToolbarToolTagForLetter(unichar letter);

/// Maps a path-operation toolbar tag to its operation. Returns NO for any other
/// tag. For the stroke-to-outline tag `*outOutline` is YES; for the centerline
/// tag `*outCenterline` is YES; for a boolean tag `*outOp` is set. The two BOOL
/// out-params are always cleared first, so a boolean tag leaves both NO.
BOOL CanvasToolbarTagToPathOp(NSInteger tag, BOOL *_Nullable outOutline,
                              KKBooleanOp *_Nullable outOp,
                              BOOL *_Nullable outCenterline);

NS_ASSUME_NONNULL_END
