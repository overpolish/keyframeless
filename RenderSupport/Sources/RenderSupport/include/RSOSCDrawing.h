/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "RSOSCShaderTypes.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Vertex builders and the draw for viewer on-screen controls. Positions are
// Metal space: surface pixels centred on the surface, Y up. Canvas space (Y
// down, origin top-left) converts through RSOSCMetalPoint. Colours are
// premultiplied fills and straight-alpha strokes, as RSOSCVertex documents.

FOUNDATION_EXPORT simd_float2 RSOSCMetalPoint(CGPoint canvas, CGSize surface);

// A border line as an anti-aliased capsule of the flat colour.
FOUNDATION_EXPORT void RSOSCAppendLine(NSMutableData *vertices, simd_float2 from, simd_float2 to,
                                       float halfWidth, simd_float4 color);
// A capsule glyph centred at `centre` whose long axis follows `axis`.
// halfLength 0 is the point glyph; edge handles use a pill.
FOUNDATION_EXPORT void RSOSCAppendGlyph(NSMutableData *vertices, simd_float2 centre, simd_float2 axis,
                                        float halfLength, float radius, float outline,
                                        simd_float4 fill, simd_float4 stroke);
// A rounded square with an inset outline over a drop shadow that falls
// `shadowOffset` pixels down the screen and blurs over `shadowRadius`.
typedef struct {
  float halfExtent;
  float cornerRadius;
  float outlineWidth;
  float shadowOffset;
  float shadowRadius;
} RSOSCSquareStyle;
FOUNDATION_EXPORT void RSOSCAppendSquare(NSMutableData *vertices, simd_float2 centre, RSOSCSquareStyle style,
                                         simd_float4 fill, simd_float4 stroke);
// The rotation gizmo's quad: `halfExtent` must cover the outermost ring pixels
// plus the anti-aliased edge. `local` runs Y up like OSCRotationGeometry.
FOUNDATION_EXPORT void RSOSCRingQuad(RSOSCVertex quad[6], simd_float2 centre, float halfExtent);

// Clears `texture` and draws the rings (when `ringQuad` is non-NULL) under the
// glyph vertices, so handles stay on top. `bundle` holds the default Metal
// library the OSC shaders were compiled into. Waits for completion, as the
// host reads the surface as soon as the callback returns. NO when the device,
// pipelines or a queue are unavailable; nothing is drawn then.
FOUNDATION_EXPORT BOOL RSOSCDraw(id<MTLDevice> device, id<MTLTexture> texture, MTLPixelFormat format,
                                 NSBundle *bundle, NSData *vertices, const RSOSCVertex *ringQuad,
                                 const RSOSCRingParams *ringParams, NSString *label);
