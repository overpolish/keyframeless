/* SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "RenderSupport.h"
#include <assert.h>
#include <math.h>

static void TestTimes(void) {
  RSRenderBlurState state = {
      .enabled = true, .sampleCount = 4, .shutterSec = 1.0 / 30};
  NSArray<NSValue *> *times = RSRenderBlurSampleTimes(state, CMTimeMake(3, 1));
  assert(times.count == 4);
  CMTime previous = CMTimeMake(4, 1);
  for (NSValue *value in times) {
    CMTime time;
    [value getValue:&time];
    assert(CMTimeCompare(time, previous) < 0);
    previous = time;
  }
  assert(fabs(CMTimeGetSeconds(previous) - (3 - 1.0 / 30)) < 1e-9);
  times = RSRenderBlurSampleTimes(state, kCMTimeZero);
  for (NSValue *value in times) {
    CMTime time;
    [value getValue:&time];
    assert(CMTimeCompare(time, kCMTimeZero) == 0);
  }
  state.sampleCount = 1000;
  assert(RSRenderBlurSampleTimes(state, CMTimeMake(3, 1)).count ==
         RS_RENDER_BLUR_MAX_SAMPLES);
  state.sampleCount = 1;
  assert(RSRenderBlurSampleTimes(state, kCMTimeZero).count == 0);
  state.sampleCount = 4;
  state.shutterSec = NAN;
  assert(RSRenderBlurSampleTimes(state, kCMTimeZero).count == 0);
  state.shutterSec = 1.0 / 30;
  assert(RSRenderBlurSampleTimes(state, kCMTimeInvalid).count == 0);
  state.enabled = false;
  assert(RSRenderBlurSampleTimes(state, kCMTimeZero).count == 0);
  assert(RSRenderCheckoutQueue(nil) == nil);
  RSRenderReturnQueue(nil);
  assert(RSRenderBlurredTexture(nil, 3, nil) == nil);
  assert(!RSRenderApplyBlur(nil, @[], state, kCMTimeZero, nil, nil));
}
static void TestGPU(NSBundle *bundle) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  assert(device && "Metal device required for this GPU test");
  assert(RSRenderDevice(device.registryID).registryID == device.registryID);
  assert(RSRenderDevice(UINT64_MAX) == nil);
  NSMutableArray *queues = [NSMutableArray array];
  for (int i = 0; i < 5; i++) {
    id queue = RSRenderCheckoutQueue(device);
    assert(queue && ![queues containsObject:queue]);
    [queues addObject:queue];
  }
  assert(RSRenderCheckoutQueue(device) == nil);
  id first = queues[0];
  RSRenderReturnQueue(first);
  assert(RSRenderCheckoutQueue(device) == first);
  for (id queue in queues)
    RSRenderReturnQueue(queue);

  id<MTLRenderPipelineState> pipeline =
      RSRenderPipeline(device, bundle, MTLPixelFormatRGBA32Float,
                       @"RSRenderBlurVertex", @"RSRenderBlurAccumulate");
  assert(pipeline);
  assert(pipeline == RSRenderPipeline(device, bundle, MTLPixelFormatRGBA32Float,
                                      @"RSRenderBlurVertex",
                                      @"RSRenderBlurAccumulate"));
  assert(!RSRenderPipeline(device, bundle, MTLPixelFormatRGBA32Float,
                           @"missing", @"RSRenderBlurAccumulate"));
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                   width:8
                                  height:8
                               mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> destination = [device newTextureWithDescriptor:descriptor];
  RSRenderBlurState state = {
      .enabled = true, .sampleCount = 2, .shutterSec = 1.0 / 60};
  __block id<MTLCommandBuffer> common;
  __block NSMutableSet *seen = [NSMutableSet set];
  BOOL (^render)(int, id<MTLTexture>, id<MTLCommandBuffer>, NSArray *) =
      ^BOOL(int index, id<MTLTexture> texture, id<MTLCommandBuffer> buffer,
            NSArray *sources) {
        assert(sources.count == 1 && sources[0] == destination);
        assert(![seen containsObject:texture]);
        [seen addObject:texture];
        if (common)
          assert(common == buffer);
        else
          common = buffer;
        MTLRenderPassDescriptor *pass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(index == 0, 0, index == 1, 1);
        id<MTLRenderCommandEncoder> encoder =
            [buffer renderCommandEncoderWithDescriptor:pass];
        assert(encoder);
        [encoder endEncoding];
        return YES;
      };
  assert(RSRenderApplyBlur(destination, @[ destination ], state, kCMTimeZero,
                           pipeline, render));
  assert(common.status == MTLCommandBufferStatusCompleted);
  float pixel[4];
  [destination getBytes:pixel
            bytesPerRow:sizeof(pixel)
             fromRegion:MTLRegionMake2D(4, 4, 1, 1)
            mipmapLevel:0];
  assert(fabs(pixel[0] - .5) < 1e-5 && fabs(pixel[2] - .5) < 1e-5 &&
         pixel[3] == 1);
  NSSet *firstTextures = [seen copy];
  // Aborting a sample must release the in-flight gate and all resources without
  // committing.
  __block id<MTLCommandBuffer> abandoned;
  for (int attempt = 0; attempt < 7; attempt++)
    assert(!RSRenderApplyBlur(
        destination, @[ destination ], state, kCMTimeZero, pipeline,
        ^BOOL(int index, id<MTLTexture> texture, id<MTLCommandBuffer> buffer,
              NSArray *sources) {
          abandoned = buffer;
          return NO;
        }));
  assert(abandoned.status == MTLCommandBufferStatusNotEnqueued);
  BOOL caught = NO;
  @try {
    RSRenderApplyBlur(
        destination, @[ destination ], state, kCMTimeZero, pipeline,
        ^BOOL(int index, id<MTLTexture> texture, id<MTLCommandBuffer> buffer,
              NSArray *sources) {
          @throw [NSException exceptionWithName:@"TestSampleFailure"
                                         reason:nil
                                       userInfo:nil];
        });
  } @catch (NSException *exception) {
    caught = [exception.name isEqualToString:@"TestSampleFailure"];
  }
  assert(caught);
  seen = [NSMutableSet set];
  common = nil;
  assert(RSRenderApplyBlur(destination, @[ destination ], state, kCMTimeZero,
                           pipeline, render));
  assert([seen isEqual:firstTextures]); // Reuse intermediates instead of
                                        // allocating each frame.
  assert(RSRenderBlurredTexture(destination, .49, nil) == destination);
  puts("RenderSupport GPU: device routing, bounded queues, pipeline cache, "
       "averaging, buffer sharing, abort recovery and texture reuse passed");
}
// The glyph/line routing has a distinct signature per kind: a glyph composites
// its stroke into an outline ring, a line is solid fill. Distinct channel
// colours make each path unambiguous, so a swapped kind branch (glyph solid,
// line outlined) fails these assertions.
static void TestOSCDrawing(NSBundle *bundle) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  assert(device);
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                   width:32
                                  height:32
                               mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  NSMutableData *vertices = [NSMutableData data];
  // A point glyph: red fill, green stroke. The ring must read green, which the
  // solid-fill branch never produces.
  RSOSCAppendGlyph(vertices, (simd_float2){0, 0}, (simd_float2){1, 0}, 0, 4, 1.25,
                   (simd_float4){1, 0, 0, 1}, (simd_float4){0, 1, 0, 1});
  // A line whose interior must be pure fill: no stroke, no gradient tint.
  RSOSCAppendLine(vertices, (simd_float2){-8, 8}, (simd_float2){8, 8}, 2, (simd_float4){0, 0, 1, 1});
  assert(RSOSCDraw(device, texture, MTLPixelFormatRGBA32Float, bundle, vertices, NULL, NULL,
                   @"OSCDrawingTests"));
  float p[4];
  [texture getBytes:p bytesPerRow:sizeof(p) fromRegion:MTLRegionMake2D(16, 16, 1, 1) mipmapLevel:0];
  assert(p[0] > 0.8f && p[1] < 0.3f); // glyph centre: red fill
  [texture getBytes:p bytesPerRow:sizeof(p) fromRegion:MTLRegionMake2D(20, 16, 1, 1) mipmapLevel:0];
  assert(p[1] > 0.5f && p[0] < 0.5f); // glyph ring: green stroke
  [texture getBytes:p bytesPerRow:sizeof(p) fromRegion:MTLRegionMake2D(16, 8, 1, 1) mipmapLevel:0];
  assert(p[2] > 0.9f && p[0] < 0.1f && p[1] < 0.1f); // line interior: blue fill
  [texture getBytes:p bytesPerRow:sizeof(p) fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
  assert(p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0); // far corner stays clear
  puts("RenderSupport OSC: glyph stroke, line solid and clear pass passed");
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    TestTimes();
    if (argc == 2) {
      NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
      TestGPU(bundle);
      TestOSCDrawing(bundle);
    }
  }
  puts("RenderSupport: subframe timing, clamping and missing resources passed");
}
