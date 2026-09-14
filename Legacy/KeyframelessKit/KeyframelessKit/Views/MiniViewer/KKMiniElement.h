/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKOSCShaderTypes.h>

NS_ASSUME_NONNULL_BEGIN

/// What a mini-viewer OSC element IS - one case per drawable primitive the
/// canvas knows how to encode. Everything the mini draws (and, in later
/// phases, hit-tests) is one of these; a new OSC kind means a new descriptor,
/// never a new delegate method pair.
typedef NS_ENUM(NSInteger, KKMiniElementKind) {
  /// One handle glyph at `center`, drawn per `style` (dot / arc / ring-widget
  /// / square). The primary point handle, extra point handles, fixed-glyph
  /// handles, the anchor square and the secondary Position arc all collapse
  /// onto this case.
  KKMiniElementKindGlyph = 0,
  /// A rectangular box OSC: border + up to 8 handle glyphs + optional
  /// readout (crop, scale, any future box gizmo).
  KKMiniElementKindBox = 1,
  /// An elliptical ring stroke with viewer-parity idle/hover/active styling
  /// (radius rings, `osc=ring` scalars).
  KKMiniElementKindRing = 2,
  /// A 3-ring rotation gizmo (KKRotationOSC parity).
  KKMiniElementKindRotation = 3,
  /// A motion-path overlay: trajectory polyline + tangent handle segments +
  /// keypose anchor dots.
  KKMiniElementKindMotionPath = 4,
};

/// ONE typed descriptor for a mini-viewer OSC element. The delegate returns an
/// array of these (`miniViewer:elementsForContentRect:`) and the canvas draws
/// them through a single generic loop - replacing the per-kind delegate-method
/// families (pointHandleCenter / anchorSquareCenter / ringCenter /
/// extra*Bundles...) and their per-kind ghost-alpha hooks: the ghost dim is
/// just `alpha` on the element. All geometry is in overlay points (y-up).
@interface KKMiniElement : NSObject

@property(nonatomic) KKMiniElementKind kind;

/// The element's identity for visibility / hit routing: usually the lane key
/// it edits (or an element key like @"Rotation.X"). nil = anonymous drawable.
@property(nonatomic, copy, nullable) NSString *label;

/// Draw alpha: 1.0 normal, ~0.3 when the element is an Opt-hold revealed
/// ghost. The one ghost-dim channel (replaces the per-kind GhostAlpha hooks).
@property(nonatomic) CGFloat alpha;

/// Pressed emphasis for an arc glyph (the active Position-handle look).
@property(nonatomic) BOOL active;

/// Ring stroke emphasis: 0 idle / 1 hover / 2 active.
@property(nonatomic) NSInteger emphasis;

// --- Glyph ---------------------------------------------------------------
@property(nonatomic) CGPoint center;
/// KKMiniHandleStyle (declared in KKMiniViewerRenderer.h). Style None = the
/// element exists for anchoring/hit purposes but draws no default glyph.
@property(nonatomic) NSInteger style;
/// Dot-glyph size multiplier (matches the renderer's pointHandleSizeScale).
@property(nonatomic) CGFloat sizeScale;
/// Dot glyphs: white fill (viewer KKPointOSC parity) instead of the accent.
@property(nonatomic) BOOL whiteFill;

// --- Box -----------------------------------------------------------------
@property(nonatomic) CGRect rect;
@property(nonatomic, copy, nullable) NSArray<NSValue *> *handleCenters;
@property(nonatomic, copy, nullable) NSString *readout;

// --- Ring ----------------------------------------------------------------
@property(nonatomic) CGFloat radiusX;
@property(nonatomic) CGFloat radiusY;

// --- Rotation ------------------------------------------------------------
@property(nonatomic) CGFloat radiusPx;
@property(nonatomic) KKRotationOSCParams rotationParams;

// --- Motion path ---------------------------------------------------------
@property(nonatomic, copy, nullable) NSArray<NSValue *> *polyline;
/// Flattened tangent segments [anchor0, handleEnd0, anchor1, handleEnd1, ...].
@property(nonatomic, copy, nullable) NSArray<NSValue *> *handleSegments;
@property(nonatomic, copy, nullable) NSArray<NSValue *> *anchors;

+ (instancetype)glyphAt:(CGPoint)center
                  style:(NSInteger)style
                  alpha:(CGFloat)alpha;
+ (instancetype)boxWithRect:(CGRect)rect
              handleCenters:(nullable NSArray<NSValue *> *)handleCenters
                    readout:(nullable NSString *)readout
                      alpha:(CGFloat)alpha;
+ (instancetype)ringAt:(CGPoint)center
               radiusX:(CGFloat)radiusX
               radiusY:(CGFloat)radiusY
              emphasis:(NSInteger)emphasis
                 alpha:(CGFloat)alpha;
+ (instancetype)rotationAt:(CGPoint)center
                  radiusPx:(CGFloat)radiusPx
                    params:(KKRotationOSCParams)params;
+ (instancetype)motionPathWithPolyline:(nullable NSArray<NSValue *> *)polyline
                        handleSegments:
                            (nullable NSArray<NSValue *> *)handleSegments
                               anchors:(nullable NSArray<NSValue *> *)anchors
                                 alpha:(CGFloat)alpha;

@end

NS_ASSUME_NONNULL_END
