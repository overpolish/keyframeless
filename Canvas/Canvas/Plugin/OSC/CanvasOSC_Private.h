/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Shared internals of CanvasOSC, split across category files (+Geometry,
// +State, +AutoSelect, +Input). Holds the controller properties + transient
// state and declares the cross-category method surface so each category can
// call the others without -Wundeclared-selector.

#import "CanvasOSC.h"
#import "CanvasPathEditController.h" // shared path anchor/handle editing
#import "CanvasPenController.h" // CanvasPenSurface + the shared pen state machine
#import "CanvasShapeController.h" // shared rect/ellipse drag-create tool
#import "CanvasToolbar.h" // CanvasToolbarTag + CanvasMakeToolbar (shared w/ mini)
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPositionOSC;
@class KKScaleOSC;
@class KKRotationOSC;
@class KKAnchorOSC;
@class KKToolbar;
@class KKPointOSC;
@class KKRingOSC;
@class CanvasPenController;
@class CanvasPathEditController;
@class CanvasShapeController;

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
  // The pen tool claims the whole canvas (minus the toolbar) so FCP routes
  // every click to the OSC, not just clicks over a handle.
  CanvasOSCPartPen = 7,
  // An anchor / tangent handle of the selected path's point-edit OSC.
  CanvasOSCPartPathEdit = 8,
  // The rect / ellipse tool claims the whole canvas (minus the toolbar) so FCP
  // routes the box drag to the OSC, like the pen.
  CanvasOSCPartShape = 9,
  // The body of an already-SELECTED layer: a drag here moves the whole
  // selection (paths shift points, images shift Position); a click selects it.
  CanvasOSCPartLayerMove = 10,
  // A corner-radius widget (its own "Corners" OSC element): a drag rounds the
  // corner; Opt-click toggles the element's visibility like any other handle.
  CanvasOSCPartCorner = 11,
};

// FxModifierKeys -> the surface-neutral CanvasPenModifiers used by the shared
// pen / shape / path-edit controllers. Defined once in CanvasOSC+Pen.m.
CanvasPenModifiers CanvasPenModsFromFxModifiers(NSUInteger m);

@interface CanvasOSC ()
// The three reusable sub-controls, concentric on the layer's Position handle.
@property(nonatomic, strong) KKPositionOSC *position;
@property(nonatomic, strong) KKScaleOSC *scale;
@property(nonatomic, strong) KKRotationOSC *rotation;
// The anchor pivot square (topmost), concentric region with the Position
// handle.
@property(nonatomic, strong) KKAnchorOSC *anchor;
// Set while the hover hit-test forced a move/eye/hand cursor, so the next hover
// can reset it to the arrow.
@property(nonatomic) BOOL pointCursorSet;
// Canvas-space centre the rotation rings + scale box sit on this tick: the
// member-local ANCHOR pivot (where the layer rotates/scales from), recomputed
// by
// -_applyGroupComposeOffsetAtTime: each draw / hit / mouse tick.
@property(nonatomic) CGPoint gizmoPivotCanvas;
// Layer the hover hit-test resolved for an auto-select pick; consumed by the
// matching mouseDown.
@property(nonatomic, copy, nullable) NSString *pendingPickLayerID;
// Body-drag move state (CanvasOSCPartLayerMove): the layer the press landed on,
// the Y-up object point at press, the pre-drag layer blob (so each tick
// translates from the original, not cumulatively), and whether a real drag
// happened (else mouseUp is a plain click = select).
@property(nonatomic, copy, nullable) NSString *layerMoveHitID;
@property(nonatomic) CGPoint layerMoveStartObj;
@property(nonatomic, copy, nullable) NSString *layerMoveStartBlob;
@property(nonatomic) BOOL layerMoveDidMove;

