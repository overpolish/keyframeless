/* SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMRenderHost.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

@implementation MagicMovePlugin (RenderHost)
- (id<MTLRenderPipelineState>)renderPipelineForImage:(FxImageTile *)image
                                              vertex:(NSString *)vertex
                                            fragment:(NSString *)fragment {
  return RSRenderPipeline(RSRenderDevice(image.deviceRegistryID),
                          [NSBundle bundleForClass:MagicMovePlugin.class],
                          RSRenderPixelFormat(image.ioSurface.pixelFormat), vertex, fragment);
}

- (BOOL)encodeFullScreenQuadIntoTexture:(id<MTLTexture>)texture
                       destinationImage:(FxImageTile *)image
                          commandBuffer:(id<MTLCommandBuffer>)buffer
                         sourceTextures:(NSArray<id<MTLTexture>> *)sources
                               commands:(void (^)(id<MTLRenderCommandEncoder>,
                                                  NSArray<id<MTLTexture>> *))
                                            commands {
  if (!texture || !buffer || !commands || !sources.count)
    return NO;
  MTLRenderPassDescriptor *pass =
      [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> encoder =
      [buffer renderCommandEncoderWithDescriptor:pass];
  if (!encoder)
    return NO;
  float w = texture.width, h = texture.height;
  [encoder setViewport:(MTLViewport){0, 0, w, h, -1, 1}];
  // Host parent transforms can request a cropped destination tile even
  // though the plugin requests the full source. UVs must account for the crop.
  FxRect tile = image.tilePixelBounds, bounds = image.imagePixelBounds;
  float imageWidth = MAX(1, bounds.right - bounds.left);
  float imageHeight = MAX(1, bounds.top - bounds.bottom);
  float l = (tile.left - bounds.left) / imageWidth;
  float r = (tile.right - bounds.left) / imageWidth;
  float t = (bounds.top - tile.top) / imageHeight;
  float b = (bounds.top - tile.bottom) / imageHeight;
  RSRenderVertex2D vertices[] = {{{w / 2, -h / 2}, {r, b}},
                                 {{-w / 2, -h / 2}, {l, b}},
                                 {{w / 2, h / 2}, {r, t}},
                                 {{-w / 2, h / 2}, {l, t}}};
  simd_uint2 size = {(uint)w, (uint)h};
  [encoder setVertexBytes:vertices
                   length:sizeof(vertices)
                  atIndex:RSRenderVertexIndexVertices];
  [encoder setVertexBytes:&size
                   length:sizeof(size)
                  atIndex:RSRenderVertexIndexViewportSize];
  @try {
    commands(encoder, sources);
  } @finally {
    [encoder endEncoding];
  }
  return YES;
}

- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)image
                               sourceImages:(NSArray<FxImageTile *> *)sources
                                      setup:
                                          (void (^)(id<MTLCommandBuffer>))setup
                                   commands:
                                       (void (^)(id<MTLRenderCommandEncoder>,
                                                 NSArray<id<MTLTexture>> *))
                                           commands {
  id<MTLDevice> device = RSRenderDevice(image.deviceRegistryID);
  id<MTLCommandQueue> queue = RSRenderCheckoutQueue(device);
  if (!queue)
    return NO;
  @try {
    id<MTLTexture> output = [image metalTextureForDevice:device];
    NSMutableArray *inputs = [NSMutableArray array];
    for (FxImageTile *source in sources) {
      id<MTLTexture> input = [source metalTextureForDevice:device];
      if (!input)
        return NO;
      [inputs addObject:input];
    }
    if (!output || !inputs.count)
      return NO;
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    if (!buffer)
      return NO;
    buffer.label = @"MagicMove Render";
    if (setup)
      setup(buffer);
    if (![self encodeFullScreenQuadIntoTexture:output
                              destinationImage:image
                                 commandBuffer:buffer
                                sourceTextures:inputs
                                      commands:commands])
      return NO;
    [buffer commit];
    [buffer waitUntilCompleted];
    return buffer.status == MTLCommandBufferStatusCompleted;
  } @finally {
    RSRenderReturnQueue(queue);
  }
}
@end
