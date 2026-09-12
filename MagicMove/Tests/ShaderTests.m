/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "ShaderTypes.h"
#import <KeyframelessKit/KKShaderTypes.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>

static void checkPixel(const float *pixel, vector_float4 expected, float tolerance) {
  for (int i = 0; i < 4; ++i) assert(fabsf(pixel[i] - expected[i]) <= tolerance);
}

static id<MTLTexture> makeTexture(id<MTLDevice> device, NSUInteger width, NSUInteger height,
                                  vector_float4 color) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  uint8_t *pixels = calloc(width * height * 4, sizeof(uint8_t));
  for (NSUInteger i = 0; i < width * height; ++i)
    for (NSUInteger c = 0; c < 4; ++c) pixels[i * 4 + c] = (uint8_t)lrintf(fminf(fmaxf(color[c], 0), 1) * 255);
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4 * sizeof(uint8_t)];
  free(pixels);
  return texture;
}

static id<MTLTexture> makeHorizontalRamp(id<MTLDevice> device, NSUInteger width, NSUInteger height) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  uint8_t *pixels = calloc(width * height * 4, sizeof(uint8_t));
  for (NSUInteger y = 0; y < height; ++y) for (NSUInteger x = 0; x < width; ++x) {
    float red = width > 1 ? (float)x / (float)(width - 1) : 0;
    // Premultiplied ramp: RGB is alpha-scaled and every row is identical.
    pixels[(y * width + x) * 4 + 0] = (uint8_t)lrintf(red * 0.5f * 255);
    pixels[(y * width + x) * 4 + 1] = (uint8_t)lrintf(red * 0.25f * 255);
    pixels[(y * width + x) * 4 + 2] = (uint8_t)lrintf(red * 0.125f * 255);
    pixels[(y * width + x) * 4 + 3] = 128;
  }
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
               withBytes:pixels bytesPerRow:width * 4 * sizeof(uint8_t)];
  free(pixels);
  return texture;
}

static id<MTLRenderPipelineState> makePipeline(id<MTLDevice> device, id<MTLLibrary> library) {
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"vertexShader"];
  descriptor.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
  NSError *error = nil;
  id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  assert(pipeline && !error);
  return pipeline;
}

static void render(id<MTLDevice> device, id<MTLCommandQueue> queue,
                   id<MTLRenderPipelineState> pipeline, id<MTLTexture> input,
                   MMTransform transform, float *pixels, NSUInteger width, NSUInteger height) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                           width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  id<MTLTexture> output = [device newTextureWithDescriptor:descriptor];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = output;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  float halfWidth = (float)width / 2.0f, halfHeight = (float)height / 2.0f;
  KKVertex2D vertices[] = {
    {{-halfWidth, -halfHeight}, {0, 0}}, {{halfWidth, -halfHeight}, {1, 0}},
    {{-halfWidth, halfHeight}, {0, 1}}, {{halfWidth, halfHeight}, {1, 1}}
  };
  vector_uint2 viewport = {(uint32_t)width, (uint32_t)height};
  id<MTLCommandBuffer> command = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:KKVertexInputIndex_ViewportSize];
  [encoder setFragmentBytes:&transform length:sizeof(transform) atIndex:0];
  [encoder setFragmentTexture:input atIndex:KKTextureIndex_InputImage];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
  assert(!command.error);
  [output getBytes:pixels bytesPerRow:width * 4 * sizeof(float)
       fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
}