// The combined viewer toolbar (drag handle + grid/adaptive/spacing/snap),
// global screen chrome whose state lives in kParamUIState (not parameters).
@property(nonatomic, strong) KKToolbar *toolbar;
// While the drag handle is held: the mouse + toolbar centre at press (ioSurface
// px), and the viewport size cached from the last draw (mouse callbacks don't
// get it) so the drag can normalise the new position for UI-state storage.
@property(nonatomic) BOOL toolbarDragging;
// The conditional path-op groups the current toolbar was built with, so draw
// can rebuild the bar only when the selection crosses the show/hide threshold
// (the KKToolbar item list is fixed at init).
@property(nonatomic) BOOL toolbarShowsBooleans;
@property(nonatomic) BOOL toolbarShowsOutline;
@property(nonatomic) BOOL toolbarShowsCenterline;
@property(nonatomic) CGPoint toolbarPressMouse;
@property(nonatomic) CGPoint toolbarPressCenter;
@property(nonatomic) CGSize toolbarIOSize;
// The exact object-space cell size the grid LAST drew (after Auto). The snap
// reuses it so it can never diverge from the drawn lines (0 = not drawn yet).
@property(nonatomic) double drawnGridObjSpacingX;
@property(nonatomic) double drawnGridObjSpacingY;
// The shared pen state machine; this OSC is its drawing + persistence surface
// (CanvasOSC+Pen.m implements CanvasPenSurface). Created lazily.
@property(nonatomic, strong) CanvasPenController *penController;
// Shared anchor/handle editor for the selected path (CanvasOSC is its surface
// via the same CanvasPenSurface the pen uses).
@property(nonatomic, strong) CanvasPathEditController *pathEditController;
// Shared rect/ellipse drag-create tool (same CanvasPenSurface).
@property(nonatomic, strong) CanvasShapeController *shapeController;
// Set for the span of a pen overlay draw so the surface draw primitives know
// the FxImageTile + time to encode into.
@property(nonatomic, assign, nullable) FxImageTile *penDrawDest;
// Cached path-op fill preview: a CG-filled RGBA texture (red operands / green
// result) blitted over the viewer while hovering a path-op button. Rebuilt only
// when the signature (op + selection + playhead + dest size) changes, so a
// still hover doesn't re-render the bitmap every frame.
@property(nonatomic, strong, nullable) id<MTLTexture> pathOpFillTexture;
@property(nonatomic, copy, nullable) NSString *pathOpFillSig;
// YES once a live param write happened during the current edit gesture, so the
// mouseUp commit knows whether it still needs to write (a preview-only insert
// with no drag) or the per-tick drag writes already covered it.
@property(nonatomic) BOOL penLiveParamWritten;
// The tool seen on the previous draw, to detect a switch INTO the pen tool (and
// clear the lingering cursor-mode point selection then).
@property(nonatomic) NSInteger lastDrawnTool;
@property(nonatomic) CMTime penDrawTime;
// Reusable dot controls for the anchors + tangent handles, matching the
// Position path OSC's look (shared KKPointOSC, not hand-drawn squares).
@property(nonatomic, strong) KKPointOSC *penAnchorOSC;
@property(nonatomic, strong) KKPointOSC *penHandleOSC;
// Live-corner radius widget glyph: the shared KKRingOSC, tinted accent (or
// error at max), so it matches the Glow radius ring + Rounded's handle.
@property(nonatomic, strong) KKRingOSC *penCornerRingOSC;
@end

// Canvas-space geometry + sub-control feeding.
@interface CanvasOSC (Geometry)
- (double)_onScreenFrameMin;
- (double)_canvasAspect;
// Canvas-pixel lengths of the object-space unit axes (height feeds the stroke
// pick tolerance in CanvasHitTestLayerID). NO when the OSC API is absent.
- (BOOL)_objectBasisWidth:(double *)outW height:(double *)outH;
// Raw OBJECT (Y-down) <-> CANVAS (ioSurface px) conversions, no control offset.
- (CGPoint)_rawCanvasFromObjX:(double)ox y:(double)oy;
- (CGPoint)_rawObjFromCanvasX:(double)cx y:(double)cy;
- (void)_syncScaleControlAtTime:(CMTime)time;
- (void)_syncRotationControlAtTime:(CMTime)time;
// Reset the point controls' group hooks to identity (Position + Anchor stay 2D
// / member-local - see the .m note) and recompute the member-local anchor pivot
// the rotation rings + scale box centre on. Call at the top of draw / hit-test
// / mouse.
- (void)_applyGroupComposeOffsetAtTime:(CMTime)time;
@end

