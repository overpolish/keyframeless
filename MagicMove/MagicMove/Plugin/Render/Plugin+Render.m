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
  MMTransform state = {0};
  state.scale = 1;
  BOOL combinedActive = NO;
  MMCombinedPose *combined = MMReadCombinedPose(self.apiManager, renderTime, &combinedActive, error);
  if (!combined) return NO;
  if (combinedActive) {
    state.offset.x = combined.positionX/100;
    state.scale = combined.scale/100;
    *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
    return YES;
  }
  for (MMTimingLane *lane in self.timingLanes) {
    NSUInteger generation = lane.durationGeneration;
    NSData *pending = lane.pendingDestinations;
    NSData *data = pending ? MMReadDestinationsFromPrevious(self.apiManager, lane.valueID, pending, error)
                           : MMReadDestinations(self.apiManager, lane.valueID, lane.dataID, error);
    if (!data) return NO;
    [lane publishDurationSnapshot:data generation:generation];
    const MTDurationRecord *records = data.bytes;
    NSUInteger count = data.length/sizeof(*records);
    double value;
    if (count == 0) {
      if (![api getFloatValue:&value fromParameter:lane.valueID atTime:renderTime])
        return MMError(error, @"Magic Move could not read a motion value");
    } else {
      NSMutableData *storage = [NSMutableData dataWithLength:count*sizeof(MTDestination)];
      MTDestination *destinations = storage.mutableBytes;
      for (NSUInteger i=0; i<count; ++i)
        destinations[i] = (MTDestination){records[i].time-records[0].time,
                                           (records[i].useAvailableTime && i > 0 ?
                                            records[i].time-records[i-1].time : records[i].duration),
                                           &records[i].value, records[i].easing};
      double seconds = CMTimeGetSeconds(renderTime)-records[0].time;
      if (!MTSample(destinations, count, 1, seconds, &value))
        return MMError(error, @"Invalid motion destinations");
    }
    if (!isfinite(value)) return MMError(error, @"Invalid motion value");
    if (lane.valueID == MMPositionX) state.offset.x = value/100;
    else if (lane.valueID == MMScale) state.scale = value/100;
  }
  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
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
  if (pluginState.length != sizeof(MMTransform) || sourceImages.count == 0 ||
      !sourceImages[0].ioSurface || !destinationImage.ioSurface)
    return MMError(error, @"Invalid Magic Move render input");
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
