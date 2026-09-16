/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "RSOSCDrawing.h"
#import "RenderSupportTypes.h"

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef struct {
  bool enabled;
  int sampleCount;
  double shutterSec;
} RSRenderBlurState;

FOUNDATION_EXPORT NSArray<NSValue *> *
RSRenderBlurSampleTimes(RSRenderBlurState state, CMTime renderTime);
FOUNDATION_EXPORT id<MTLTexture>
RSRenderBlurredTexture(id<MTLTexture> source, float blurPixels,
                       id<MTLCommandBuffer> commandBuffer);
FOUNDATION_EXPORT BOOL
RSRenderApplyBlur(id<MTLTexture> destination, NSArray<id<MTLTexture>> *sources,
                  RSRenderBlurState state, CMTime renderTime,
                  id<MTLRenderPipelineState> accumulationPipeline,
                  BOOL (^renderBlock)(int, id<MTLTexture>, id<MTLCommandBuffer>,
                                      NSArray<id<MTLTexture>> *));

// Device selection must follow the host's registry ID, not the system default
// GPU.
FOUNDATION_EXPORT id<MTLDevice> RSRenderDevice(uint64_t registryID);
// Bounded, reusable queues. Every successful checkout must be returned after
// GPU completion.
FOUNDATION_EXPORT id<MTLCommandQueue>
RSRenderCheckoutQueue(id<MTLDevice> device);
FOUNDATION_EXPORT void RSRenderReturnQueue(id<MTLCommandQueue> queue);
FOUNDATION_EXPORT id<MTLRenderPipelineState>
RSRenderPipeline(id<MTLDevice> device, NSBundle *bundle, MTLPixelFormat format,
                 NSString *vertex, NSString *fragment);
// The Metal format for an IOSurface pixel format the host hands over: float
// tiles keep their precision, 8-bit BGRA stays BGRA, anything else is half.
FOUNDATION_EXPORT MTLPixelFormat RSRenderPixelFormat(OSType ioSurfacePixelFormat);