// Reading the inspector-published snapshots (layer blob + UIState) and writing
// back through the OSC's action scope - the OSC can't read the custom params.
@interface CanvasOSC (State)
- (NSArray<KKBezierPath *> *)_snapshotPaths;
- (nullable KKBezierPath *)_selectedLayer;
- (nullable NSString *)_resolvedSelectedLayerID;
// The full multi-selection set (layerIDs) + the boolean-op operands (selected
// vector paths in stack order). Both read kParamUIState's selectedLayerIDs.
- (NSArray<NSString *> *)_selectedLayerIDs;
- (NSArray<KKBezierPath *> *)_selectedVectorLayers;
- (BOOL)_selectedLayerLocked;
// Lone selected layer (exactly one selected) + whether the transform gizmo
// should show (lone image/group only). Drive the selection-type display rules.
- (nullable KKBezierPath *)_loneSelectedLayer;
- (BOOL)_showsTransformGizmo;
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
- (void)_toolbarMouseDownTag:(NSInteger)tag
                         atX:(double)x
                           y:(double)y
                      atTime:(CMTime)time;
- (void)_toolbarMouseDraggedAtX:(double)x y:(double)y;
- (void)_toolbarMouseUp;
// Control+letter tool shortcuts (^V/^X/^B/^G). Returns YES if it consumed the
// key.
- (BOOL)_handleToolbarKey:(unsigned short)asciiKey
                modifiers:(NSUInteger)modifiers;
// The active drawing tool from kParamUIState (CanvasToolbarTool*, default
// cursor).
- (NSInteger)_activeTool;
// Grid settings read from kParamUIState (defaults: off / Auto / 10 / off).
- (BOOL)_gridEnabled;
- (BOOL)_gridAdaptive;
- (NSInteger)_gridSpacing;
- (BOOL)_gridSnap;
@end

// Path boolean operations on the multi-selection (union / subtract / intersect
// / exclude). Reads the published blob, applies the op via the kit, writes the
// new stack + selects the result - all in one undo action.
@interface CanvasOSC (PathOps)
- (void)_handlePathBooleanOp:(KKBooleanOp)op atTime:(CMTime)time;
- (void)_handleOutlineOp;
- (void)_handleCenterlineOp;
// Delete the selected layer(s) from the stack (group-expanding), selecting a
// survivor, in one undo action. Returns NO when nothing is selected so the key
// handler can fall through.
- (BOOL)_deleteSelectedLayers;
- (void)_drawPathOpHoverPreviewInDestination:(FxImageTile *)dest
                                      atTime:(CMTime)time;
@end

// Grid overlay (under the gizmo), gated on the UI-state grid settings.
@interface CanvasOSC (Grid)
- (void)_drawGridWithWidth:(NSInteger)width
                    height:(NSInteger)height
          destinationImage:(FxImageTile *)destinationImage;
// Generic grid snap: pin a canvas point to the nearest grid intersection (no-op
// unless Snap is on). The Position / Anchor canvasSnapProvider blocks call
// this.
- (CGPoint)_snapCanvasPointToGrid:(CGPoint)cp;
@end

// Click-to-select: pick the layer under the cursor + commit the selection.
@interface CanvasOSC (AutoSelect)
- (BOOL)_autoSelectEnabled;
- (nullable NSString *)_pickLayerIDAtX:(double)x
                                     y:(double)y
                                atTime:(CMTime)time;
- (void)_commitPickSelectionWithModifiers:(NSUInteger)modifiers;
// Canvas point -> render OBJECT space (normalized, Y-UP), for body-drag deltas.
- (CGPoint)_objYUpAtCanvasX:(double)x y:(double)y;
@end

