/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerView.h>

@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic base for a mini-viewer delegate.
///
/// Owns everything that isn't tied to a specific effect: the persisted
/// `timeline`, the constant-vs-animatable gate, reading a lane's value (with
/// a subclass default), the generic "set this constant lane, preserving
/// animatable status + bounds" timeline builder, the whole crop handle/box
/// interaction (via `KKMiniViewerCropEditor`), and the `KKMiniViewerDelegate`
/// dispatch that routes the canvas's handle callbacks to the crop editor or
/// the subclass's point handle.
///
/// A plugin subclass supplies only effect-specific pieces (see the hooks
/// below): the actual effect render, the point-handle (e.g. radius)
/// geometry, and the label/value-type/default vocabulary.
@interface KKMiniViewerRenderer : NSObject <KKMiniViewerDelegate>

/// The persisted timeline (constants live here as disabled single-keypose
/// lanes). The host keeps this in sync.
@property(nonatomic, copy, nullable) KKTimeline *timeline;
/// Weak ref to the canvas this renderer is currently delegating for. Set by
/// the base on every delegate call, so subclasses can read the canvas's
/// frame size (e.g. to scale overlay glyphs with popover size) without
/// threading `canvas` through every subclass hook.
@property(nonatomic, weak, nullable) KKMiniViewerView *canvas;

/// Boundary-editing mode (Basic step 27): the popover edits an animatable
/// lane's keypose at a specific clip time rather than a constant.
/// `editFraction` is that time (default 0 = constants). When YES:
/// `valuesForLabel:` evaluates at `editFraction`, handles stay active for
/// animatable lanes, and optimistic writes replace the keypose nearest
/// `editFraction` (preserving structure) instead of a t=0 single keypose.
@property(nonatomic) BOOL boundaryEditing;
@property(nonatomic) double editFraction;
/// Number of slots the canvas is currently iterating. KKMiniViewerView
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

/// Master "hide all on-screen controls" gate, mirroring the viewer OSC's
/// visibility tick. When YES, no point / rotation / crop handle is drawn or
/// hit-tested in the mini-viewer, regardless of `suppressedHandleLabels`.
/// Set by the host when the user toggles the inspector's OSC visibility.
@property(nonatomic) BOOL handlesHidden;

/// Per-element OSC visibility from the settings popover's pills: lane labels
/// the user has individually hidden (e.g. @"Position"). Distinct from
/// `suppressedHandleLabels` (which the boundary popover owns per-phase) so the
/// two never clobber each other; a handle is drawn only when its label is in
/// neither set and `handlesHidden` is NO.
@property(nonatomic, copy, nullable) NSSet<NSString *> *hiddenHandleLabels;

/// Opt-click on a mini-viewer handle/ring toggles that element's visibility
/// (mirrors the viewer OSC's opt-click-to-hide). The host wires this to the
/// same persistence the inspector pills use; the label is a lane label or a
/// rotation-ring key (@"Rotation.X"). nil = opt-click does nothing (default,
/// so other plugins are unaffected).
@property(nonatomic, copy, nullable) void (^onHandleVisibilityToggled)
    (NSString *label);

/// Opt-hold "reveal" mode: user-hidden handles/rings draw as dimmed ghosts and
/// become hit-testable so an opt-click re-shows them. Set by the mini-viewer
/// view from the Option modifier. Only effective when
/// `onHandleVisibilityToggled` is wired (so plugins that don't support
/// hide-toggling are unaffected).
@property(nonatomic) BOOL revealHidden;

/// Alpha to draw the point handle at: 1.0 normal, 0.3 when it's a revealed
/// ghost. Read by the mini-viewer view when encoding the arc glyph.
- (CGFloat)pointHandleGhostAlpha;

