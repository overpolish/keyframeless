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
- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count;
- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj;
/// Draw the marquee rubber-band. `surfaceRect` is in SURFACE points (not object
/// space - it's the raw drag rectangle). Stroked in the host accent.
- (void)penDrawMarqueeRect:(CGRect)surfaceRect;
@end

/// The surface-agnostic pen-drawing state machine: placing anchors, pulling
/// bezier handles, closing / finishing, snap ghost, single-undo commits, and
/// the overlay preview. Shared by the viewer OSC and the mini-viewer so both
/// behave identically and new drawing features land once.
@interface CanvasPenController : NSObject
- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface;
@property(nonatomic, readonly) BOOL active; // a path is being drawn

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
