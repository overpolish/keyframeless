/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Shared internals of CanvasOSC, split across category files (+Geometry, +State,
// +AutoSelect, +Input). Holds the controller properties + transient state and
// declares the cross-category method surface so each category can call the
// others without -Wundeclared-selector.

#import "CanvasOSC.h"
#import "CanvasToolbar.h" // CanvasToolbarTag + CanvasMakeToolbar (shared w/ mini)
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPositionOSC;
@class KKScaleOSC;
@class KKRotationOSC;
@class KKAnchorOSC;
@class KKToolbar;

NS_ASSUME_NONNULL_BEGIN

// This control's own activePart numbers (Position handle / anchor dot, the
// motion-path tangent handle, the scale box, the rotation rings, and the
// auto-select layer pick). Match the controllers' activePart wiring in -init.
typedef NS_ENUM(NSInteger, CanvasOSCPart) {
  CanvasOSCPartNone = 0,
  CanvasOSCPartPosition = 1,
  CanvasOSCPartScale = 2,
  CanvasOSCPartPath = 3,
  CanvasOSCPartRotation = 4,
  CanvasOSCPartLayerPick = 5,
  CanvasOSCPartAnchor = 6,
};

@interface CanvasOSC ()
// The three reusable sub-controls, concentric on the layer's Position handle.
@property(nonatomic, strong) KKPositionOSC *position;
@property(nonatomic, strong) KKScaleOSC *scale;
@property(nonatomic, strong) KKRotationOSC *rotation;
// The anchor pivot square (topmost), concentric region with the Position handle.
@property(nonatomic, strong) KKAnchorOSC *anchor;
// Set while the hover hit-test forced a move/eye/hand cursor, so the next hover
// can reset it to the arrow.
@property(nonatomic) BOOL pointCursorSet;
// Canvas-space centre the rotation rings + scale box sit on this tick: the
// member-local ANCHOR pivot (where the layer rotates/scales from), recomputed by
// -_applyGroupComposeOffsetAtTime: each draw / hit / mouse tick.
@property(nonatomic) CGPoint gizmoPivotCanvas;
// Layer the hover hit-test resolved for an auto-select pick; consumed by the
// matching mouseDown.
@property(nonatomic, copy, nullable) NSString *pendingPickLayerID;

// The combined viewer toolbar (drag handle + grid/adaptive/spacing/snap), global
// screen chrome whose state lives in kParamUIState (not parameters).
@property(nonatomic, strong) KKToolbar *toolbar;
// While the drag handle is held: the mouse + toolbar centre at press (ioSurface
// px), and the viewport size cached from the last draw (mouse callbacks don't
// get it) so the drag can normalise the new position for UI-state storage.
@property(nonatomic) BOOL toolbarDragging;
@property(nonatomic) CGPoint toolbarPressMouse;
@property(nonatomic) CGPoint toolbarPressCenter;
@property(nonatomic) CGSize toolbarIOSize;
// The exact object-space cell size the grid LAST drew (after Auto). The snap
// reuses it so it can never diverge from the drawn lines (0 = not drawn yet).
@property(nonatomic) double drawnGridObjSpacingX;
@property(nonatomic) double drawnGridObjSpacingY;
@end

// Canvas-space geometry + sub-control feeding.
@interface CanvasOSC (Geometry)
- (double)_onScreenFrameMin;
- (double)_canvasAspect;
// Raw OBJECT (Y-down) <-> CANVAS (ioSurface px) conversions, no control offset.
- (CGPoint)_rawCanvasFromObjX:(double)ox y:(double)oy;
- (CGPoint)_rawObjFromCanvasX:(double)cx y:(double)cy;
- (void)_syncScaleControlAtTime:(CMTime)time;
- (void)_syncRotationControlAtTime:(CMTime)time;
// Reset the point controls' group hooks to identity (Position + Anchor stay 2D /
// member-local - see the .m note) and recompute the member-local anchor pivot the
// rotation rings + scale box centre on. Call at the top of draw / hit-test /
// mouse.
- (void)_applyGroupComposeOffsetAtTime:(CMTime)time;
@end

// Reading the inspector-published snapshots (layer blob + UIState) and writing
// back through the OSC's action scope - the OSC can't read the custom params.
@interface CanvasOSC (State)
- (NSArray<KKBezierPath *> *)_snapshotPaths;
- (nullable KKBezierPath *)_selectedLayer;
- (nullable NSString *)_resolvedSelectedLayerID;
- (BOOL)_selectedLayerLocked;
- (NSDictionary *)_uiStateDict;
- (void)_writeUIStateMerging:(void (^)(NSMutableDictionary *state))mutate;
- (void)_persistSelectedLayerTimeline:(KKTimeline *)tl;
@end

// The combined viewer toolbar (grid + drag handle), screen chrome backed by
// kParamUIState. Build / draw / hit-test / drag, all coords in ioSurface px.
@interface CanvasOSC (Toolbar)
- (void)_setupToolbar;
- (void)_drawToolbarWithWidth:(NSInteger)width
                       height:(NSInteger)height
             destinationImage:(FxImageTile *)destinationImage;
// Raw KKToolbar hit result: an item tag, 0 (miss), or -1 (toolbar body).
- (NSInteger)_toolbarHitTestAtX:(double)x y:(double)y;
- (void)_toolbarMouseDownTag:(NSInteger)tag atX:(double)x y:(double)y;
- (void)_toolbarMouseDraggedAtX:(double)x y:(double)y;
- (void)_toolbarMouseUp;
// Control+letter tool shortcuts (^V/^X/^B/^G). Returns YES if it consumed the key.
- (BOOL)_handleToolbarKey:(unsigned short)asciiKey modifiers:(NSUInteger)modifiers;
// Grid settings read from kParamUIState (defaults: off / Auto / 10 / off).
- (BOOL)_gridEnabled;
- (BOOL)_gridAdaptive;
- (NSInteger)_gridSpacing;
- (BOOL)_gridSnap;
@end

// Grid overlay (under the gizmo), gated on the UI-state grid settings.
@interface CanvasOSC (Grid)
- (void)_drawGridWithWidth:(NSInteger)width
                    height:(NSInteger)height
          destinationImage:(FxImageTile *)destinationImage;
// Generic grid snap: pin a canvas point to the nearest grid intersection (no-op
// unless Snap is on). The Position / Anchor canvasSnapProvider blocks call this.
- (CGPoint)_snapCanvasPointToGrid:(CGPoint)cp;
@end

// Click-to-select: pick the layer under the cursor + commit the selection.
@interface CanvasOSC (AutoSelect)
- (BOOL)_autoSelectEnabled;
- (nullable NSString *)_pickLayerIDAtX:(double)x y:(double)y atTime:(CMTime)time;
- (void)_commitPickSelection;
@end

NS_ASSUME_NONNULL_END
