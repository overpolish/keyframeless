/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "MMLanes.h"
#import "KFRenderHost.h"
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

// Inverse pixel transforms remove host preview/proxy scaling and pixel aspect,
// so the canonical size is the square-pixel geometry the user authored against.
static CGSize MMCanonicalSize(FxImageTile *image, FxRect bounds) {
  FxMatrix44 *inverse=image.inversePixelTransform;
  FxPoint2D lower={bounds.left,bounds.bottom}, upper={bounds.right,bounds.top};
  if(inverse) { lower=[inverse transform2DPoint:lower]; upper=[inverse transform2DPoint:upper]; }
  double width=fabs(upper.x-lower.x),height=fabs(upper.y-lower.y);
  return isfinite(width)&&isfinite(height)&&width>0&&height>0 ? CGSizeMake(width,height) : CGSizeZero;
}
static CGSize MMImageReferenceSize(FxImageTile *image) {
  return MMCanonicalSize(image,image.imagePixelBounds);
}
// The tile the host actually delivered. FxPlug lets it hand over less than
// -sourceTileRect: asked for, and the texture then covers only that tile.
static FxRect MMDeliveredTile(FxImageTile *image) {
  FxRect tile=image.tilePixelBounds, bounds=image.imagePixelBounds;
  if(tile.right-tile.left<=0 || tile.top-tile.bottom<=0) return bounds;
  if(tile.left<bounds.left) tile.left=bounds.left;
  if(tile.bottom<bounds.bottom) tile.bottom=bounds.bottom;
  if(tile.right>bounds.right) tile.right=bounds.right;
  if(tile.top>bounds.top) tile.top=bounds.top;
  return tile;
}
// Authored full-resolution pixels are meaningful only against the canonical
// frame the pivot belongs to, so the anchor becomes a fraction of the source
// frame and the sigma a texture-pixel radius at the delivered tile's scale.
static MMTransform MMTransformForSource(MMTransform state,FxImageTile *source) {
  CGSize frame=MMImageReferenceSize(source);
  if(frame.width>0 && frame.height>0) {
    state.anchor.x/=frame.width;
    state.anchor.y/=frame.height;
  } else {
    state.anchor=(vector_float2){0,0};
  }
  FxRect tile=MMDeliveredTile(source);
  CGSize canonical=MMCanonicalSize(source,tile);
  double tileWidth=tile.right-tile.left, tileHeight=tile.top-tile.bottom;
  if(canonical.width>0 && canonical.height>0)
    state.blurPixels*=fmin(tileWidth/canonical.width,tileHeight/canonical.height);
  FxRect bounds=source.imagePixelBounds;
  double imageWidth=bounds.right-bounds.left, imageHeight=bounds.top-bounds.bottom;
  if(imageWidth>0 && imageHeight>0) {
    state.sourceOrigin=(vector_float2){(float)((tile.left-bounds.left)/imageWidth),
                                       (float)((bounds.top-tile.top)/imageHeight)};
    state.sourceSize=(vector_float2){(float)(tileWidth/imageWidth),
                                     (float)(tileHeight/imageHeight)};
  } else {
    state.sourceOrigin=(vector_float2){0,0};
    state.sourceSize=(vector_float2){1,1};
  }
  return state;
}
// The destination image expressed in source-frame fractions, so the shader can
// convert its own coordinates back to the frame the transform is authored in.
static MMTransform MMTransformForDestination(MMTransform state,FxImageTile *source,
                                             FxImageTile *destination) {
  FxRect frame=source.imagePixelBounds, bounds=destination.imagePixelBounds;
  double frameWidth=frame.right-frame.left, frameHeight=frame.top-frame.bottom;
  double width=bounds.right-bounds.left, height=bounds.top-bounds.bottom;
  if(frameWidth>0 && frameHeight>0 && width>0 && height>0) {
    state.frameOrigin=(vector_float2){(float)((bounds.left-frame.left)/frameWidth),
                                      (float)((frame.top-bounds.top)/frameHeight)};
    state.frameScale=(vector_float2){(float)(width/frameWidth),
                                     (float)(height/frameHeight)};
  } else {
    state.frameOrigin=(vector_float2){0,0};
    state.frameScale=(vector_float2){1,1};
  }
  return state;
}
// Samples carried by a plugin-state payload: one transform when motion blur is
// off, otherwise the shutter samples followed by the shared renderer state.
static NSUInteger MMSampleCount(NSData *pluginState) {
  if(pluginState.length<sizeof(MMTransform)) return 0;
  if(pluginState.length==sizeof(MMTransform)) return 1;
  RSRenderBlurState blur={0};
  if(pluginState.length<2*sizeof(MMTransform)+sizeof(blur)) return 1;
  [pluginState getBytes:&blur range:NSMakeRange(pluginState.length-sizeof(blur),sizeof(blur))];
  if(!blur.enabled || blur.sampleCount<2 || blur.sampleCount>RS_RENDER_BLUR_MAX_SAMPLES ||
     pluginState.length!=(NSUInteger)blur.sampleCount*sizeof(MMTransform)+sizeof(blur))
    return 1;
  return (NSUInteger)blur.sampleCount;
}
// The most margin a side can take, in frames. Content moved past it clips, and
// the cap bounds the allocation given that the filter also needs the whole
// buffer: one frame per side is nine times the frame area.
static const double MMDestinationMarginFrames = 1.0;
// Half-extents of the transformed source quad, in frame fractions from the
// frame centre, y measured downward to match the shader's coordinates. Only
// the magnitude is used: the output rect stays centred on the frame, so it can
// be sized by the pose without ever moving with it.
static void MMTransformHalfExtent(MMTransform state,double aspect,
                                  double *halfX,double *halfY) {
  if(!(state.scale>0) || !(state.scaleY>0) || !isfinite(aspect) || aspect<=0) return;
  double cx=cos(state.rotationX), sx=sin(state.rotationX);
  double cy=cos(state.rotationY), sy=sin(state.rotationY);
  double cz=cos(state.rotation), sz=sin(state.rotation);
  double a=cz*cy*aspect*state.scale, b=(cz*sy*sx-sz*cx)*state.scaleY;
  double c=sz*cy*aspect*state.scale, d=(sz*sy*sx+cz*cx)*state.scaleY;
  for(int corner=0; corner<4; ++corner) {
    double cornerX=(corner&1) ? 0.5 : -0.5, cornerY=(corner&2) ? 0.5 : -0.5;
    double localX=cornerX-state.anchor.x, localY=cornerY-state.anchor.y;
    double x=(a*localX+b*localY)/aspect+state.offset.x+state.anchor.x;
    double y=(c*localX+d*localY)+state.offset.y+state.anchor.y;
    if(!isfinite(x) || !isfinite(y)) continue;
    *halfX=fmax(*halfX,fabs(x)); *halfY=fmax(*halfY,fabs(y));
  }
}
// The source region a destination point reads, in frame fractions offset from
// the frame centre. This is the shader's own inverse projection, so the answer
// to -sourceTileRect: matches the pixels the render will actually sample.
static BOOL MMSourceExtent(MMTransform state,double aspect,double x,double y,
                           double *minX,double *maxX,double *minY,double *maxY) {
  if(!(state.scale>0) || !(state.scaleY>0) || !isfinite(aspect) || aspect<=0) return NO;
  double cx=cos(state.rotationX), sx=sin(state.rotationX);
  double cy=cos(state.rotationY), sy=sin(state.rotationY);
  double cz=cos(state.rotation), sz=sin(state.rotation);
  double a=cz*cy*aspect*state.scale, b=(cz*sy*sx-sz*cx)*state.scaleY;
  double c=sz*cy*aspect*state.scale, d=(sz*sy*sx+cz*cx)*state.scaleY;
  double determinant=a*d-b*c;
  if(fabs(cx*cy)<1.0e-6 || fabs(determinant)<1.0e-12) return NO;
  double px=(x-state.offset.x-state.anchor.x)*aspect, py=y-state.offset.y-state.anchor.y;
  double sourceX=(d*px-b*py)/determinant+state.anchor.x;
  double sourceY=(-c*px+a*py)/determinant+state.anchor.y;
  if(!isfinite(sourceX) || !isfinite(sourceY)) return NO;
  *minX=fmin(*minX,sourceX); *maxX=fmax(*maxX,sourceX);
  *minY=fmin(*minY,sourceY); *maxY=fmax(*maxY,sourceY);
  return YES;
}
- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState atTime:(CMTime)renderTime
                       error:(NSError **)error {
  if (!destinationImageRect || sourceImages.count == 0)
    return MMError(error, @"Missing source image bounds.");
  FxImageTile *source = sourceImages.firstObject;
  FxRect frame = source.imagePixelBounds;
  *destinationImageRect = frame;
  double frameWidth = frame.right-frame.left, frameHeight = frame.top-frame.bottom;
  if (frameWidth <= 0 || frameHeight <= 0) return YES;
  // Sized by the pose, but always centred on the frame. The rect's centre must
  // not move: the host places the output by its own rule rather than by the
  // rect's absolute position, so a rect that shifted with the content moved
  // the buffer the same way and cancelled the translation, leaving Position
  // with no effect on screen while the on-screen control tracked it. Growing
  // symmetrically keeps the buffer still and costs nothing at the poses that
  // never leave the frame, which is most of them.
  CGSize canonical = MMImageReferenceSize(source);
  double aspect = canonical.width > 0 && canonical.height > 0 ? canonical.width/canonical.height
                                                              : frameWidth/frameHeight;
  double halfX = 0.5, halfY = 0.5, blur = 0;
  NSUInteger samples = MMSampleCount(pluginState);
  for (NSUInteger i = 0; i < samples; ++i) {
    MMTransform state;
    [pluginState getBytes:&state range:NSMakeRange(i*sizeof(state),sizeof(state))];
    if (canonical.width > 0 && canonical.height > 0)
      state.anchor = (vector_float2){state.anchor.x/(float)canonical.width,
                                     state.anchor.y/(float)canonical.height};
    else
      state.anchor = (vector_float2){0,0};
    MMTransformHalfExtent(state,aspect,&halfX,&halfY);
    if (isfinite(state.blurPixels)) blur = fmax(blur,state.blurPixels);
  }
  // The Gaussian reaches about three sigma past the transformed edge.
  if (canonical.width > 0) halfX += 3*blur/canonical.width;
  if (canonical.height > 0) halfY += 3*blur/canonical.height;
  const double limit = 0.5+MMDestinationMarginFrames;
  double marginX = (fmin(limit,halfX)-0.5)*frameWidth;
  double marginY = (fmin(limit,halfY)-0.5)*frameHeight;
  destinationImageRect->left = (int)floor(frame.left-marginX);
  destinationImageRect->right = (int)ceil(frame.right+marginX);
  destinationImageRect->top = (int)ceil(frame.top+marginY);
  destinationImageRect->bottom = (int)floor(frame.bottom-marginY);
  return YES;
}
- (void)publishInspectorGeometry:(FxImageTile *)image {
  if(!image) return;
  CGSize size=MMImageReferenceSize(image);
  if(size.width>0 && size.height>0) self.inspectorImageSize=size;
}

