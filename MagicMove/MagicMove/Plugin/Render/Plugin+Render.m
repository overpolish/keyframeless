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
@import MotionTiming;
#import <math.h>
@import MetalPerformanceShaders;


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
  KKMotionBlurState blur = {0};
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
      NSString *json = [NSString stringWithFormat:
          @"{\"enabled\":true,\"shutterAngle\":%d,\"samples\":%d,\"technique\":1}",
          shutterAngle, samples];
      blur = [KKMotionBlur snapshotStateFromJSON:json
                                     timingAPI:timing atTime:renderTime];
      if (!isfinite(blur.shutterSec) || blur.shutterSec <= 0)
        return MMError(error, @"Unable to read the frame duration for motion blur");
    }
  }
  NSArray<NSValue *> *times = blur.enabled ? [KKMotionBlur sampleTimesForState:blur renderTime:renderTime]
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

// Ported from MagicMove at cb0c3d9a (KKMagicMoveBlurredTexture): MPS Gaussian
// before the transform, clamp edges, negligible-radius bypass and 256px cap.
// The new control authors sigma in full-resolution pixels instead of percent;
// render callers convert to preview/proxy pixels before entering this helper.
static id<MTLTexture> MMBlurredSource(id<MTLTexture> source,
                                      float blurPixels,
                                      id<MTLDevice> device,
                                      id<MTLCommandBuffer> commandBuffer) {
  if (!source || !device || !commandBuffer || !isfinite(blurPixels) || blurPixels <= 0.0f)
    return source;
  float sigma = fminf(blurPixels, 256.0f);
  if (sigma < 0.5f) return source;
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:source.pixelFormat
                                   width:source.width height:source.height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                     MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModePrivate;
  id<MTLTexture> intermediate = [device newTextureWithDescriptor:descriptor];
  if (!intermediate) return source;
  MPSImageGaussianBlur *gaussian = [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
  gaussian.edgeMode = MPSImageEdgeModeClamp;
  [gaussian encodeToCommandBuffer:commandBuffer sourceTexture:source destinationTexture:intermediate];
  return intermediate;
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
  CGSize referenceSize=MMImageReferenceSize(sourceImages[0]);
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
          sample=MMTransformForTexture(sample,textures[0],referenceSize);
          id<MTLTexture> source = MMBlurredSource(textures[0], sample.blurPixels,
                                                  commandBuffer.device, commandBuffer);
          return [self encodeFullScreenQuadIntoTexture:sampleDest destinationImage:destinationImage
              commandBuffer:commandBuffer sourceTextures:@[source]
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
  __block id<MTLTexture> blurredSource = nil;
  __block MMTransform textureState=state;
  // Schedule the spatial pass on the renderer's command buffer before its
  // encoder is opened. This keeps blur and transform in one GPU submission.
  return [self encodeRenderCommandsForDestinationImage:destinationImage sourceImages:sourceImages
      setup:^(id<MTLCommandBuffer> commandBuffer) {
        id<MTLTexture> input = [sourceImages[0] metalTextureForDevice:commandBuffer.device];
        textureState=MMTransformForTexture(state,input,referenceSize);
        blurredSource = MMBlurredSource(input, textureState.blurPixels,
                                        commandBuffer.device, commandBuffer);
      }
      commands:^(id<MTLRenderCommandEncoder> encoder, NSArray<id<MTLTexture>> *textures) {
        [encoder setRenderPipelineState:pipeline];
        id<MTLTexture> input = blurredSource ?: textures[0];
        [encoder setFragmentTexture:input atIndex:KKTextureIndex_InputImage];
        [encoder setFragmentBytes:&textureState length:sizeof(textureState) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      }];
}
@end
#pragma clang diagnostic pop
