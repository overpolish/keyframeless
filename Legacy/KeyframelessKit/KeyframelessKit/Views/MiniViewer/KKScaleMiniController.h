/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>

NS_ASSUME_NONNULL_BEGIN

/// Reusable mini-viewer Scale controller: the mini sibling of the viewer-side
/// `KKScaleOSC`. A `KKMiniViewerRenderer` subclass owns one of these and
/// forwards the scale-box hooks (geometry + hit-test + drag) to it, so any
/// plugin with a 2D Scale lane gets the transform box for free.
///
/// Composition, not inheritance: the controller holds a weak back-ref to the
/// renderer and calls its public hooks (`timeline`, `valuesForLabel:`,
/// `commitValues:forLabel:canvas:`, `rotationCenterForContentRect:`,
/// `isConstantLabel:`, `labelVisibleOrRevealing:`, `ghostAlphaForLabel:`,
/// `suppressedHandleLabels`, `handlesHidden`, `nearestHandleIndexToPoint:…`,
/// `templateLaneForLabel:`). The box is concentric with the rotation gizmo
/// (the renderer's `rotationCenterForContentRect:`) and sized through the same
/// `KKScaleGizmo` curve as the viewer, at the content rect's own scale.
///
/// Drag shortcuts mirror `KKScaleOSC`: the grabbed handle tracks the cursor;
/// **Cmd** = fine (0.2×); **Shift** = invert the lane's aspect-link for the
/// drag. Corners drive both axes (geometric-mean uniform when linked); edges
/// drive one axis. The aspect-link is read from the live lane if present, else
/// the plugin template (an untouched default constant has no lane in the
/// renderer's sparse timeline, so a bare read would drop the lock).
@interface KKScaleMiniController : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
                       laneLabel:(NSString *)laneLabel
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, weak, readonly) KKMiniViewerRenderer *renderer;
@property(nonatomic, copy, readonly) NSString *laneLabel;
/// YES while a scale handle is being dragged.
@property(nonatomic, readonly) BOOL isDragging;

/// Whether the box is shown this tick: the Scale lane is a constant in the
/// current popover mode, not hidden / suppressed, and visible (or
/// opt-revealing).
- (BOOL)boxShown;
/// Draw alpha for the box (1.0 normally, dimmed when opt-revealing a ghost).
- (CGFloat)ghostAlpha;
/// "X% x Y%" readout, or nil when the box isn't shown.
- (nullable NSString *)readoutText;

/// The box rect in overlay points. NO if the box isn't shown / the rect is
/// empty.
- (BOOL)boxRect:(out CGRect *)outRect forContentRect:(CGRect)cr;
/// The 8 handle centres (0-3 corners BL/BR/TR/TL, 4-7 edges) for the live
/// value.
- (NSArray<NSValue *> *)handleCentersForContentRect:(CGRect)cr;
/// Handle centres the box *would* have at explicit scale percents - a guide's
/// "drag the corner to 200%" target. nil if the box isn't shown.
- (nullable NSArray<NSValue *> *)handleCentersForValues:
                                     (NSArray<NSNumber *> *)values
                                            contentRect:(CGRect)cr;

/// YES if `p` lands on a handle; sets `*outIdx` to its index (0-7).
- (BOOL)handleHitAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                outIndex:(nullable NSInteger *)outIdx;
/// Try to grab a handle at `p`. YES if claimed (sets `isDragging`); the host
/// should not fall through to its own controls.
- (BOOL)beginDragAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Live-update the grabbed handle. Caller gates on `isDragging`.
- (void)applyDragToPoint:(CGPoint)p
             contentRect:(CGRect)cr
               modifiers:(NSEventModifierFlags)modifiers
                  canvas:(KKMiniViewerView *)canvas;
/// End the drag (clears `isDragging`).
- (void)endDrag;

@end

NS_ASSUME_NONNULL_END
