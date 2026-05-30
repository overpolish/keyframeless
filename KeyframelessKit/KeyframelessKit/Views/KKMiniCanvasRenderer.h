/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniCanvasView.h>

@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic base for a mini-canvas delegate.
///
/// Owns everything that isn't tied to a specific effect: the persisted
/// `timeline`, the constant-vs-animatable gate, reading a lane's value (with
/// a subclass default), the generic "set this constant lane, preserving
/// animatable status + bounds" timeline builder, the whole crop handle/box
/// interaction (via `KKMiniCanvasCropEditor`), and the `KKMiniCanvasDelegate`
/// dispatch that routes the canvas's handle callbacks to the crop editor or
/// the subclass's point handle.
///
/// A plugin subclass supplies only effect-specific pieces (see the hooks
/// below): the actual effect render, the point-handle (e.g. radius)
/// geometry, and the label/value-type/default vocabulary.
@interface KKMiniCanvasRenderer : NSObject <KKMiniCanvasDelegate>

/// The persisted timeline (constants live here as disabled single-keypose
/// lanes). The host keeps this in sync.
@property(nonatomic, copy, nullable) KKTimeline *timeline;

/// Boundary-editing mode (Basic step 27): the popover edits an animatable
/// lane's keypose at a specific clip time rather than a constant.
/// `editFraction` is that time (default 0 = constants). When YES:
/// `valuesForLabel:` evaluates at `editFraction`, handles stay active for
/// animatable lanes, and optimistic writes replace the keypose nearest
/// `editFraction` (preserving structure) instead of a t=0 single keypose.
@property(nonatomic) BOOL boundaryEditing;
@property(nonatomic) double editFraction;
/// Number of slots the canvas is currently iterating. KKMiniCanvasView
/// sets this before its per-slot processSourceTexture loop. Subclasses
/// can use it to differentiate "single-slot, source is the pre-rendered
/// dest texture published by the plugin → blit straight through" from
/// "multi-slot, each source is a raw frame at editFraction → run the
/// plugin's shader locally". Defaults to 1.
@property(nonatomic) NSUInteger currentSlotCount;
/// Lane labels whose handle/box must NOT be drawn or hit - a property
/// excluded from the boundary's phase has no keypose there, so its OSC
/// would be meaningless. Set by the boundary popover; cleared on close.
@property(nonatomic, copy, nullable)
    NSArray<NSString *> *suppressedHandleLabels;

#pragma mark - Subclass vocabulary (override)

/// Lane label for the crop box, or nil if this plugin has no crop. Default
/// `@"Crop"`.
@property(nonatomic, readonly, nullable) NSString *cropLabel;
/// Lane label for the single point handle (e.g. `@"Radius"`), or nil.
/// Default nil.
@property(nonatomic, readonly, nullable) NSString *pointLabel;
/// Value type for a lane the renderer writes. Default `KKLaneValueTypeFloat`.
- (NSInteger)valueTypeForLabel:(NSString *)label;
/// Default value array for a label when the timeline has no (or a short)
/// lane for it. Default `@[ @0 ]`.
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label;

/// Glyph style for the renderer's point handle (the one returned by
/// `pointHandleCenter:forContentRect:`). Mini-canvas draws the same glyph
/// the viewer-side OSC uses, so plugins backed by `KKArcOSC` (e.g. Magic
/// Move's Position) can match it here.
typedef NS_ENUM(NSInteger, KKMiniHandleStyle) {
  KKMiniHandleStylePoint = 0, ///< Default: solid dot (matches KKPointOSC).
  KKMiniHandleStyleArc = 1,   ///< Ring (matches KKArcOSC).
};

#pragma mark - Subclass effect + point handle (override)

/// Override to switch the main point handle's glyph. Default Point.
/// Extra handles (crop corners) always render as Point.
- (KKMiniHandleStyle)pointHandleStyle;

/// YES while the main point handle is currently being dragged. Lets the
/// canvas swap glyph params (e.g. ArcOSC's active radius + plus indicator)
/// on press. Default reflects the renderer's own `_pointGrabbed` state.
- (BOOL)pointHandleIsActive;

/// Render the effect from `source` into `dest`. Default returns NO (raw
/// passthrough). Read values via `-valuesForLabel:`.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb;
/// Point handle centre (overlay points), or NO if none. Default NO.
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
           forContentRect:(CGRect)contentRect;
/// Point handle centre if its value were `value` (for a guide's amber
/// "drag to here" target marker). Default NO.
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)contentRect;
/// YES if `p` grabs the point handle. Default NO.
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)contentRect;
/// Apply a point-handle drag: compute the new value, then call
/// `-commitValues:forLabel:canvas:`. Default no-op.
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)contentRect
                       canvas:(KKMiniCanvasView *)canvas;

#pragma mark - Provided to subclasses

/// Constant == no lane yet, or a lane that isn't enabled (animatable).
- (BOOL)isConstantLabel:(NSString *)label;
/// Current values for `label` (subclass default when absent/short). Respects
/// any live override pushed via `-setLiveValues:forLabel:` (cleared on drag
/// end) so the drag's in-flight value shows immediately without round-tripping
/// through FxPlug param writes.
- (NSArray<NSNumber *> *)valuesForLabel:(NSString *)label;

/// Push the in-flight drag value for `label` as a live override at
/// `fraction`. The next `valuesForLabel:` returns these instead of the
/// timeline-evaluated values WHEN the current `editFraction` matches
/// `fraction` (so filmstrip/onion neighbour cells keep their own values).
/// Pass nil values to clear. Caller is responsible for triggering a redraw.
- (void)setLiveValues:(nullable NSArray<NSNumber *> *)values
             forLabel:(NSString *)label
           atFraction:(double)fraction;
/// Clear all live overrides (drag end).
- (void)clearLiveValues;
/// The crop box rect for the current crop values within `contentRect`.
- (CGRect)cropRectForContentRect:(CGRect)contentRect;
/// Optimistically set the timeline + report the edit + redraw. Used by both
/// the crop editor path and subclass point drags.
- (void)commitValues:(NSArray<NSNumber *> *)values
            forLabel:(NSString *)label
              canvas:(KKMiniCanvasView *)canvas;

@end

NS_ASSUME_NONNULL_END
