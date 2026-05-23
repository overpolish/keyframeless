/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKMiniCanvasView;

/// Plugin-supplied interaction delegate. Hooks are declared now and wired in
/// later phases (handle drawing, hit-testing, drag deltas reported as value
/// mutations). Points are clip-normalized: (0,0) top-left, (1,1) bottom-right.
@protocol KKMiniCanvasDelegate <NSObject>
@optional
/// Run the plugin's effect on `source` into `dest` (same size as the source
/// frame), encoding into `commandBuffer`. Return YES if a pass was encoded;
/// NO (or unimplemented) → the canvas displays the raw source. The plugin
/// owns its pipeline and uniforms (read from persisted state, no FCP I/O).
- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
/// Center of the point handle in overlay points (y-up), given the image's
/// `contentRect` (same space). Return NO for no handle. The canvas draws it
/// with the shared `KKPointOSC` shader so it's pixel-identical to the viewer
/// OSC handle - the plugin only decides where.
- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
          contentRect:(CGRect)contentRect;
/// Extra point handles (e.g. crop corners/edges) beyond the single
/// `pointHandleCenter`, in overlay points (y-up). Each is drawn with the same
/// shared `KKPointOSC` glyph. Return nil/empty for none.
- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    extraHandleCentersForContentRect:(CGRect)contentRect;
/// Optional rectangle outline (the crop box) stroked over the image, in
/// overlay points (y-up). Return NO for none.
- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
        borderRect:(out CGRect *)outRect
    forContentRect:(CGRect)contentRect;
/// Push externally-edited constant values (slider/field) into the delegate
/// so the preview updates live, without persisting (the host coalesces the
/// real write). `values` is the lane's value array (Float: [v]; Crop:
/// [w,h,x,y]).
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    applyConstantValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label;
/// Where the point handle's centre *would* be if its value were `value`
/// (same space/contract as -miniCanvas:pointHandleCenter:contentRect:).
/// Lets a guide place a "drag to here" target marker. NO if unsupported.
- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
             forValue:(double)value
          contentRect:(CGRect)contentRect;
/// Crop handle centres (overlay points, y-up) the box *would* have if the
/// crop were `values` (`[w,h,x,y]`) - same order/count as
/// -miniCanvas:extraHandleCentersForContentRect: (0 = top-left). Lets a
/// guide target a specific crop handle. nil if unsupported.
- (nullable NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
                 cropHandleCentersForValues:(NSArray<NSNumber *> *)values
                                contentRect:(CGRect)contentRect;
/// YES if `point` (overlay points, y-up) grabs a handle.
- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    handleHitAtPoint:(CGPoint)point
         contentRect:(CGRect)contentRect;
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    beginHandleDragAtPoint:(CGPoint)point
               contentRect:(CGRect)contentRect;
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    dragHandleToPoint:(CGPoint)point
          contentRect:(CGRect)contentRect;
- (void)miniCanvasEndHandleDrag:(KKMiniCanvasView *)canvas;
@end

/// `MTKView` that resolves a cross-process source `IOSurface` - published by
/// the render side to a small JSON descriptor file - and displays it. The
/// render and view sides live in separate XPC processes, so the only shared
/// primitive is the `IOSurface` (looked up here by global ID). Shader
/// compositing, handles and value editing arrive in later phases. See
/// Rounded/PLAN.md "Cross-process transport".
@interface KKMiniCanvasView : MTKView

/// Path to the JSON descriptor: `{ ioSurfaceID, width, height, generation }`.
/// Polled for liveness; set by the host.
@property(nonatomic, copy, nullable) NSString *sourceDescriptorPath;

/// Clip aspect (w/h) for the cold-start letterbox before a source resolves.
/// Defaults to 16:9.
@property(nonatomic) CGFloat clipAspect;

@property(nonatomic, weak, nullable) id<KKMiniCanvasDelegate> canvasDelegate;

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

/// Original media pixel size (from the feed descriptor's srcWidth/srcHeight),
/// or zero until the source resolves. Used to show crop in pixel units.
@property(nonatomic, readonly) CGSize sourceMediaSize;

/// Fired when `sourceMediaSize` first resolves (or changes) - lets a host
/// re-render any pixel-scaled UI that depends on it.
@property(nonatomic, copy, nullable) void (^onSourceResolved)(void);

/// Fired on any user zoom or pan (wheel/pinch zoom, trackpad pan, drag-pan).
/// A guide uses this to advance a "try zooming or panning" step.
@property(nonatomic, copy, nullable) void (^onViewTransformChanged)(void);

/// Fired when the view is reset to its initial aspect-fit framing (the
/// double-click gesture). A guide uses this to advance a "double-click to
/// reset" step.
@property(nonatomic, copy, nullable) void (^onViewReset)(void);

/// Fired when the user single-clicks an INACTIVE filmstrip cell (onion-skin
/// only). The host swaps the popover to the KP at that fraction. Cells in
/// single-slot mode never fire - there's nothing to switch to.
@property(nonatomic, copy, nullable) void (^onFilmstripCellActivated)
    (double fraction);

/// 0 = Off (single frame at the active KP), 1 = Filmstrip (each KP fans out
/// side-by-side in the pannable canvas), 2 = Onion (all KP frames stacked
/// on the active cell with prev=red / next=blue tinting). Mirrors the value
/// the popover header pill sets; mapped 1:1 to KKMiniCanvasRenderMode by
/// the popover so the canvas stays free of the lanes-view import cycle.
@property(nonatomic) NSInteger renderMode;

/// Reset zoom/pan to the initial aspect-fit framing - the same effect as a
/// double-click on the canvas. Fires `onViewReset`.
- (void)resetView;

/// Screen-space rect of the single point handle's glyph (e.g. the radius
/// dot), or `NSZeroRect` if the delegate exposes no point handle or the view
/// isn't in a window. Lets a guide spotlight the mini-canvas handle the same
/// way the viewer OSC guide spotlights the in-viewer handle.
- (NSRect)pointHandleScreenRect;

/// Drive the point handle from screen points - the exact path a real overlay
/// drag takes (delegate hit-test/commit + the `onHandleDragBegin/End`
/// coalescing), so a guide can capture the gesture (clicks can't pass through
/// the XPC overlay) and the renderer geometry + persist behave identically to
/// a user drag. Begin must land on the handle for the drag to take.
- (void)beginPointHandleDragAtScreenPoint:(NSPoint)screenPoint;
- (void)dragPointHandleToScreenPoint:(NSPoint)screenPoint;
- (void)endPointHandleDrag;

/// Screen rect of where the point handle's glyph would sit at `value` - the
/// guide's amber "drag to here" target. `NSZeroRect` if the delegate doesn't
/// implement the value-parameterized hook or the view isn't in a window.
- (NSRect)pointHandleScreenRectForValue:(double)value;

/// Screen rect of crop handle `index` (order/count match
/// -miniCanvas:extraHandleCentersForContentRect:; 0 = top-left) for the
/// current crop, or for a hypothetical crop `values` (the guide's "drag
/// here" target). `NSZeroRect` if there's no crop / not in a window.
- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index;
- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index
                        forCropValues:(NSArray<NSNumber *> *)values;

@end

NS_ASSUME_NONNULL_END