/// Alpha to draw the crop OSC at (border + corner handles): 1.0 normal, 0.3
/// when it's a revealed ghost. Read by the mini-viewer view.
- (CGFloat)cropGhostAlpha;
/// Alpha to draw the scale box at (border + handles): 1.0 normal, 0.3 when it's
/// a revealed ghost. Default 1.0; a plugin with a scale box overrides it.
- (CGFloat)scaleGhostAlpha;
/// Alpha to draw the anchor pivot square at: 1.0 normal, 0.3 when it's a
/// revealed ghost. Default 1.0; a plugin with an anchor square overrides it.
- (CGFloat)anchorSquareGhostAlpha;
/// YES when `label` (an OSC element key) is visible or being revealed as a
/// ghost (opt-hold). Lets a subclass gate motion-path drawing / hit-testing the
/// same way the built-in handles gate on their own labels.
- (BOOL)labelVisibleOrRevealing:(NSString *)label;
/// 0.3 when `label` is user-hidden (revealed-ghost dimming), else 1.0.
- (CGFloat)ghostAlphaForLabel:(NSString *)label;
/// The Opt-hover visibility cursor for `label`, or nil if none applies: `eye`
/// (show) over a revealed ghost, `eye.slash` (hide) over a visible handle -
/// only when Opt is held and the master is on (peek mode returns nil).
/// Subclasses call this in `cursorAtPoint:` when the pointer is over `label`'s
/// handle, e.g. `return [self kkVisibilityCursorForLabel:lbl] ?:
/// KKPointMoveCursor();`
- (nullable NSCursor *)kkVisibilityCursorForLabel:(NSString *)label;
/// Draw alpha for the motion-path overlay (line + anchors + handles). Default
/// 1.0; a subclass with a hideable path returns a ghost alpha while revealing.
- (CGFloat)motionPathGhostAlpha;

#pragma mark - Subclass vocabulary (override)

/// Lane label for the crop box, or nil if this plugin has no crop. Default
/// `@"Crop"`.
@property(nonatomic, readonly, nullable) NSString *cropLabel;
/// Lane label for the single point handle (e.g. `@"Radius"`), or nil.
/// Default nil.
@property(nonatomic, readonly, nullable) NSString *pointLabel;
/// Lane label for the rotation gizmo (e.g. `@"Rotation"`), or nil if this
/// plugin has no 3-ring rotation OSC. Default nil. When non-nil, the
/// subclass must also override the rotation hooks below.
@property(nonatomic, readonly, nullable) NSString *rotationLabel;

/// Persist a full mutated timeline. Mini-viewer motion-path edits (dragging an
/// arbitrary keypose anchor or a tangent handle) rewrite the whole blob, unlike
/// `commitValues:forLabel:` which writes a single label's value at
/// `editFraction`. The host wires this to its timeline-blob writer.
@property(nonatomic, copy, nullable) void (^onTimelinePersist)
    (KKTimeline *timeline);

/// Value type for a lane the renderer writes. Default `KKLaneValueTypeFloat`.
- (NSInteger)valueTypeForLabel:(NSString *)label;
/// Default value array for a label when the timeline has no (or a short)
/// lane for it. Default `@[ @0 ]`.
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label;

/// Glyph style for the renderer's point handle (the one returned by
/// `pointHandleCenter:forContentRect:`). Mini-viewer draws the same glyph
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

/// Size multiplier for the point-style handle glyph (the main point handle and
/// any crop-corner handles), relative to the standard mini-viewer dot. Default
/// 1.0. Lets a plugin match a specific reference dot - e.g. Rounded sets this
/// so its radius + crop handles are the same size as Magic Move's path-anchor
/// dots.
- (CGFloat)pointHandleSizeScale;

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
/// 2D sibling: point handle centre if its value were the multi-component
/// `values` (e.g. Position `[x, y]`), for a guide's "drag to here" target.
/// Default NO.
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)contentRect;
/// YES if `p` grabs the point handle. Default NO.
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)contentRect;
/// Apply a point-handle drag: compute the new value, then call
/// `-commitValues:forLabel:canvas:`. Default no-op.
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)contentRect
                       canvas:(KKMiniViewerView *)canvas;