// Moving, scaling and rotating the source means a destination tile reads a
// different region of the source. The host asks per tile, so the answer is the
// inverse projection of that tile rather than the whole image.
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect sourceImageIndex:(NSUInteger)index
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState atTime:(CMTime)renderTime error:(NSError **)error {
  if (index >= sourceImages.count) return MMError(error, @"Missing Magic Move source image");
  FxImageTile *source = sourceImages[index];
  [self publishInspectorGeometry:source];
  FxRect frame = source.imagePixelBounds;
  *sourceTileRect = frame;
  double frameWidth = frame.right-frame.left, frameHeight = frame.top-frame.bottom;
  NSUInteger samples = MMSampleCount(pluginState);
  if (frameWidth <= 0 || frameHeight <= 0 || !samples) return YES;
  CGSize canonical = MMImageReferenceSize(source);
  double aspect = canonical.width > 0 && canonical.height > 0 ? canonical.width/canonical.height
                                                              : frameWidth/frameHeight;
  double minX = INFINITY, maxX = -INFINITY, minY = INFINITY, maxY = -INFINITY, blur = 0;
  BOOL mapped = NO;
  for (NSUInteger i = 0; i < samples; ++i) {
    MMTransform state;
    [pluginState getBytes:&state range:NSMakeRange(i*sizeof(state),sizeof(state))];
    if (canonical.width > 0 && canonical.height > 0)
      state.anchor = (vector_float2){state.anchor.x/(float)canonical.width,
                                     state.anchor.y/(float)canonical.height};
    else
      state.anchor = (vector_float2){0,0};
    if (isfinite(state.blurPixels)) blur = fmax(blur,state.blurPixels);
    for (int corner = 0; corner < 4; ++corner) {
      double x = (corner&1) ? destinationTileRect.right : destinationTileRect.left;
      double y = (corner&2) ? destinationTileRect.top : destinationTileRect.bottom;
      if (MMSourceExtent(state,aspect,(x-frame.left)/frameWidth-0.5,
                         (frame.top-y)/frameHeight-0.5,&minX,&maxX,&minY,&maxY))
        mapped = YES;
    }
  }
  // An edge-on or degenerate transform has no invertible region; the whole
  // image is the only safe answer.
  if (!mapped) return YES;
  double blurX = canonical.width > 0 ? 3*blur/canonical.width : 0;
  double blurY = canonical.height > 0 ? 3*blur/canonical.height : 0;
  int left = (int)floor(frame.left+(0.5+minX-blurX)*frameWidth);
  int right = (int)ceil(frame.left+(0.5+maxX+blurX)*frameWidth);
  int top = (int)ceil(frame.top-(0.5+minY-blurY)*frameHeight);
  int bottom = (int)floor(frame.top-(0.5+maxY+blurY)*frameHeight);
  sourceTileRect->left = MAX(frame.left,MIN(frame.right,left));
  sourceTileRect->right = MAX(sourceTileRect->left,MIN(frame.right,right));
  sourceTileRect->bottom = MAX(frame.bottom,MIN(frame.top,bottom));
  sourceTileRect->top = MAX(sourceTileRect->bottom,MIN(frame.top,top));
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
