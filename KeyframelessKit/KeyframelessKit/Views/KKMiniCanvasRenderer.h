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

#pragma mark - Subclass effect + point handle (override)

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
/// Current values for `label` (subclass default when absent/short).
- (NSArray<NSNumber *> *)valuesForLabel:(NSString *)label;
/// The crop box rect for the current crop values within `contentRect`.
- (CGRect)cropRectForContentRect:(CGRect)contentRect;
/// Optimistically set the timeline + report the edit + redraw. Used by both
/// the crop editor path and subclass point drags.
- (void)commitValues:(NSArray<NSNumber *> *)values
            forLabel:(NSString *)label
              canvas:(KKMiniCanvasView *)canvas;

@end

NS_ASSUME_NONNULL_END
