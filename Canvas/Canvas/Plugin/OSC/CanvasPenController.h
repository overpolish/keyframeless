/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CanvasPenCursorKind) {
  CanvasPenCursorPen = 0,   // place the next anchor
  CanvasPenCursorClose = 1, // clicking here ends the path (first / last anchor)
};

// Surface-neutral modifier flags. Each surface translates its native modifiers
// (FxModifierKeys for the viewer, NSEventModifierFlags for the mini) into
// these.
typedef NS_OPTIONS(NSUInteger, CanvasPenModifiers) {
  CanvasPenModNone = 0,
  CanvasPenModShift = 1 << 0, // axis-lock the handle / add to selection
  CanvasPenModCmd = 1 << 1,   // 45deg snap the handle
  CanvasPenModCtrl = 1 << 2,  // cusp (drop the mirrored in-handle)
  CanvasPenModOpt = 1 << 3,   // subtract from a marquee selection
};

/// A surface that the shared pen controller draws onto + drives: the FCP viewer
/// OSC or the inspector mini-viewer. It abstracts everything that differs
/// between the two - coordinate conversion, grid snap, layer-blob I/O, and the
/// overlay drawing primitives. ALL object points crossing this protocol are
/// NORMALIZED and Y-UP (the KKBezierPath point space); the surface owns any
/// flip to its own space. "Surface points" are the surface's own input space
/// (the viewer's ioSurface px / the mini's view points).
@protocol CanvasPenSurface <NSObject>
- (CGPoint)penObjFromSurfaceX:(double)x y:(double)y; // raw, no snap
- (CGPoint)penSnappedObjFromSurfaceX:(double)x
                                   y:(double)y; // grid-snapped (or raw)
- (CGPoint)penSurfacePointFromObj:(CGPoint)objYUp;
- (BOOL)penGridSnapping;
- (double)
    penCanvasAspect; // outputW/outputH, for 45deg handle snap in pixel space
- (BOOL)penToolActive;

- (nullable KKBezierPath *)penLayerWithID:(NSString *)layerID;
- (nullable NSString *)penSelectedLayerID;
/// The FULL selection set (stack order). The path-edit controller uses the count
/// to tell the single-path point-edit context (one editable path -> a marquee
/// selects its anchors) from the 0 / multi states (marquee selects layers).
- (NSArray<NSString *> *)penSelectedLayerIDs;
/// Clear the whole layer selection - a plain click on empty canvas. The viewer
/// writes an empty selection; the mini is bounded by its popover context (it may
/// only collapse to the primary, since the popover stays bound to a layer).
- (void)penDeselectAll;
/// Layers that must NOT be selectable in the current context (a popover scope -
/// the constants popover greys out animated-only layers, a keypose popover greys
/// out layers with no keypose at that time). The marquee excludes these so it
/// can't select a layer a click can't. Empty / nil on the viewer (no scope).
- (nullable NSSet<NSString *> *)penNonSelectableLayerIDs;
/// Identifies this surface for cross-process selection sync ("osc" / "mini").
- (NSString *)penSurfaceTag;
/// The full layer stack + the current edit fraction, so the path-edit
/// controller can project the selected path's geometry through its transform +
/// groups (pen CREATION is member-local, but EDITING a transformed/grouped path
/// needs these).
- (NSArray<KKBezierPath *> *)penAllLayers;
- (double)penEditFraction;
/// One undo action: decode the blob, run `mutate`, write it back; if `selectID`
/// is non-nil, set that layer as the selection in the SAME action.
- (void)penMutateBlob:(void (^)(NSMutableArray<KKBezierPath *> *paths))mutate
        selectLayerID:(nullable NSString *)selectID;