static MMTransform transform(float x, float y, float scale, float rotation, float aspect) {
  MMTransform result = {{x, y}, scale, rotation, aspect, scale}; return result;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: %s shader.metallib\n", argv[0]); return 2; }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("ShaderTests: skipped (no Metal device)"); return 0; }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] error:&error];
    if (!library) { fprintf(stderr, "unable to load metallib: %s\n", error.localizedDescription.UTF8String); return 1; }
    id<MTLRenderPipelineState> pipeline = makePipeline(device, library);
    id<MTLCommandQueue> queue = [device newCommandQueue]; assert(queue);
    vector_float4 color = {0.20f, 0.10f, 0.05f, 0.25f};
    id<MTLTexture> input = makeTexture(device, 4, 4, color);
    float pixels[8 * 4 * 4];

    render(device, queue, pipeline, input, transform(0, 0, 1, 0, 1), pixels, 4, 4);
    checkPixel(&pixels[(2 * 4 + 2) * 4], color, 0.01f); // identity
    render(device, queue, pipeline, input, transform(0.75f, 0, 1, 0, 1), pixels, 4, 4);
    assert(pixels[0 * 4 + 3] == 0 && pixels[3 * 4 + 3] > 0.1f); // positive X
    render(device, queue, pipeline, input, transform(-0.75f, 0, 1, 0, 1), pixels, 4, 4);
    assert(pixels[3 * 4 + 3] == 0 && pixels[0 * 4 + 3] > 0.1f); // negative X
    render(device, queue, pipeline, input, transform(0, 0, 0, 0, 1), pixels, 4, 4);
    for (NSUInteger i = 0; i < 16; ++i) assert(pixels[i * 4 + 3] == 0); // scale zero
    render(device, queue, pipeline, input, transform(0, 0, 0.5f, 0, 1), pixels, 4, 4);
    assert(pixels[(2 * 4 + 2) * 4 + 3] > 0.1f && pixels[3] == 0); // centered scale
    MMTransform stretch = transform(0, 0, 1, 0, 1); stretch.scaleY = 0.5f;
    render(device, queue, pipeline, input, stretch, pixels, 4, 4);
    assert(pixels[(2*4)*4+3] > 0.1f && pixels[3] == 0); // full width, half height
    stretch.scaleY = 0;
    render(device, queue, pipeline, input, stretch, pixels, 4, 4);
    for (NSUInteger i=0; i<16; ++i) assert(pixels[i*4+3] == 0);
    render(device, queue, pipeline, input, transform(3, 0, 1, 0, 1), pixels, 4, 4);
    for (NSUInteger i = 0; i < 16; ++i) assert(pixels[i * 4 + 3] == 0); // outside bounds

    id<MTLTexture> ramp = makeHorizontalRamp(device, 8, 4);
    render(device, queue, pipeline, ramp, transform(0, 0, 1, 0, 1), pixels, 8, 4);
    for (NSUInteger x = 0; x < 8; ++x) {
      float red = (float)x / 7.0f * 0.5f;
      vector_float4 expected = {red, red * 0.5f, red * 0.25f, 128.0f / 255.0f};
      checkPixel(&pixels[(2 * 8 + x) * 4], expected, 0.02f);
    } // identity, premultiplied horizontal ramp, and non-square dimensions
    render(device, queue, pipeline, ramp, transform(1.0f / 8.0f, 0, 1, 0, 1), pixels, 8, 4);
    assert(pixels[(2 * 8) * 4 + 3] == 0); // exact positive one-pixel translation
    checkPixel(&pixels[(2 * 8 + 4) * 4], (vector_float4){4.0f / 7.0f * 0.5f, 4.0f / 7.0f * 0.25f,
                                                          4.0f / 7.0f * 0.125f, 128.0f / 255.0f}, 0.08f);
    render(device, queue, pipeline, ramp, transform(-1.0f / 8.0f, 0, 1, 0, 1), pixels, 8, 4);
    assert(pixels[(2 * 8 + 7) * 4 + 3] == 0); // exact negative one-pixel translation
    checkPixel(&pixels[(2 * 8 + 3) * 4], (vector_float4){3.0f / 7.0f * 0.5f, 3.0f / 7.0f * 0.25f,
                                                          3.0f / 7.0f * 0.125f, 128.0f / 255.0f}, 0.08f);
    render(device, queue, pipeline, ramp, transform(0, 0, 2, 0, 1), pixels, 8, 4);
    checkPixel(&pixels[(2 * 8 + 4) * 4], (vector_float4){3.0f / 7.0f * 0.5f, 3.0f / 7.0f * 0.25f,
                                                          3.0f / 7.0f * 0.125f, 128.0f / 255.0f}, 0.08f);
    render(device, queue, pipeline, ramp, transform(0, 0, 0.5f, 0, 1), pixels, 8, 4);
    assert(pixels[(2 * 8 + 0) * 4 + 3] == 0 && pixels[(2 * 8 + 7) * 4 + 3] == 0);
    puts("ShaderTests: all tests passed");
  }
}
