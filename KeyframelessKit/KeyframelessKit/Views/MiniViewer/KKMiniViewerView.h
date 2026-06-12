/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKOSCShaderTypes.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKMiniViewerView;

/// One rectangular box OSC for the mini-viewer to render: an outline, 8 grab
/// handles (4 corners + 4 edge midpoints), and an optional size readout. The
/// mini-viewer equivalent of the viewer's KKBoxOSC - crop, scale, and any
/// future box gizmo are just descriptors, drawn through one shared path. All
/// geometry is in overlay points (y-up).
@interface KKMiniBox : NSObject
/// Box outline rect.
@property(nonatomic) CGRect rect;
/// The 8 handle centres (typically 4 corners then 4 edge midpoints). Drawn with
/// the shared `KKPointOSC` glyph.
@property(nonatomic, copy) NSArray<NSValue *> *handleCenters;
/// Size readout drawn trailing-aligned below the box's lower-right corner, or
/// nil for none (e.g. "1920 x 1080" for crop, "100% x 100%" for scale).
@property(nonatomic, copy, nullable) NSString *readout;
/// Draw alpha for the whole box (border + handles + readout): 1.0 normal, 0.3
/// when it's a revealed opt-hold ghost.
@property(nonatomic) CGFloat ghostAlpha;

+ (instancetype)boxWithRect:(CGRect)rect
              handleCenters:(NSArray<NSValue *> *)handleCenters
                    readout:(nullable NSString *)readout
                 ghostAlpha:(CGFloat)ghostAlpha;
@end

/// Plugin-supplied interaction delegate. Hooks are declared now and wired in
/// later phases (handle drawing, hit-testing, drag deltas reported as value
/// mutations). Points are clip-normalized: (0,0) top-left, (1,1) bottom-right.
@protocol KKMiniViewerDelegate <NSObject>
@optional
/// YES if the effect should be rendered into a processed texture sized to the
/// DISPLAY resolution (downscaled to the content rect, capped at source) rather
/// than the full source size. Only soft / bounds-expanding effects (e.g. Glow)
/// benefit - rendering at display res preserves their soft falloff. A transform
/// shader that normalizes the fragment position by the dest texture's own pixel
/// dims must return NO (the default), or a smaller dest would zoom it in.
- (BOOL)prefersDisplayResolutionProcessing;
/// Run the plugin's effect on `source` into `dest` (same size as the source
/// frame), encoding into `commandBuffer`. Return YES if a pass was encoded;
/// NO (or unimplemented) → the canvas displays the raw source. The plugin
/// owns its pipeline and uniforms (read from persisted state, no FCP I/O).
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
/// Center of the point handle in overlay points (y-up), given the image's
/// `contentRect` (same space). Return NO for no handle. The canvas draws it
/// with the shared `KKPointOSC` shader so it's pixel-identical to the viewer
/// OSC handle - the plugin only decides where.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
          contentRect:(CGRect)contentRect;
/// Extra point handles (e.g. crop corners/edges) beyond the single
/// `pointHandleCenter`, in overlay points (y-up). Each is drawn with the same
/// shared `KKPointOSC` glyph. Return nil/empty for none.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    extraHandleCentersForContentRect:(CGRect)contentRect;
/// Scale-box handle centres (overlay points, y-up): 0-3 corners BL/BR/TR/TL,
/// 4-7 edges. Empty/nil if the delegate draws no scale box. Lets a guide
/// spotlight a scale handle; the drag itself reuses the generic handle path.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    scaleHandleCentersForContentRect:(CGRect)contentRect;
/// Motion-path overlay (Magic Move). Polyline points (overlay points, y-up) for
/// the red trajectory line through the Position keyposes. Empty for none.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathPolylineForContentRect:(CGRect)contentRect;
/// Anchor dot centres (overlay points, y-up), one per Position keypose.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathAnchorsForContentRect:(CGRect)contentRect;
/// Tangent-handle segments for smooth keyposes, flattened as
/// [anchor0, handleEnd0, anchor1, handleEnd1, ...] (overlay points, y-up). Each
/// pair draws a connector line + a dot at the handle end.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)contentRect;
/// A double-click landed at `point` (overlay points, y-up). Return YES if the
/// delegate handled it (e.g. toggled a keypose smooth/corner); NO lets the
/// canvas treat it as reset-view.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)point
           contentRect:(CGRect)contentRect;