/// LIVE (no undo) preview during a continuous drag: swap in `paths` so the OSC
/// overlay (and, where it renders from this state, the surface) updates without
/// committing an undo step.
- (void)penSetLiveLayers:(NSArray<KKBezierPath *> *)paths;
/// PREVIEW-ONLY update: like penSetLiveLayers but guaranteed NOT to write the
/// param even on a surface that writes live (the viewer). Use when the geometry
/// changed structurally but the RENDERED shape did not (e.g. a curve-preserving
/// point insert), so the OSC overlay updates yet the single undo is deferred to
/// penCommitLiveLayers - avoiding a separate undo step at mouseDown.
- (void)penPreviewLayers:(NSArray<KKBezierPath *> *)paths;
/// Commit the live / preview state as ONE undo action (called on drag end).
- (void)penCommitLiveLayers;

/// Overlay draw primitives, called during the surface's draw pass. Inputs are
/// normalized Y-up object points; the surface converts + strokes/fills.
- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active;
/// An anchor dot in the WARNING colour (same glyph + shadow as the others) -
/// used to flag the open endpoint the pen will continue from when hovered.
- (void)penDrawWarnDotAtObj:(CGPoint)objYUp;
/// A haloed accent RING centred at `objYUp` - the live-corner radius widget,
/// drawn hollow so it reads as a distinct control vs the filled anchor dots.
/// `maxed` tints it the error colour when the radius is at its clamp.
- (void)penDrawRingAtObj:(CGPoint)objYUp maxed:(BOOL)maxed;
- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count;
/// Like penDrawCurveObjPoints but in an explicit RGBA colour - used by the
/// path-operation hover preview (red = removed, green = result).
- (void)penDrawColoredCurveObjPoints:(const CGPoint *)objPts
                               count:(NSUInteger)count
                               color:(simd_float4)color;
/// Like penDrawColoredCurveObjPoints but each point is snapped to a whole
/// surface pixel (floor + 0.5, like the grid) so the dimmed multi-select layer
/// box reads crisp instead of soft on sub-pixels. For axis-aligned boxes only;
/// a rotated box still snaps per corner (best effort).
- (void)penDrawSnappedLoopObjPoints:(const CGPoint *)objPts
                              count:(NSUInteger)count
                              color:(simd_float4)color;
- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj;
/// Draw the marquee rubber-band. `surfaceRect` is in SURFACE points (not object
/// space - it's the raw drag rectangle). Stroked in the host accent.
- (void)penDrawMarqueeRect:(CGRect)surfaceRect;
/// Commit a LAYER selection from the marquee when it fully encompasses one or
/// more layers. `additive` extends the current selection (Shift); otherwise it
/// replaces it. `layerIDs` are stack-ordered (topmost first); the surface picks
/// the primary edit target and routes through its own selection plumbing.
- (void)penSelectLayerIDs:(NSArray<NSString *> *)layerIDs additive:(BOOL)additive;
@end

/// The surface-agnostic pen-drawing state machine: placing anchors, pulling
/// bezier handles, closing / finishing, snap ghost, single-undo commits, and
/// the overlay preview. Shared by the viewer OSC and the mini-viewer so both
/// behave identically and new drawing features land once.
@interface CanvasPenController : NSObject
- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface;
@property(nonatomic, readonly) BOOL active; // a path is being drawn
/// In-progress point count (a held first point counts as 1), 0 when idle.
- (NSInteger)inProgressPointCount;
/// The last placed in-progress point in OBJECT space (y-up). NO when idle.
- (BOOL)lastInProgressPointObj:(out CGPoint *)outObj;

// All coords are SURFACE points. mouseDown returns YES (the pen consumed it).
- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods;
- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods;
- (void)mouseUp;
- (void)mouseMovedAtX:(double)x y:(double)y;
- (BOOL)keyDown:(unsigned short)asciiKey; // Esc cancels, Return/Enter finishes
- (void)confirmIfContextLost; // tool / layer switch -> finalize as-is
- (void)draw;                 // emits the surface draw primitives
- (CanvasPenCursorKind)cursorKindAtX:(double)x y:(double)y;
@end

NS_ASSUME_NONNULL_END
