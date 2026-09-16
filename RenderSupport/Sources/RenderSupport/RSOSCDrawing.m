/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "RSOSCDrawing.h"
#import "RenderSupport.h"

simd_float2 RSOSCMetalPoint(CGPoint canvas, CGSize surface) {
  return (simd_float2){(float)canvas.x - (float)surface.width / 2, (float)surface.height / 2 - (float)canvas.y};
}

// Two triangles over a quad whose `local` frame is `u` along and `n` across,
// padded by 1.5 pixels so the fwidth-based edge has room to fall off.
static void RSOSCAppendQuad(NSMutableData *data, RSOSCVertex prototype, simd_float2 centre, simd_float2 u,
                            simd_float2 n, float padX, float padY, BOOL shadeByOffset) {
  const float sx[4] = {-padX, padX, -padX, padX}, sy[4] = {-padY, -padY, padY, padY};
  RSOSCVertex quad[4];
  for (int i = 0; i < 4; ++i) {
    simd_float2 offset = u * sx[i] + n * sy[i];
    quad[i] = prototype;
    quad[i].position = centre + offset;
    quad[i].local = (simd_float2){sx[i], sy[i]};
    if (shadeByOffset) quad[i].shade = offset.y;
  }
  const RSOSCVertex triangles[6] = {quad[0], quad[1], quad[2], quad[1], quad[3], quad[2]};
  [data appendBytes:triangles length:sizeof(triangles)];
}

void RSOSCAppendLine(NSMutableData *data, simd_float2 from, simd_float2 to, float halfWidth, simd_float4 color) {
  simd_float2 delta = to - from;
  float length = simd_length(delta);
  if (length < 1e-3f) return;
  simd_float2 u = delta / length, n = (simd_float2){-u.y, u.x};
  float halfLength = length * 0.5f;
  RSOSCVertex prototype = {.kind = RSOSCVertexKindLine, .shape = {halfLength, halfWidth, 0, 0}, .fill = color};
  RSOSCAppendQuad(data, prototype, (from + to) * 0.5f, u, n, halfLength + halfWidth + 1.5f, halfWidth + 1.5f, NO);
}

void RSOSCAppendGlyph(NSMutableData *data, simd_float2 centre, simd_float2 axis, float halfLength, float radius,
                      float outline, simd_float4 fill, simd_float4 stroke) {
  simd_float2 n = (simd_float2){-axis.y, axis.x};
  RSOSCVertex prototype = {.kind = RSOSCVertexKindGlyph, .shape = {halfLength, radius, outline, 0},
                           .fill = fill, .stroke = stroke};
  RSOSCAppendQuad(data, prototype, centre, axis, n, halfLength + radius + 1.5f, radius + 1.5f, YES);
}

void RSOSCAppendSquare(NSMutableData *data, simd_float2 centre, RSOSCSquareStyle style, simd_float4 fill,
                       simd_float4 stroke) {
  // Room for the shadow, which falls below the square and blurs outward. The
  // quad is axis aligned, so `local` runs screen-up like the position and the
  // shader offsets the shadow the other way.
  float pad = style.halfExtent + style.shadowOffset + style.shadowRadius + 1.5f;
  RSOSCVertex prototype = {.shade = style.shadowOffset, .kind = RSOSCVertexKindSquare,
                           .shape = {style.halfExtent, style.cornerRadius, style.outlineWidth, style.shadowRadius},
                           .fill = fill, .stroke = stroke};
  RSOSCAppendQuad(data, prototype, centre, (simd_float2){1, 0}, (simd_float2){0, 1}, pad, pad, NO);
}

void RSOSCRingQuad(RSOSCVertex quad[6], simd_float2 centre, float halfExtent) {
  // `local` runs Y up like the ring geometry, which is Metal's Y flipped.
  const float ox[4] = {-halfExtent, halfExtent, -halfExtent, halfExtent};
  const float oy[4] = {-halfExtent, -halfExtent, halfExtent, halfExtent};
  RSOSCVertex corners[4];
  for (int i = 0; i < 4; ++i)
    corners[i] = (RSOSCVertex){.position = {centre.x + ox[i], centre.y - oy[i]}, .local = {ox[i], oy[i]}};
  const RSOSCVertex triangles[6] = {corners[0], corners[1], corners[2], corners[1], corners[3], corners[2]};
  for (int i = 0; i < 6; ++i) quad[i] = triangles[i];
}

BOOL RSOSCDraw(id<MTLDevice> device, id<MTLTexture> texture, MTLPixelFormat format, NSBundle *bundle,
               NSData *vertices, const RSOSCVertex *ringQuad, const RSOSCRingParams *ringParams, NSString *label) {
  if (!device || !texture) return NO;
  id<MTLRenderPipelineState> pipeline = RSRenderPipeline(device, bundle, format, @"RSOSCVertexShader", @"RSOSCFragmentShader");
  // The rings need their own fragment stage, so they are a second pipeline in
  // the same encoder, drawn first: the glyphs stay on top of them.
  id<MTLRenderPipelineState> ringPipeline =
      ringQuad && ringParams ? RSRenderPipeline(device, bundle, format, @"RSOSCVertexShader", @"RSOSCRingFragment") : nil;
  if (!pipeline || (ringQuad && !ringPipeline)) return NO;
  id<MTLCommandQueue> queue = RSRenderCheckoutQueue(device);
  if (!queue) return NO;
  @try {
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    if (!buffer) return NO;
    buffer.label = label;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return NO;
    [encoder setViewport:(MTLViewport){0, 0, (double)texture.width, (double)texture.height, -1, 1}];
    simd_uint2 viewport = {(uint)texture.width, (uint)texture.height};
    if (ringPipeline) {
      [encoder setRenderPipelineState:ringPipeline];
      [encoder setVertexBytes:ringQuad length:sizeof(RSOSCVertex) * 6 atIndex:RSOSCVertexIndexVertices];
      [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:RSOSCVertexIndexViewportSize];
      [encoder setFragmentBytes:ringParams length:sizeof(*ringParams) atIndex:RSOSCFragmentIndexRingParams];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
    // With every element hidden the clear alone is the draw: an empty vertex
    // buffer is nil and a zero-count draw is invalid.
    if (vertices.length) {
      [encoder setRenderPipelineState:pipeline];
      id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices.bytes length:vertices.length
                                                      options:MTLResourceStorageModeShared];
      [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:RSOSCVertexIndexVertices];
      [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:RSOSCVertexIndexViewportSize];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices.length / sizeof(RSOSCVertex)];
    }
    [encoder endEncoding];
    [buffer commit];
    [buffer waitUntilCompleted];
    return buffer.status == MTLCommandBufferStatusCompleted;
  } @finally {
    RSRenderReturnQueue(queue);
  }
}
