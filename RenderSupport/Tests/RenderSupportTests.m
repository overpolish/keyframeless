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
int main(int argc, const char **argv) {
  @autoreleasepool {
    TestTimes();
    if (argc == 2)
      TestGPU([NSBundle bundleWithPath:@(argv[1])]);
  }
  puts("RenderSupport: subframe timing, clamping and missing resources passed");
}
