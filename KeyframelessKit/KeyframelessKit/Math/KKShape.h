/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, KKShapeKind) {
  KKShapeKindRect = 0,
  KKShapeKindEllipse = 1,
  KKShapeKindLine = 2,
  KKShapeKindPolygon = 3,
  KKShapeKindBezier = 4,
};

@interface KKShape : NSObject <NSCopying>
@property(nonatomic, readonly) KKShapeKind kind;

/// Per-kind binary payload (no kind byte). Packed as documented per subclass.
/// Returns nil for kinds that don't (yet) participate in disk/wire format.
- (nullable NSData *)serializedPayload;

/// Reverse of `serializedPayload`. Returns nil if `kind` is unsupported, or
/// `available` is smaller than the payload size for that kind.
+ (nullable instancetype)shapeWithKind:(KKShapeKind)kind
                                 bytes:(const void *)bytes
                             available:(size_t)available;

/// Payload byte count for a given kind. 0 means "unsupported / no on-disk
/// representation" (groups, polygon, bezier).
+ (size_t)payloadByteCountForKind:(KKShapeKind)kind;

/// Linearly interpolate between two shapes of the same kind. Returns nil if
/// `a` and `b` differ in kind, either is nil, or the kind isn't lerpable
/// (currently rect/ellipse/line).
+ (nullable KKShape *)lerpFrom:(KKShape *)a to:(KKShape *)b t:(float)t;
@end

@interface KKRectShape : KKShape
@property(nonatomic, assign) simd_float2 min;
@property(nonatomic, assign) simd_float2 max;
@property(nonatomic, assign) float radiusTL;
@property(nonatomic, assign) float radiusTR;
@property(nonatomic, assign) float radiusBR;
@property(nonatomic, assign) float radiusBL;

/// Per-corner radius fractions packed as (TL, TR, BR, BL). Setter clamps each
/// component to [0, 1].
@property(nonatomic, assign) simd_float4 radii;

/// Materialize the rect (with rounded corners scaled to the given canvas
/// pixel dims) into `path`'s point bag. Replaces the rect-rebuild hack
/// that lived inline in the renderer.
- (void)applyToPath:(KKBezierPath *)path
        canvasWidth:(float)canvasW
       canvasHeight:(float)canvasH;
@end

@interface KKEllipseShape : KKShape
@property(nonatomic, assign) simd_float2 min;
@property(nonatomic, assign) simd_float2 max;

/// Materialize the ellipse as 4 cubic-bezier points into `path`. Canvas
/// dims are ignored — ellipse geometry is canvas-independent.
- (void)applyToPath:(KKBezierPath *)path
        canvasWidth:(float)canvasW
       canvasHeight:(float)canvasH;
@end

@interface KKLineShape : KKShape
@property(nonatomic, assign) simd_float2 start;
@property(nonatomic, assign) simd_float2 end;

/// Materialize the line as 2 linear points into `path`. Canvas dims ignored.
- (void)applyToPath:(KKBezierPath *)path
        canvasWidth:(float)canvasW
       canvasHeight:(float)canvasH;
@end

@interface KKPolygonShape : KKShape
@property(nonatomic, copy) NSData *pointsData;
@property(nonatomic, assign) BOOL closed;
@end

@interface KKBezierShape : KKShape
@property(nonatomic, copy) NSData *pointsData;
@property(nonatomic, assign) BOOL closed;
@end

NS_ASSUME_NONNULL_END