/// Anchor-point pivot square (Magic Move). Centre in overlay points (y-up),
/// drawn with the shared `KKSquarePointOSC` glyph so it matches the viewer.
/// Return NO for none. Dimming for a revealed ghost comes from the renderer's
/// `anchorSquareGhostAlpha`.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    anchorSquareCenter:(out CGPoint *)outCenter
           contentRect:(CGRect)contentRect;
/// A secondary Position handle (the arc glyph) for a plugin whose main point
/// handle is something else (e.g. Glow's radius ring). Centre in overlay points
/// (y-up), drawn with the shared arc glyph so it matches the viewer's Position
/// handle. Return NO for none. Dimming for a revealed ghost comes from the
/// renderer's `positionHandleGhostAlpha`; the active (pressed) emphasis from
/// `positionHandleIsActive`.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    positionHandleCenter:(out CGPoint *)outCenter
             contentRect:(CGRect)contentRect;
/// All rectangular box OSCs to draw - crop, scale, and any future box gizmo -
/// as `KKMiniBox` descriptors (outline + 8 handles + optional readout). The
/// canvas renders each uniformly, so a new box OSC needs no new draw path.
/// nil/empty for none.
- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)contentRect;
/// An elliptical ring OSC to draw (e.g. Glow's radius), centred at `outCenter`
/// with per-axis pixel radii `outRadiusX`/`outRadiusY`, all in overlay points
/// (y-up). Return NO for none. The canvas strokes it in the Metal pass like the
/// box borders; the delegate owns hit-testing + the drag-to-value mapping
/// (handleHitAtPoint / beginHandleDrag / dragHandleToPoint), same as the box.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
        ringCenter:(out CGPoint *)outCenter
           radiusX:(out CGFloat *)outRadiusX
           radiusY:(out CGFloat *)outRadiusY
       contentRect:(CGRect)contentRect;
/// Visual emphasis for the ring stroke, mirroring the viewer ring's idle /
/// hover / active states: 0 = idle, 1 = hovered, 2 = active (being dragged).
/// The canvas brightens + thickens the stroke accordingly. Default 0 when the
/// delegate doesn't implement it. The delegate is responsible for invalidating
/// the canvas (setNeedsDisplay) when its hover state changes.
- (NSInteger)miniViewerRingEmphasis:(KKMiniViewerView *)canvas;
/// Draw alpha for the ring: 1.0 normal, < 1.0 (e.g. 0.3) when it's an Opt-hold
/// revealed ghost of a hidden ring, so the canvas dims it like the other ghost
/// handles. Default 1.0 when the delegate doesn't implement it.
- (CGFloat)miniViewerRingGhostAlpha:(KKMiniViewerView *)canvas;
/// Push externally-edited constant values (slider/field) into the delegate
/// so the preview updates live, without persisting (the host coalesces the
/// real write). `values` is the lane's value array (Float: [v]; Crop:
/// [w,h,x,y]).
- (void)miniViewer:(KKMiniViewerView *)canvas
    applyConstantValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label;
/// Where the point handle's centre *would* be if its value were `value`
/// (same space/contract as -miniViewer:pointHandleCenter:contentRect:).
/// Lets a guide place a "drag to here" target marker. NO if unsupported.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
             forValue:(double)value
          contentRect:(CGRect)contentRect;
/// 2D sibling of the above: where the point handle's centre would be if its
/// value were the multi-component `values` (e.g. Position `[x, y]`). Lets a
/// guide place a "drag to here" target for a spatial point handle. NO if
/// unsupported.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
            forValues:(NSArray<NSNumber *> *)values
          contentRect:(CGRect)contentRect;
/// 3-ring rotation gizmo overlay (KKRotationOSC parity on the mini-viewer).
/// The delegate fills in the centre (overlay points, y-up), pixel radius,
/// and a `KKRotationOSCParams` struct holding the world matrix + ring
/// colours. Returns NO to suppress (default - no rotation handle).
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    rotationOSCCenter:(out CGPoint *)outCenter
             radiusPx:(out CGFloat *)outRadiusPx
               params:(out KKRotationOSCParams *)outParams
          contentRect:(CGRect)contentRect;
