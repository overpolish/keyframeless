/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "Plugin+RenderGeometry.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "MMLanes.h"
#import "KFRenderHost.h"
@import MotionTiming;
#import <math.h>

static int MMBlurIntegerSetting(id<FxParameterRetrievalAPI_v6> api, UInt32 parameter,
                                CMTime time, int fallback, int minimum, int maximum) {
  int value = fallback;
  if (![api getIntValue:&value fromParameter:parameter atTime:time]) value = fallback;
  if (value < minimum) value = minimum;
  if (value > maximum) value = maximum;
  return (int)value;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Render)
- (BOOL)pluginState:(NSData **)pluginState atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!api) return MMError(error, @"Magic Move needs parameter access");
  BOOL blurEnabled = NO;
  if (![api getBoolValue:&blurEnabled fromParameter:MMMotionBlur atTime:renderTime])
    return MMError(error, @"Unable to read motion blur setting");
  RSRenderBlurState blur = {0};
  if (blurEnabled) {
    id<FxTimingAPI_v4> timing = [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    int samples = MMBlurIntegerSetting(api, MMMotionBlurSamples, renderTime,
                                       MMMotionBlurDefaultSamples, MMMotionBlurMinSamples,
                                       MMMotionBlurMaxSamples);
    int shutterAngle = MMBlurIntegerSetting(api, MMMotionBlurShutterAngle, renderTime,
                                            MMMotionBlurDefaultShutterAngle,
                                            MMMotionBlurMinShutterAngle,
                                            MMMotionBlurMaxShutterAngle);
    // A zero shutter is an intentional sharp-frame setting, even when the
    // Motion Blur toggle remains enabled.
    if (shutterAngle > MMMotionBlurMinShutterAngle) {
      blur.enabled = true;
      blur.sampleCount = samples;
      CMTime frameDuration = kCMTimeZero;
      if (timing) [timing frameDuration:&frameDuration];
      blur.shutterSec = CMTimeGetSeconds(frameDuration) * shutterAngle / 360.0;
      if (!isfinite(blur.shutterSec) || blur.shutterSec <= 0)
        return MMError(error, @"Unable to read the frame duration for motion blur");
    }
  }
  NSArray<NSValue *> *times = blur.enabled ? RSRenderBlurSampleTimes(blur, renderTime)
      : @[[NSValue valueWithBytes:&renderTime objCType:@encode(CMTime)]];
  NSMutableData *transforms = [NSMutableData dataWithLength:times.count*sizeof(MMTransform)];
  MMTransform *states = transforms.mutableBytes;
  for (NSUInteger sample=0; sample<times.count; ++sample) {
    states[sample].scale = 1;
    states[sample].scaleY = 1;
  }
  NSArray<id<KFPropertyPose>> *positions=[MMPositionLane() readSamples:self.apiManager times:times error:error];
  if(!positions) return NO;
  NSArray<id<KFPropertyPose>> *scales=[MMScaleLane() readSamples:self.apiManager times:times error:error];
  if(!scales) return NO;
  for (NSUInteger sample=0; sample<times.count; ++sample) {
    NSArray<NSNumber *> *offset=positions[sample].values;
    states[sample].offset.x = offset[0].doubleValue/100;
    states[sample].offset.y = offset[1].doubleValue/100;
    NSArray<NSNumber *> *scale=scales[sample].values;
    states[sample].scale = scale[0].doubleValue/100;
    states[sample].scaleY = scale[1].doubleValue/100;
  }
  NSArray<id<KFPropertyPose>> *opacities=[MMOpacityLane() readSamples:self.apiManager times:times error:error];
  if(!opacities) return NO;
  for(NSUInteger sample=0;sample<times.count;sample++)
    states[sample].opacity=fmax(0,fmin(1,opacities[sample].value/100));
  NSArray<id<KFPropertyPose>> *rotations=[MMRotationLane() readSamples:self.apiManager times:times error:error];
  if(!rotations) return NO;
  for(NSUInteger sample=0;sample<times.count;sample++) {
    NSArray<NSNumber *> *angles=rotations[sample].values;
    // Reduce only for trigonometry; authored degrees and timing remain unwrapped.
    states[sample].rotationX=fmod(angles[0].doubleValue,360)*M_PI/180;
    states[sample].rotationY=fmod(angles[1].doubleValue,360)*M_PI/180;
    states[sample].rotation=fmod(angles[2].doubleValue,360)*M_PI/180;
  }
  NSArray<id<KFPropertyPose>> *blurs = [MMBlurLane() readSamples:self.apiManager times:times error:error];
  if (!blurs) return NO;
  NSArray<id<KFPropertyPose>> *anchors = [MMAnchorLane() readSamples:self.apiManager times:times error:error];
  if (!anchors) return NO;
  for (NSUInteger sample=0; sample<times.count; ++sample) {
    NSArray<NSNumber *> *values = anchors[sample].values;
    states[sample].anchor = (vector_float2){
      values.count > 0 ? values[0].doubleValue : 0.0,
      values.count > 1 ? values[1].doubleValue : 0.0};
    states[sample].blurPixels = (float)fmax(0.0, blurs[sample].value);
  }
  // Preserve the one-transform unblurred payload. Blur adds all shutter samples
  // followed by its shared renderer state; sample zero is always renderTime.
  if (blur.enabled) [transforms appendBytes:&blur length:sizeof(blur)];
  *pluginState = transforms;
  return YES;
}
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState atTime:(CMTime)renderTime
                         error:(NSError **)error {
  if (pluginState.length < sizeof(MMTransform) || sourceImages.count == 0 ||
      !sourceImages[0].ioSurface || !destinationImage.ioSurface)
    return MMError(error, @"Invalid Magic Move render input");
  // Inspector and on-screen geometry are the frame's, not the grown output's.
  [self publishInspectorGeometry:sourceImages[0]];
  RSRenderBlurState blur = {0};
  if (pluginState.length != sizeof(MMTransform)) {
    if (pluginState.length < 2*sizeof(MMTransform)+sizeof(blur))
      return MMError(error, @"Invalid motion blur state");
    [pluginState getBytes:&blur range:NSMakeRange(pluginState.length-sizeof(blur),sizeof(blur))];
    if (!blur.enabled || blur.sampleCount < 2 || blur.sampleCount > RS_RENDER_BLUR_MAX_SAMPLES ||
        !isfinite(blur.shutterSec) || blur.shutterSec <= 0 ||
        pluginState.length != (NSUInteger)blur.sampleCount*sizeof(MMTransform)+sizeof(blur))
      return MMError(error, @"Invalid motion blur samples");
  }
  MMTransform state;
  [pluginState getBytes:&state length:sizeof(state)];
  FxRect bounds = destinationImage.imagePixelBounds;
  double width = bounds.right-bounds.left, height = bounds.top-bounds.bottom;
  if (width <= 0 || height <= 0) return MMError(error, @"Invalid Magic Move image size");
  // Rotation and non-uniform scale are only isotropic in square-pixel space,
  // so the frame geometry comes from the source's canonical size. The
  // destination may be larger, and its shape is not the frame's.
  CGSize frameSize=MMImageReferenceSize(sourceImages[0]);
  if (frameSize.width <= 0 || frameSize.height <= 0) {
    FxRect frame=sourceImages[0].imagePixelBounds;
    frameSize=CGSizeMake(frame.right-frame.left,frame.top-frame.bottom);
  }
  if (frameSize.width <= 0 || frameSize.height <= 0) return MMError(error, @"Invalid Magic Move frame size");
  state.aspect = frameSize.width/frameSize.height;
  id<MTLRenderPipelineState> pipeline =
      [self renderPipelineForImage:destinationImage vertex:@"vertexShader" fragment:@"fragmentShader"];
  if (!pipeline) return MMError(error, @"Unable to create Magic Move render pipeline");
  if (blur.enabled) {
    id<MTLRenderPipelineState> accumulation = [self renderPipelineForImage:destinationImage vertex:@"RSRenderBlurVertex" fragment:@"RSRenderBlurAccumulate"];
    id<MTLDevice> renderDevice = RSRenderDevice(destinationImage.deviceRegistryID);
    if (!renderDevice) return MMError(error, @"Unable to resolve the render GPU");
    id<MTLTexture> renderDestination = [destinationImage metalTextureForDevice:renderDevice];
    NSMutableArray<id<MTLTexture>> *renderSources = [NSMutableArray array];
    for (FxImageTile *sourceImage in sourceImages) {
      id<MTLTexture> texture = [sourceImage metalTextureForDevice:renderDevice];
      if (!texture) return MMError(error, @"Unable to read the source texture");
      [renderSources addObject:texture];
    }
    NSArray<NSValue *> *sampleTimes = RSRenderBlurSampleTimes(blur, renderTime);
    BOOL applied = RSRenderApplyBlur(renderDestination, renderSources, blur, renderTime, accumulation,
        ^BOOL(int sampleIndex, id<MTLTexture> sampleDest, id<MTLCommandBuffer> commandBuffer,
                           NSArray<id<MTLTexture>> *textures) {
          if (!textures.count || sampleIndex < 0 || sampleIndex >= blur.sampleCount) return NO;
          // Host tile order is unspecified. Keep the nearest source frame at index zero.
          NSUInteger sourceIndex = 0;
          if (textures.count > 1 && textures.count == sourceImages.count) {
            CMTime sampleTime; [sampleTimes[sampleIndex] getValue:&sampleTime];
            double want = CMTimeGetSeconds(sampleTime), bestDistance = INFINITY;
            for (NSUInteger i = 0; i < sourceImages.count; i++) {
              double distance = fabs(CMTimeGetSeconds(sourceImages[i].mediaTime) - want);
              if (distance < bestDistance) { bestDistance = distance; sourceIndex = i; }
            }
            if (sourceIndex != 0) { NSMutableArray *ordered = [textures mutableCopy]; ordered[0] = textures[sourceIndex]; textures = ordered; }
          }
          MMTransform sample;
          [pluginState getBytes:&sample range:NSMakeRange((NSUInteger)sampleIndex*sizeof(sample),sizeof(sample))];
          sample.aspect = (float)(frameSize.width/frameSize.height);
          sample=MMTransformForDestination(MMTransformForSource(sample,sourceImages[sourceIndex]),
                                           sourceImages[sourceIndex],destinationImage);
          id<MTLTexture> source = RSRenderBlurredTexture(textures[0], sample.blurPixels,
                                                         commandBuffer);
          return [self encodeFullScreenQuadIntoTexture:sampleDest destinationImage:destinationImage
              commandBuffer:commandBuffer sourceTextures:@[source]
              commands:^(id<MTLRenderCommandEncoder> encoder, NSArray<id<MTLTexture>> *inputs) {
                [encoder setRenderPipelineState:pipeline];
                [encoder setFragmentTexture:inputs[0] atIndex:RSRenderTextureIndexInputImage];
                [encoder setFragmentBytes:&sample length:sizeof(sample) atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
              }];
        });
    if (applied) return YES;
  }
  __block id<MTLTexture> blurredSource = nil;
  __block MMTransform textureState=state;
  // Schedule the spatial pass on the renderer's command buffer before its
  // encoder is opened. This keeps blur and transform in one GPU submission.
  return [self encodeRenderCommandsForDestinationImage:destinationImage sourceImages:sourceImages
      setup:^(id<MTLCommandBuffer> commandBuffer) {
        id<MTLTexture> input = [sourceImages[0] metalTextureForDevice:commandBuffer.device];
        textureState=MMTransformForDestination(MMTransformForSource(state,sourceImages[0]),
                                               sourceImages[0],destinationImage);
        blurredSource = RSRenderBlurredTexture(input, textureState.blurPixels,
                                               commandBuffer);
      }
      commands:^(id<MTLRenderCommandEncoder> encoder, NSArray<id<MTLTexture>> *textures) {
        [encoder setRenderPipelineState:pipeline];
        id<MTLTexture> input = blurredSource ?: textures[0];
        [encoder setFragmentTexture:input atIndex:RSRenderTextureIndexInputImage];
        [encoder setFragmentBytes:&textureState length:sizeof(textureState) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      }];
}
@end
#pragma clang diagnostic pop
