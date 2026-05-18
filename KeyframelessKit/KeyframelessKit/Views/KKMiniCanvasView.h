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
/// OSC handle — the plugin only decides where.
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

/// `MTKView` that resolves a cross-process source `IOSurface` — published by
/// the render side to a small JSON descriptor file — and displays it. The
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
/// `onHandleValue` writes — the host opens/closes an undo group so the whole
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
/// Is the pointer (screen) currently over the canvas? Non-mutating — used by
/// the popover's local monitor to swallow without double-applying.
- (BOOL)pointerOverCanvas;

/// Original media pixel size (from the feed descriptor's srcWidth/srcHeight),
/// or zero until the source resolves. Used to show crop in pixel units.
@property(nonatomic, readonly) CGSize sourceMediaSize;

/// Fired when `sourceMediaSize` first resolves (or changes) — lets a host
/// re-render any pixel-scaled UI that depends on it.
@property(nonatomic, copy, nullable) void (^onSourceResolved)(void);

@end

NS_ASSUME_NONNULL_END