/// Hit-test the rotation gizmo at `point` (overlay points, y-up). The
/// delegate records the active ring + press tangent so a subsequent
/// `-rotationDragToPoint:` produces a sensible angle. Returns NO if the
/// point isn't on any ring.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    rotationHitAtPoint:(CGPoint)point
           contentRect:(CGRect)contentRect;
/// The cursor to show while hovering `point` (overlay points), or nil for the
/// default arrow - lets the mini-canvas mirror the viewer's resize / move
/// cursors over its handles. Must be a pure hit-test (no drag-state side
/// effects); the overlay calls it on every mouseMoved.
- (nullable NSCursor *)miniViewer:(KKMiniViewerView *)canvas
                    cursorAtPoint:(CGPoint)point
                      contentRect:(CGRect)contentRect;
- (void)miniViewer:(KKMiniViewerView *)canvas
    rotationBeginDragAtPoint:(CGPoint)point
                 contentRect:(CGRect)contentRect;
- (void)miniViewer:(KKMiniViewerView *)canvas
    rotationDragToPoint:(CGPoint)point
            contentRect:(CGRect)contentRect
              modifiers:(NSEventModifierFlags)modifiers;
- (void)miniViewerEndRotationDrag:(KKMiniViewerView *)canvas;
/// Crop handle centres (overlay points, y-up) the box *would* have if the
/// crop were `values` (`[w,h,x,y]`) - same order/count as
/// -miniViewer:extraHandleCentersForContentRect: (0 = top-left). Lets a
/// guide target a specific crop handle. nil if unsupported.
- (nullable NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
                 cropHandleCentersForValues:(NSArray<NSNumber *> *)values
                                contentRect:(CGRect)contentRect;
/// Scale-box handle centres the box *would* have at the scale percents `values`
/// (`[x%, y%]`) - same order as -miniViewer:scaleHandleCentersForContentRect:.
/// Lets a guide target a scale handle (e.g. the corner at 200%). nil if
/// unsupported.
- (nullable NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
                scaleHandleCentersForValues:(NSArray<NSNumber *> *)values
                                contentRect:(CGRect)contentRect;
/// YES if `point` (overlay points, y-up) grabs a handle.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)point
         contentRect:(CGRect)contentRect;
- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)point
               contentRect:(CGRect)contentRect;
- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)point
          contentRect:(CGRect)contentRect;
/// Modifiers-aware drag, called instead of the plain variant if implemented.
/// Lets the delegate honour cmd-bypass for snap, shift-constrain, etc.
- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)point
          contentRect:(CGRect)contentRect
            modifiers:(NSEventModifierFlags)modifiers;
- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas;
/// Option-click on a handle/ring: toggle that element's visibility instead of
/// starting a drag. Return YES if a handle was hit and handled (the canvas then
/// suppresses the drag). Mirrors the viewer OSC's opt-click-to-hide.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)point
              contentRect:(CGRect)contentRect;
