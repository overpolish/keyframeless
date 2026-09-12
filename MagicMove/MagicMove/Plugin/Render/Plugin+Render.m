/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "MMDestinations.h"
#import "MMCombinedPose.h"
@import MotionTiming;
#import <math.h>


static BOOL MMError(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_InvalidParameter
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
  return NO;
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
  KKMotionBlurState blur = {0};
  if (blurEnabled) {
    id<FxTimingAPI_v4> timing = [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    blur = [KKMotionBlur snapshotStateFromJSON:@"{\"enabled\":true,\"shutterAngle\":180,\"samples\":16,\"technique\":1}"
                                     timingAPI:timing atTime:renderTime];
    if (!isfinite(blur.shutterSec) || blur.shutterSec <= 0)
      return MMError(error, @"Unable to read the frame duration for motion blur");
  }
  NSArray<NSValue *> *times = blur.enabled ? [KKMotionBlur sampleTimesForState:blur renderTime:renderTime]
      : @[[NSValue valueWithBytes:&renderTime objCType:@encode(CMTime)]];
  NSMutableData *transforms = [NSMutableData dataWithLength:times.count*sizeof(MMTransform)];
  MMTransform *states = transforms.mutableBytes;
  for (NSUInteger sample=0; sample<times.count; ++sample) states[sample].scale = 1;
  BOOL combinedActive = NO;
  NSArray<MMCombinedPose *> *combined = MMReadCombinedPoseSamples(self.apiManager, times, &combinedActive, error);
  if (!combined) return NO;
  if (combinedActive) {
    for (NSUInteger sample=0; sample<times.count; ++sample) {
      states[sample].offset.x = combined[sample].positionX/100;
      states[sample].scale = combined[sample].scale/100;
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
      else if (lane.valueID == MMScale) states[sample].scale = value/100;
    }
  }
  // Preserve the one-transform unblurred payload. Blur adds all shutter samples
  // followed by its shared renderer state; sample zero is always renderTime.
  if (blur.enabled) [transforms appendBytes:&blur length:sizeof(blur)];
  *pluginState = transforms;
  return YES;
}

// Moving/rotating the source can require pixels outside the destination tile.
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect sourceImageIndex:(NSUInteger)index
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState atTime:(CMTime)renderTime error:(NSError **)error {
  if (index >= sourceImages.count) return MMError(error, @"Missing Magic Move source image");
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
  KKMotionBlurState blur = {0};
  if (pluginState.length != sizeof(MMTransform)) {
    if (pluginState.length < 2*sizeof(MMTransform)+sizeof(blur))
      return MMError(error, @"Invalid motion blur state");
    [pluginState getBytes:&blur range:NSMakeRange(pluginState.length-sizeof(blur),sizeof(blur))];
    if (!blur.enabled || blur.sampleCount < 2 || blur.sampleCount > KK_MOTION_BLUR_MAX_SAMPLES ||
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
  id<MTLRenderPipelineState> pipeline =
      [self pipelineStateForPluginID:kPluginID destinationImage:destinationImage
                        vertexShader:@"vertexShader" fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipeline) return MMError(error, @"Unable to create Magic Move render pipeline");
  if (blur.enabled) {
    BOOL applied = [KKMotionBlur applyToDestinationImage:destinationImage sourceImages:sourceImages
        state:blur renderTime:renderTime
        renderBlock:^BOOL(int sampleIndex, id<MTLTexture> sampleDest, id<MTLCommandBuffer> commandBuffer,
                           NSArray<id<MTLTexture>> *textures) {
          if (!textures.count || sampleIndex < 0 || sampleIndex >= blur.sampleCount) return NO;
          MMTransform sample;
          [pluginState getBytes:&sample range:NSMakeRange((NSUInteger)sampleIndex*sizeof(sample),sizeof(sample))];
          sample.aspect = width/height;
          return [self encodeFullScreenQuadIntoTexture:sampleDest destinationImage:destinationImage
              commandBuffer:commandBuffer sourceTextures:textures
              commands:^(id<MTLRenderCommandEncoder> encoder, NSArray<id<MTLTexture>> *inputs) {
                [encoder setRenderPipelineState:pipeline];
                [encoder setFragmentTexture:inputs[0] atIndex:KKTextureIndex_InputImage];
                [encoder setFragmentBytes:&sample length:sizeof(sample) atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
              }];
        }];
    if (applied) return YES;
    // Retain the old fallback if shared blur resources cannot be prepared.
  }
  return [self encodeRenderCommandsForDestinationImage:destinationImage sourceImages:sourceImages
      commands:^(id<MTLRenderCommandEncoder> encoder, NSArray<id<MTLTexture>> *textures) {
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:textures[0] atIndex:KKTextureIndex_InputImage];
        [encoder setFragmentBytes:&state length:sizeof(state) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      }];
}
@end
#pragma clang diagnostic pop