/// Index of the handle center nearest to `p` that lies within `tolerance`
/// (point units), or NSNotFound if none. Shared hit-test for square/point
/// drag handles - pass a single center (count 1) for a yes/no test. Strictly
/// nearer-than-tolerance, first-wins on ties.
- (NSInteger)nearestHandleIndexToPoint:(CGPoint)p
                               centers:(const CGPoint *)centers
                                 count:(NSInteger)count
                             tolerance:(CGFloat)tolerance;

/// === 3-ring rotation gizmo ===
/// To opt in: override `rotationLabel`. The base provides the full state
/// machine (hit-test, press snapshot, tangent capture, compose × axis(dAngle)
/// → decompose-near, commit) so a typical plugin overrides ONLY the small
/// accessors below. The four `rotation…` hooks lower down
/// (`rotationOSCCenter:`, `rotationHitTestAtPoint:`,
/// `rotationBeginDragAtPoint:`, `applyRotationDragToPoint:…`) ship with
/// sensible defaults driven by these accessors and only need overriding for
/// non-standard behaviour.

/// Current rotation values in degrees (length 3, x/y/z). Default reads
/// `-valuesForLabel:[self rotationLabel]`.
- (NSArray<NSNumber *> *)rotationEulerDegrees;
/// Where the sphere sits in overlay points (y-up). Default = centre of
/// `contentRect`. Override to lock it to another handle (e.g. MagicMove
/// uses the Position handle so the rings move with the translated image).
- (CGPoint)rotationCenterForContentRect:(CGRect)contentRect;
/// Per-axis ring colours, [X, Y, Z]. Default = red / green / blue.
- (NSArray<NSColor *> *)rotationRingColors;
/// Per-axis drag direction sign (simd_double3). Default = `{+1, -1, +1}`,
/// tuned to feel natural with the viewer convention.
- (simd_double3)rotationAxisSigns;
/// On-screen ring radius in points. Default scales with the canvas's frame
/// height (28pt at the 230pt baseline; see project_miniviewer_osc_port).
- (CGFloat)rotationRadiusPxForCanvas:(nullable KKMiniViewerView *)canvas;

/// 3-ring rotation gizmo (parallel to the point handle path). Default fills
/// out a `KKRotationOSCParams` from the accessors above. Override only if
/// the standard accessors aren't enough.
- (BOOL)rotationOSCCenter:(out CGPoint *)outCenter
                 radiusPx:(out CGFloat *)outRadiusPx
                   params:(out KKRotationOSCParams *)outParams
           forContentRect:(CGRect)contentRect;
/// YES if `p` lands on one of the rotation rings, recording the active ring
/// + press tangent for the subsequent drag. Default uses the accessors.
- (BOOL)rotationHitTestAtPoint:(CGPoint)p contentRect:(CGRect)contentRect;
/// Called once on drag begin AFTER `rotationHitTestAtPoint:` returned YES.
/// Default snapshots press values from `rotationEulerDegrees`.
- (void)rotationBeginDragAtPoint:(CGPoint)p contentRect:(CGRect)contentRect;
/// Apply a rotation-ring drag: compose press matrix * axis(dAngle),
/// decompose-near, then `-commitValues:forLabel:canvas:`. Default does the
/// full pipeline including Cmd-15° snap.
- (void)applyRotationDragToPoint:(CGPoint)p
                     contentRect:(CGRect)contentRect
                          canvas:(KKMiniViewerView *)canvas
                       modifiers:(NSEventModifierFlags)modifiers;
/// YES while a rotation ring is currently being dragged. Default reflects
/// the renderer's own `_rotationGrabbed` state.
- (BOOL)rotationIsActive;

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
              canvas:(KKMiniViewerView *)canvas;

@end

NS_ASSUME_NONNULL_END
