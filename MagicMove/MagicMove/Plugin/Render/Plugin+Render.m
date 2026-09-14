/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "MMDestinations.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"
#import "MMAnchorPose.h"
#import "MMRenderHost.h"
@import MotionTiming;
#import <math.h>


static BOOL MMError(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_InvalidParameter
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
  return NO;
}
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
  BOOL combinedActive = NO;
  NSArray<MMCombinedPose *> *combined = MMReadCombinedPoseSamples(self.apiManager, times, &combinedActive, error);
  if (!combined) return NO;
  if (combinedActive) {
    for (NSUInteger sample=0; sample<times.count; ++sample) {
      states[sample].offset.x = combined[sample].positionX/100;
      states[sample].offset.y = combined[sample].positionY/100;
      states[sample].scale = combined[sample].scale/100;
      states[sample].scaleY = combined[sample].scale/100;
    }
  } else for (MMTimingLane *lane in self.timingLanes) {
    NSUInteger generation = lane.durationGeneration;
    NSData *pending = lane.pendingDestinations;
    NSData *data = pending ? MMReadDestinationsFromPrevious(self.apiManager, lane.valueID, pending, error)
                           : MMReadDestinations(self.apiManager, lane.valueID, lane.dataID, error);
    if (!data) return NO;
    [lane publishDurationSnapshot:data generation:generation];
    const MTDurationRecord *records = data.bytes;
    NSUInteger count = data.length/sizeof(*records);
    NSMutableData *storage = [NSMutableData dataWithLength:count*sizeof(MTDestination)];
    MTDestination *destinations = storage.mutableBytes;
    const double motionMin = lane.valueID == MMScale ? 0 : -200;
    const double motionMax = lane.valueID == MMScale ? 400 : 200;
    for (NSUInteger i=0; i<count; ++i)
      destinations[i] = (MTDestination){records[i].time-records[0].time,
        (records[i].useAvailableTime && i > 0 ? records[i].time-records[i-1].time : records[i].duration),
        &records[i].value, records[i].easing, records[i].addedMotion, &motionMin, &motionMax, 1};
    double constant = 0;
    if (!count && ![api getFloatValue:&constant fromParameter:lane.valueID atTime:renderTime])
      return MMError(error, @"Magic Move could not read a motion value");
    for (NSUInteger sample=0; sample<times.count; ++sample) {
      CMTime time; [times[sample] getValue:&time];
      double value = constant;
      if (count && !MTSample(destinations, count, 1, CMTimeGetSeconds(time)-records[0].time, &value))
        return MMError(error, @"Invalid motion destinations");
      if (!isfinite(value)) return MMError(error, @"Invalid motion value");
      if (lane.valueID == MMPositionX) states[sample].offset.x = value/100;
      else if (lane.valueID == MMScale) { states[sample].scale = value/100; states[sample].scaleY = value/100; }
    }
  }
  BOOL scaleActive = NO;
  NSArray<MMScalePose *> *scales = MMReadScalePoseSamples(self.apiManager, times, &scaleActive, error);
  if (!scales) return NO;
  if (scaleActive) for (NSUInteger sample=0; sample<times.count; ++sample) {
    states[sample].scale = scales[sample].x/100;
    states[sample].scaleY = scales[sample].y/100;
  }
  NSArray<MMScalarPose *> *opacities=[MMOpacityLane() readSamples:self.apiManager times:times error:error];
  if(!opacities) return NO;
  for(NSUInteger sample=0;sample<times.count;sample++)
    states[sample].opacity=fmax(0,fmin(1,opacities[sample].value/100));
  NSArray<id<MMPropertyPose>> *rotations=[MMRotationLane() readSamples:self.apiManager times:times error:error];
  if(!rotations) return NO;
  for(NSUInteger sample=0;sample<times.count;sample++) {
    NSArray<NSNumber *> *angles=rotations[sample].values;
    // Reduce only for trigonometry; authored degrees and timing remain unwrapped.
    states[sample].rotationX=fmod(angles[0].doubleValue,360)*M_PI/180;
    states[sample].rotationY=fmod(angles[1].doubleValue,360)*M_PI/180;
    states[sample].rotation=fmod(angles[2].doubleValue,360)*M_PI/180;
  }
  NSArray<MMScalarPose *> *blurs = [MMBlurLane() readSamples:self.apiManager times:times error:error];
  if (!blurs) return NO;
  NSArray<id<MMPropertyPose>> *anchors = [MMAnchorLane() readSamples:self.apiManager times:times error:error];
  if (!anchors) return NO;
  for (NSUInteger sample=0; sample<times.count; ++sample) {
    NSArray<NSNumber *> *values = anchors[sample].values;
    states[sample].anchorPixels = (vector_float2){
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

// Inverse pixel transforms remove host preview/proxy scaling and pixel aspect.
static CGSize MMImageReferenceSize(FxImageTile *image) {
  FxRect bounds=image.imagePixelBounds;
  FxMatrix44 *inverse=image.inversePixelTransform;
  FxPoint2D lower={bounds.left,bounds.bottom}, upper={bounds.right,bounds.top};
  if(inverse) { lower=[inverse transform2DPoint:lower]; upper=[inverse transform2DPoint:upper]; }
  double width=fabs(upper.x-lower.x),height=fabs(upper.y-lower.y);
  return isfinite(width)&&isfinite(height)&&width>0&&height>0 ? CGSizeMake(width,height) : CGSizeZero;
}
static MMTransform MMTransformForTexture(MMTransform state,id<MTLTexture> texture,CGSize reference) {
  if(reference.width>0 && reference.height>0) {
    state.anchorPixels.x *= texture.width/reference.width;
    state.anchorPixels.y *= texture.height/reference.height;
    state.blurPixels *= fmin(texture.width/reference.width,texture.height/reference.height);
  }
  return state;
}
- (void)publishInspectorGeometry:(FxImageTile *)image {
  if(!image) return;
  CGSize size=MMImageReferenceSize(image);
  if(size.width>0 && size.height>0) self.inspectorImageSize=size;
}

// Moving/rotating the source can require pixels outside the destination tile.
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect sourceImageIndex:(NSUInteger)index
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState atTime:(CMTime)renderTime error:(NSError **)error {
  if (index >= sourceImages.count) return MMError(error, @"Missing Magic Move source image");
  [self publishInspectorGeometry:destinationImage];
  *sourceTileRect = sourceImages[index].imagePixelBounds;
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState atTime:(CMTime)renderTime
                         error:(NSError **)error {
  if (pluginState.length < sizeof(MMTransform) || sourceImages.count == 0 ||
      !sourceImages[0].ioSurface || !destinationImage.ioSurface)
    return MMError(error, @"Invalid Magic Move render input");
  [self publishInspectorGeometry:destinationImage];
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
  state.aspect = width/height;
  CGSize referenceSize=MMImageReferenceSize(sourceImages[0]);
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
          if (textures.count > 1 && textures.count == sourceImages.count) {
            CMTime sampleTime; [sampleTimes[sampleIndex] getValue:&sampleTime];
            double want = CMTimeGetSeconds(sampleTime), bestDistance = INFINITY;
            NSUInteger best = 0;
            for (NSUInteger i = 0; i < sourceImages.count; i++) {
              double distance = fabs(CMTimeGetSeconds(sourceImages[i].mediaTime) - want);
              if (distance < bestDistance) { bestDistance = distance; best = i; }
            }
            if (best != 0) { NSMutableArray *ordered = [textures mutableCopy]; ordered[0] = textures[best]; textures = ordered; }
          }
          MMTransform sample;
          [pluginState getBytes:&sample range:NSMakeRange((NSUInteger)sampleIndex*sizeof(sample),sizeof(sample))];
          sample.aspect = width/height;
          sample=MMTransformForTexture(sample,textures[0],referenceSize);
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
        textureState=MMTransformForTexture(state,input,referenceSize);
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