/// While dragging, return the active snap line(s) in normalized
/// content-rect space (0=left/bottom, 1=right/top). `*outX` / `*outY` are
/// only consulted when the corresponding return-element is YES. The canvas
/// overlay strokes a yellow guide through each active axis. Either or both
/// axes may be active.
- (void)miniViewer:(KKMiniViewerView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY;
@end

/// `MTKView` that resolves a cross-process source `IOSurface` - published by
/// the render side to a small JSON descriptor file - and displays it. The
/// render and view sides live in separate XPC processes, so the only shared
/// primitive is the `IOSurface` (looked up here by global ID). Shader
/// compositing, handles and value editing arrive in later phases. See
/// Rounded/PLAN.md "Cross-process transport".
@interface KKMiniViewerView : MTKView

/// Path to the JSON descriptor: `{ ioSurfaceID, width, height, generation }`.
/// Polled for liveness; set by the host.
@property(nonatomic, copy, nullable) NSString *sourceDescriptorPath;

/// Clip aspect (w/h) for the cold-start letterbox before a source resolves.
/// Defaults to 16:9.
@property(nonatomic) CGFloat clipAspect;

@property(nonatomic, weak, nullable) id<KKMiniViewerDelegate> canvasDelegate;

/// Host sink for handle-driven value edits. The delegate computes the new
/// lane values during a drag and calls `-reportHandleValueForLabel:values:`,
/// which invokes this; the host applies the timeline mutation (opt-in +
/// blob write).
@property(nonatomic, copy, nullable) void (^onHandleValue)
    (NSString *laneLabel, NSArray<NSNumber *> *values);

/// Fired once when a handle drag starts / ends, around all the per-tick
/// `onHandleValue` writes - the host opens/closes an undo group so the whole
/// drag coalesces into a single undo entry.
@property(nonatomic, copy, nullable) void (^onHandleDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onHandleDragEnd)(void);

- (void)reportHandleValueForLabel:(NSString *)laneLabel
                           values:(NSArray<NSNumber *> *)values;

/// Tell the overlay to redraw its handles (call after the value changes).
- (void)setHandlesNeedDisplay;

/// Original media pixel size (from the feed descriptor's srcWidth/srcHeight),
/// or zero until the source resolves. Used to show crop in pixel units.
@property(nonatomic, readonly) CGSize sourceMediaSize;

/// Fired when `sourceMediaSize` first resolves (or changes) - lets a host
/// re-render any pixel-scaled UI that depends on it.
@property(nonatomic, copy, nullable) void (^onSourceResolved)(void);

/// Which kind of view-transform gesture the user performed - lets a guide
/// teach pan and zoom as separate steps (the signal alone can't otherwise tell
/// a drag-pan from a wheel-zoom).
typedef NS_ENUM(NSInteger, KKMiniViewerTransformKind) {
  KKMiniViewerTransformKindPan = 0,
  KKMiniViewerTransformKindZoom = 1,
};

/// Fired on any user zoom or pan (wheel/pinch zoom, trackpad pan, drag-pan),
/// with the gesture kind. A guide uses this to advance a "try zooming" or
/// "try panning" step.
@property(nonatomic, copy, nullable) void (^onViewTransformChanged)
    (KKMiniViewerTransformKind kind);

/// Fired when the view is reset to its initial aspect-fit framing (the
/// double-click gesture). A guide uses this to advance a "double-click to
/// reset" step.
@property(nonatomic, copy, nullable) void (^onViewReset)(void);

/// Fired when a double-click was consumed by the delegate (i.e. it returned YES
/// from -miniViewer:doubleClickAtPoint:contentRect: - e.g. Magic Move toggling
/// a keypose's corner/smooth handling) instead of falling through to a view
/// reset. A guide uses this to advance a "double-click to curve a keypose"
/// step.
@property(nonatomic, copy, nullable) void (^onDelegateHandledDoubleClick)(void);

/// Fired when the user single-clicks an INACTIVE filmstrip cell (onion-skin
/// only). The host swaps the popover to the KP at that fraction. Cells in
/// single-slot mode never fire - there's nothing to switch to.
@property(nonatomic, copy, nullable) void (^onFilmstripCellActivated)
    (double fraction);

/// Fired when the user Option-clicks a handle in the canvas to hide it (the
/// in-canvas equivalent of the viewer opt-click-hide). A guide uses this to
/// advance a "hide a control" step. `label` is the toggled handle's label.
@property(nonatomic, copy, nullable) void (^onOptHideHandle)(NSString *label);

/// 0 = Off (single frame at the active KP), 1 = Filmstrip (each KP fans out
/// side-by-side in the pannable canvas), 2 = Onion (all KP frames stacked
/// on the active cell with prev=red / next=blue tinting). Mirrors the value
/// the popover header pill sets; mapped 1:1 to KKMiniViewerRenderMode by
/// the popover so the canvas stays free of the lanes-view import cycle.
@property(nonatomic) NSInteger renderMode;

@end

/// Pan/zoom + point/crop-handle screen geometry. Declared as a category so the
/// primary @implementation isn't expected to provide them (silences
/// -Wincomplete-implementation while keeping the methods public). Implemented
/// in KKMiniViewerView+Interaction.m.
@interface KKMiniViewerView (Interaction)

/// ViewBridge XPC delivers scroll/magnify only as *global* events (never
/// through the responder chain inside a popover). The popover's event
/// monitor calls these with the global event when the pointer is over the
/// canvas: scroll → zoom (mouse) / pan (trackpad), magnify → zoom. Returns
/// YES if the pointer was over the canvas and the event was consumed.
- (BOOL)applyScrollEvent:(NSEvent *)event;
- (BOOL)applyMagnifyEvent:(NSEvent *)event;
/// Is the pointer (screen) currently over the canvas? Non-mutating - used by
/// the popover's local monitor to swallow without double-applying.
- (BOOL)pointerOverCanvas;

/// Reset zoom/pan to the initial aspect-fit framing - the same effect as a
/// double-click on the canvas. Fires `onViewReset`.
- (void)resetView;

/// Screen-space rect of the single point handle's glyph (e.g. the radius
/// dot), or `NSZeroRect` if the delegate exposes no point handle or the view
/// isn't in a window. Lets a guide spotlight the mini-viewer handle the same
/// way the viewer OSC guide spotlights the in-viewer handle.
- (NSRect)pointHandleScreenRect;

/// The cursor the canvas delegate would show at `screenPoint` (its
/// `miniViewer:cursorAtPoint:contentRect:`), or nil. Lets a guide present the
/// real hover cursor while its pass-through overlay captures the mouse (the
/// mini-viewer's own tracking can't fire then).
- (nullable NSCursor *)cursorAtScreenPoint:(NSPoint)screenPoint;

/// Drive the point handle from screen points - the exact path a real overlay
/// drag takes (delegate hit-test/commit + the `onHandleDragBegin/End`
/// coalescing), so a guide can capture the gesture (clicks can't pass through
/// the XPC overlay) and the renderer geometry + persist behave identically to
/// a user drag. Begin must land on the handle for the drag to take.
- (void)beginPointHandleDragAtScreenPoint:(NSPoint)screenPoint;
- (void)dragPointHandleToScreenPoint:(NSPoint)screenPoint;
- (void)endPointHandleDrag;

/// Option-click-hide the handle at `screenPoint` (the in-canvas equivalent of
/// the viewer opt-click-hide), driven from a screen point so a guide's
/// pass-through spotlight handler can invoke it - the XPC overlay swallows the
/// raw click, exactly as the drag methods above. Returns YES if a handle was
/// hit (and toggled).
- (BOOL)optHideHandleAtScreenPoint:(NSPoint)screenPoint;

/// Set Option-peek reveal on/off directly (the same thing the overlay's
/// opt-hover does), driven by a guide whose move events don't reach the overlay
/// natively.
- (void)setGuidePeekActive:(BOOL)active;

/// Screen rect of where the point handle's glyph would sit at `value` - the
/// guide's amber "drag to here" target. `NSZeroRect` if the delegate doesn't
/// implement the value-parameterized hook or the view isn't in a window.
- (NSRect)pointHandleScreenRectForValue:(double)value;

/// 2D sibling: screen rect of where the point handle would sit at the
/// multi-component `values` (e.g. Position `[x, y]`). `NSZeroRect` if the
/// delegate doesn't implement the values hook or the view isn't in a window.
- (NSRect)pointHandleScreenRectForValues:(NSArray<NSNumber *> *)values;

/// Screen rect of crop handle `index` (order/count match
/// -miniViewer:extraHandleCentersForContentRect:; 0 = top-left) for the
/// current crop, or for a hypothetical crop `values` (the guide's "drag
/// here" target). `NSZeroRect` if there's no crop / not in a window.
- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index;
- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index
                        forCropValues:(NSArray<NSNumber *> *)values;

/// Screen rect of scale-box handle `index` (0-3 corners BL/BR/TR/TL, 4-7 edges)
/// for the current scale, or for a hypothetical scale `values` (`[x%, y%]`) -
/// the guide's "drag here" target. `NSZeroRect` if there's no scale box / not
/// in a window. The drag itself reuses the generic point-handle drive (it
/// hit-tests whatever handle the press lands on).
- (NSRect)scaleHandleScreenRectAtIndex:(NSInteger)index;
- (NSRect)scaleHandleScreenRectAtIndex:(NSInteger)index
                        forScaleValues:(NSArray<NSNumber *> *)values;

@end

NS_ASSUME_NONNULL_END