// Pen tool: this OSC is the drawing + persistence SURFACE for the shared
// CanvasPenController. The methods below are the input/draw entry points the
// other categories call; the CanvasPenSurface methods (coords, blob, draw
// primitives) are implemented in CanvasOSC+Pen.m. Mouse coords are CANVAS px.
@interface CanvasOSC (Pen) <CanvasPenSurface>
- (BOOL)_penToolActive;
// If a path is being drawn but the pen tool was deselected or the selection
// moved to another layer, confirm (end) the in-progress path as-is (no close).
// Call at the top of draw so a tool / layer switch finalises the current path.
- (void)_penConfirmIfContextLost;
// Returns YES if the pen consumed the click (always, while active).
- (BOOL)_penMouseDownAtX:(double)x
                       y:(double)y
               modifiers:(NSUInteger)modifiers
                  atTime:(CMTime)time;
- (void)_penMouseMovedAtX:(double)x y:(double)y;
// Click-drag after placing an anchor pulls its bezier handles (modifiers match
// the Position path OSC: Shift = axis-lock, Cmd = 45deg snap, Ctrl = cusp).
- (void)_penMouseDraggedAtX:(double)x
                          y:(double)y
                  modifiers:(NSUInteger)modifiers;
- (void)_penMouseUp;
// Return/Enter finishes an open path; Esc cancels. YES if consumed.
- (BOOL)_penKeyDown:(unsigned short)asciiKey
          modifiers:(NSUInteger)modifiers
             atTime:(CMTime)time;
// render-object (Y-up) <-> CANVAS px (Y flipped at the boundary). Implemented
// in +Pen.m; called by the +PenSurface protocol methods + the +PenDraw overlay.
- (CGPoint)_penCanvasFromObj:(CGPoint)objYUp;
// The cursor the pen tool shows at a CANVAS point: the close-shape glyph when
// hovering the first anchor (with a loop placed), else the pen glyph.
- (NSCursor *)_penCursorForCanvasX:(double)x y:(double)y;
// Path point editing (cursor tool): hit-test / drag the selected path's anchors
// + handles via the shared CanvasPathEditController. Coords are CANVAS px.
- (CanvasPathEditHit)_pathEditHitAtX:(double)x y:(double)y;
- (BOOL)_pathEditMouseDownAtX:(double)x y:(double)y modifiers:(NSUInteger)mods;
- (void)_pathEditMouseDraggedAtX:(double)x
                               y:(double)y
                       modifiers:(NSUInteger)mods;
- (void)_pathEditMouseUp;
- (BOOL)_pathEditDragging;
@end

// Pen / path-edit OVERLAY draw orchestration (implemented in +PenDraw.m). These
// compose the +Pen.m surface draw primitives into the per-tick overlay and are
// called from CanvasOSC's draw pass.
@interface CanvasOSC (PenDraw)
- (void)_drawPenInProgressWithWidth:(NSInteger)width
                             height:(NSInteger)height
                   destinationImage:(FxImageTile *)destinationImage
                             atTime:(CMTime)time;
// The selected vector path's edit OSC (anchors + connecting curve), read-only,
// projected to where the stroke renders. No-op unless the selected layer is a
// drawn path. (Drawn alongside the gizmo for now; gated to enter-mode later.)
- (void)_drawSelectedPathEditOSCInDestination:(FxImageTile *)destinationImage
                                       atTime:(CMTime)time;
// Silhouette of the non-primary members of a viewer multi-selection.
- (void)_drawMultiSelectHighlightInDestination:(FxImageTile *)destinationImage
                                        atTime:(CMTime)time;
// The marquee rubber-band, drawn independently of the selection count.
- (void)_drawMarqueeInDestination:(FxImageTile *)destinationImage;
@end

// Rect / ellipse tool: this OSC is the drag-create SURFACE for the shared
// CanvasShapeController. Mouse coords are CANVAS px.
@interface CanvasOSC (Shape)
- (BOOL)_shapeToolActive;
- (void)_shapeMouseDownAtX:(double)x
                         y:(double)y
                 modifiers:(NSUInteger)modifiers;
- (void)_shapeMouseDraggedAtX:(double)x
                            y:(double)y
                    modifiers:(NSUInteger)modifiers;
- (void)_shapeMouseUp;
- (void)_drawShapeInProgressInDestination:(FxImageTile *)destinationImage
                                   atTime:(CMTime)time;
@end

NS_ASSUME_NONNULL_END
