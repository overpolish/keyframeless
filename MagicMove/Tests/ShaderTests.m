/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "ShaderTypes.h"
#import "RenderSupportTypes.h"
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

// The columns [originX, originX + width) of a `full`-wide horizontal ramp: the
// partial tile a host hands over when the plugin asked for the whole image.
static id<MTLTexture> makeRampTile(id<MTLDevice> device, NSUInteger full, NSUInteger originX,
                                   NSUInteger width, NSUInteger height) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  uint8_t *pixels = calloc(width * height * 4, sizeof(uint8_t));
  for (NSUInteger y = 0; y < height; ++y) for (NSUInteger x = 0; x < width; ++x) {
    float red = (float)(originX + x) / (float)(full - 1);
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
  RSRenderVertex2D vertices[] = {
    {{-halfWidth, -halfHeight}, {0, 0}}, {{halfWidth, -halfHeight}, {1, 0}},
    {{-halfWidth, halfHeight}, {0, 1}}, {{halfWidth, halfHeight}, {1, 1}}
  };
  vector_uint2 viewport = {(uint32_t)width, (uint32_t)height};
  id<MTLCommandBuffer> command = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:RSRenderVertexIndexVertices];
  [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:RSRenderVertexIndexViewportSize];
  [encoder setFragmentBytes:&transform length:sizeof(transform) atIndex:0];
  [encoder setFragmentTexture:input atIndex:RSRenderTextureIndexInputImage];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
  assert(!command.error);
  [output getBytes:pixels bytesPerRow:width * 4 * sizeof(float)
       fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
}

// A source texture covering the whole frame, rendered into a destination that
// is exactly the frame: identity tiling and identity extent.
static MMTransform transform(float x, float y, float scale, float rotation, float aspect) {
  MMTransform result = {{x, y}, scale, rotation, aspect, scale, 1};
  result.sourceSize = (vector_float2){1, 1};
  result.frameScale = (vector_float2){1, 1};
  return result;
}


static MMTransform transform3(float x, float y, float scale, float z,
                              float aspect, float rotationX, float rotationY) {
  MMTransform result = transform(x, y, scale, z, aspect);
  result.rotationX = rotationX;
  result.rotationY = rotationY;
  return result;
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
    MMTransform opacity=transform(0,0,1,0,1); opacity.opacity=0.5;
    render(device,queue,pipeline,input,opacity,pixels,4,4);
    checkPixel(&pixels[(2*4+2)*4],color*0.5f,0.01f); // premultiplied RGB and alpha
    opacity.opacity=0;
    render(device,queue,pipeline,input,opacity,pixels,4,4);
    for(NSUInteger i=0;i<16;i++) checkPixel(&pixels[i*4],(vector_float4){0,0,0,0},0.001f);
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
    // Anchor is a fraction of the frame and must preserve non-square identity
    // when it is centred at the default pivot.
    MMTransform anchored = transform(0, 0, 0.5f, 0, 2);
    anchored.anchor = (vector_float2){0, 0};
    render(device, queue, pipeline, ramp, anchored, pixels, 8, 4);
    assert(pixels[(2 * 8 + 4) * 4 + 3] > 0.1f);
    // Moving the pivot changes which source point lands at the destination
    // centre. This catches accidental aspect scaling of the anchor itself.
    anchored.anchor = (vector_float2){2.0f / 8.0f, 0};
    render(device, queue, pipeline, ramp, anchored, pixels, 8, 4);
    float pivotRed = pixels[(2 * 8 + 4) * 4];
    assert(pivotRed > 0.05f && pivotRed < 0.25f);
    // A partial source tile must land where it belongs in the frame instead of
    // being stretched across it. Host parent scaling is what makes FCP grant
    // less than the plugin requested, and an asymmetric crop then showed up as
    // a per-axis stretch.
    id<MTLTexture> cropX = makeRampTile(device, 8, 2, 4, 4);
    MMTransform tiled = transform(0, 0, 1, 0, 1);
    tiled.sourceOrigin = (vector_float2){2.0f / 8.0f, 0};
    tiled.sourceSize = (vector_float2){4.0f / 8.0f, 1};
    render(device, queue, pipeline, cropX, tiled, pixels, 8, 4);
    for (NSUInteger x = 2; x < 6; ++x) {
      float red = (float)x / 7.0f * 0.5f;
      vector_float4 expected = {red, red * 0.5f, red * 0.25f, 128.0f / 255.0f};
      checkPixel(&pixels[(2 * 8 + x) * 4], expected, 0.02f);
    }
    for (NSUInteger x = 0; x < 8; ++x)
      if (x < 2 || x >= 6) assert(pixels[(2 * 8 + x) * 4 + 3] == 0);
    // The reported failure was vertical: a tile covering the middle rows must
    // keep the frame's full width and its own height, not fill the frame.
    id<MTLTexture> cropY = makeHorizontalRamp(device, 8, 2);
    MMTransform tiledY = transform(0, 0, 1, 0, 1);
    tiledY.sourceOrigin = (vector_float2){0, 1.0f / 4.0f};
    tiledY.sourceSize = (vector_float2){1, 2.0f / 4.0f};
    render(device, queue, pipeline, cropY, tiledY, pixels, 8, 4);
    for (NSUInteger x = 0; x < 8; ++x) {
      float red = (float)x / 7.0f * 0.5f;
      vector_float4 expected = {red, red * 0.5f, red * 0.25f, 128.0f / 255.0f};
      checkPixel(&pixels[(1 * 8 + x) * 4], expected, 0.02f);
      checkPixel(&pixels[(2 * 8 + x) * 4], expected, 0.02f);
      assert(pixels[(0 * 8 + x) * 4 + 3] == 0 && pixels[(3 * 8 + x) * 4 + 3] == 0);
    }
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
    // Non-square pixel aspect is part of the inverse mapping. The right edge
    // must still sample the right edge of the source ramp at aspect 2.
    render(device, queue, pipeline, ramp, transform(0, 0, 1, 0, 2), pixels, 8, 4);
    assert(pixels[(2 * 8 + 7) * 4] > 0.45f);
    MMTransform zAspect = transform(0, 0, 1, (float)M_PI / 2, 2);
    // Old Z-only inverse: at this sample p=(.125,-.375), so source x is
    // -.1875 and the ramp coordinate is .3125.
    float zExpected = (2.1875f / 7.0f) * 0.5f;
    render(device, queue, pipeline, ramp, zAspect, pixels, 8, 4);
    checkPixel(&pixels[(3 * 8 + 4) * 4],
               (vector_float4){zExpected, zExpected * 0.5f,
                               zExpected * 0.25f, 128.0f / 255.0f}, 0.03f);
    // A small but valid scale must not be mistaken for an edge-on plane.
    id<MTLTexture> one = makeTexture(device, 1, 1, color);
    render(device, queue, pipeline, one, transform(0, 0, 0.001f, 0, 1), pixels, 1, 1);
    checkPixel(pixels, color, 0.01f);

    // A moved image must survive past the frame edge into the grown output, so
    // the host's own transform still has it. Frame is 8 wide, the destination
    // spans half a frame either side of it, and Position is half a frame: the
    // ramp lands in the right half and nothing spills into the left.
    float wide[16 * 4 * 4];
    MMTransform moved = transform(0.5f, 0, 1, 0, 1);
    moved.frameOrigin = (vector_float2){-0.5f, 0};
    moved.frameScale = (vector_float2){2, 1};
    render(device, queue, pipeline, ramp, moved, wide, 16, 4);
    for (NSUInteger i = 8; i < 16; ++i) {
      float red = (float)(i - 8) / 7.0f * 0.5f;
      vector_float4 expected = {red, red * 0.5f, red * 0.25f, 128.0f / 255.0f};
      checkPixel(&wide[(2 * 16 + i) * 4], expected, 0.02f);
    }
    for (NSUInteger i = 0; i < 8; ++i) assert(wide[(2 * 16 + i) * 4 + 3] == 0);

    // Orthographic X rotation foreshortens the vertical plane while retaining
    // its center; Y rotation does the equivalent horizontally.
    MMTransform xTilt=transform3(0,0,1,0,1,(float)M_PI/3,0);
    render(device,queue,pipeline,input,xTilt,pixels,4,4);
    assert(pixels[(2*4+2)*4+3] > .1f && pixels[(0*4+2)*4+3] == 0);
    MMTransform yTilt=transform3(0,0,1,0,1,0,(float)M_PI/3);
    render(device,queue,pipeline,input,yTilt,pixels,4,4);
    assert(pixels[(2*4+2)*4+3] > .1f && pixels[(2*4+0)*4+3] == 0);

    // An edge-on plane has no invertible projected area and must be clear.
    MMTransform edgeOn=transform3(0,0,1,0,1,0,(float)M_PI/2);
    render(device,queue,pipeline,input,edgeOn,pixels,4,4);
    for(NSUInteger i=0;i<16;i++) assert(pixels[i*4+3] == 0);

    // A 180-degree Y flip reverses the horizontal ramp without changing
    // opacity. Combining all axes still produces a finite, visible sample.
    MMTransform flip=transform3(0,0,1,0,1,0,(float)M_PI);
    render(device,queue,pipeline,ramp,flip,pixels,8,4);
    assert(pixels[(2*8+0)*4] > .45f && pixels[(2*8+7)*4] < .05f);
    MMTransform composed=transform3(0,0,1,(float)M_PI/4,1,(float)M_PI/6,(float)M_PI/5);
    composed.opacity=.5f;
    render(device,queue,pipeline,input,composed,pixels,4,4);
    assert(pixels[(2*4+2)*4+3] > .05f && pixels[(2*4+2)*4+3] < .2f);
    puts("ShaderTests: all tests passed");
  }
}
