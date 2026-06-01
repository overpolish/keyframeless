/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKConstants.h"
#import "KKDataBlob.h"
#import "KKHostInfo.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import "KKUpdateChecker.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@interface KKPrincipalDelegate : NSObject <FxPrincipalDelegate>
+ (instancetype)shared;
@end

@implementation KKPrincipalDelegate

+ (instancetype)shared {
  static KKPrincipalDelegate *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKPrincipalDelegate alloc] init];
  });
  return instance;
}

- (void)didEstablishConnectionWithHost:(NSString *)hostBundleIdentifier
                               version:(NSString *)hostVersionString {
  [KKHostInfo shared].hostID = hostBundleIdentifier;
  [[KKUpdateChecker shared] checkWithCompletion:^(BOOL __unused available){
  }];
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation KKPlugin
#pragma clang diagnostic pop

@synthesize timingHeader = _timingHeader;
@synthesize motionBlurHeader = _motionBlurHeader;

+ (id)servicePrincipalDelegate {
  return [KKPrincipalDelegate shared];
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
  }
  return self;
}

- (void)setTimingGroupExtraParamIDs:(NSArray<NSNumber *> *)ids {
  objc_setAssociatedObject([self class], kKKTimingExtraIDs, [ids copy],
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSArray<NSNumber *> *)timingGroupExtraParamIDs {
  return objc_getAssociatedObject([self class], kKKTimingExtraIDs);
}

- (void)setLinkedParameterPairs:(NSArray<NSArray<NSNumber *> *> *)pairs {
  objc_setAssociatedObject([self class], kKKLinkedPairs, [pairs copy],
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSArray<NSArray<NSNumber *> *> *)linkedParameterPairs {
  return objc_getAssociatedObject([self class], kKKLinkedPairs);
}

- (BOOL)handleLinkedParameterChanged:(UInt32)parameterID atTime:(CMTime)time {
  NSNumber *locking = objc_getAssociatedObject(self, kKKLinkedLocking);
  if (locking.boolValue)
    return YES;

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL cmdHeld = (flags & kCGEventFlagMaskCommand) != 0;
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;

  if (!cmdHeld && !optHeld) {
    objc_setAssociatedObject(self, kKKLinkedSource, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
  }

  NSArray<NSArray<NSNumber *> *> *pairs = self.linkedParameterPairs;
  UInt32 otherID = 0;
  BOOL found = NO;
  for (NSArray<NSNumber *> *pair in pairs) {
    if (pair.count < 2)
      continue;
    if (pair[0].unsignedIntValue == parameterID) {
      otherID = pair[1].unsignedIntValue;
      found = YES;
      break;
    }
    if (pair[1].unsignedIntValue == parameterID) {
      otherID = pair[0].unsignedIntValue;
      found = YES;
      break;
    }
  }
  if (!found)
    return NO;

  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI)
    return NO;

  double valA = 0;
  [getAPI getFloatValue:&valA fromParameter:parameterID atTime:time];

  if (optHeld) {
    objc_setAssociatedObject(self, kKKLinkedLocking, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [setAPI setFloatValue:valA toParameter:otherID atTime:time];
    objc_setAssociatedObject(self, kKKLinkedLocking, @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
  }

  double valB = 0;
  [getAPI getFloatValue:&valB fromParameter:otherID atTime:time];

  // First-tick guard: when prevSource is nil or different (i.e. this is
  // the first parameterChanged for `parameterID` in this gesture), only
  // record the ratio baseline - don't write the linked partner yet.
  // A cmd-Z / cmd-Shift-Z echo for a linked param is a single one-shot
  // event so it never reaches a "second tick", meaning the linked write
  // never fires from a host-revert echo and the redo stack is preserved.
  // A real cmd-drag emits parameterChanged at ~60 Hz so the second tick
  // arrives within ~16 ms and the partner catches up imperceptibly.
  NSNumber *prevSource = objc_getAssociatedObject(self, kKKLinkedSource);
  BOOL firstTickForSource =
      (prevSource == nil || prevSource.unsignedIntValue != parameterID);
  // Default: clear the "last partner written" marker so plugins polling
  // it via `linkedPartnerWrittenForLastChange` don't see a stale value
  // from a previous call.
  objc_setAssociatedObject(self, kKKLinkedLastPartner, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (firstTickForSource) {
    objc_setAssociatedObject(self, kKKLinkedSource, @(parameterID),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    double ratio = (valA > 0) ? valB / valA : 1.0;
    objc_setAssociatedObject(self, kKKLinkedRatio, @(ratio),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
  }

  NSNumber *ratioNum = objc_getAssociatedObject(self, kKKLinkedRatio);
  double ratio = ratioNum != nil ? ratioNum.doubleValue : 1.0;

  objc_setAssociatedObject(self, kKKLinkedLocking, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [setAPI setFloatValue:valA * ratio toParameter:otherID atTime:time];
  objc_setAssociatedObject(self, kKKLinkedLocking, @NO,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Record the partner so the plugin can run any per-edit side effects
  // (e.g. mirroring the value into a backing path blob) on the partner
  // too. FCP does NOT echo `parameterChanged` for `setFloatValue:` calls
  // made from inside another `parameterChanged`, so without this the
  // partner write reaches the inspector but never triggers the plugin's
  // normal parameterChanged-driven persistence path.
  objc_setAssociatedObject(self, kKKLinkedLastPartner, @(otherID),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  return YES;
}

- (UInt32)linkedPartnerWrittenForLastChange {
  NSNumber *partner = objc_getAssociatedObject(self, kKKLinkedLastPartner);
  return partner != nil ? partner.unsignedIntValue : 0;
}

- (nullable id<MTLRenderPipelineState>)
    pipelineStateForPluginID:(NSString *)pluginID
            destinationImage:(FxImageTile *)destinationImage
                vertexShader:(NSString *)vertexShader
              fragmentShader:(NSString *)fragmentShader
                   blendMode:(KKBlendMode)blendMode {
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;

  return [[KKMetalDeviceCache sharedCache]
      buildAndRegisterPipelineStateForPluginID:pluginID
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:nil
                                  vertexShader:vertexShader
                                fragmentShader:fragmentShader
                                     blendMode:blendMode];
}

- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                               sourceImages:
                                   (NSArray<FxImageTile *> *)sourceImages
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           NSArray<id<MTLTexture>>
                                               *inputTextures))commands {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;

  id<MTLCommandQueue> commandQueue =
      [cache commandQueueWithRegistryID:registryID pixelFormat:pixelFormat];
  if (!commandQueue)
    return NO;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLTexture> outputTexture =
      [destinationImage metalTextureForDevice:device];

  NSMutableArray<id<MTLTexture>> *inputTextures =
      [[NSMutableArray alloc] initWithCapacity:sourceImages.count];
  for (FxImageTile *sourceTile in sourceImages) {
    id<MTLTexture> texture = [sourceTile metalTextureForDevice:device];
    if (texture)
      [inputTextures addObject:texture];
  }

  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  commandBuffer.label = @"KKPlugin Command Buffer";
  [commandBuffer enqueue];

  MTLRenderPassColorAttachmentDescriptor *colorAttachment =
      [[MTLRenderPassColorAttachmentDescriptor alloc] init];
  colorAttachment.texture = outputTexture;
  colorAttachment.clearColor = MTLClearColorMake(0, 0, 0, 0);
  colorAttachment.loadAction = MTLLoadActionClear;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0] = colorAttachment;

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  MTLViewport viewport = {0, 0, outputWidth, outputHeight, -1.0, 1.0};
  [encoder setViewport:viewport];

  // When parent Scale > 100%, FCP renders only a sub-tile of the destination
  // image (tilePixelBounds ⊂ imagePixelBounds). UVs map [0,1] across the full
  // source image, so the shader sees the tile as the corresponding sub-region
  // of the source - not the whole image - which prevents the entire source
  // from being squashed into the sub-tile.
  FxRect dTile = destinationImage.tilePixelBounds;
  FxRect dImg = destinationImage.imagePixelBounds;
  float imgW = (float)(dImg.right - dImg.left);
  float imgH = (float)(dImg.top - dImg.bottom);
  if (imgW <= 0)
    imgW = 1;
  if (imgH <= 0)
    imgH = 1;
  float uvL = (float)(dTile.left - dImg.left) / imgW;
  float uvR = (float)(dTile.right - dImg.left) / imgW;
  float uvT = (float)(dImg.top - dTile.top) / imgH;
  float uvB = (float)(dImg.top - dTile.bottom) / imgH;

  KKVertex2D vertices[] = {
      {{outputWidth / 2.0f, -outputHeight / 2.0f}, {uvR, uvB}},
      {{-outputWidth / 2.0f, -outputHeight / 2.0f}, {uvL, uvB}},
      {{outputWidth / 2.0f, outputHeight / 2.0f}, {uvR, uvT}},
      {{-outputWidth / 2.0f, outputHeight / 2.0f}, {uvL, uvT}},
  };

  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};

  [encoder setVertexBytes:vertices
                   length:sizeof(vertices)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewportSize
                   length:sizeof((viewportSize))
                  atIndex:KKVertexInputIndex_ViewportSize];

  commands(encoder, inputTextures);

  [encoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

  [cache returnCommandQueueToCache:commandQueue];

  return YES;
}

- (BOOL)
    encodeFullScreenQuadIntoTexture:(id<MTLTexture>)destTexture
                   destinationImage:(FxImageTile *)destinationImage
                      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                     sourceTextures:(NSArray<id<MTLTexture>> *)sourceTextures
                           commands:
                               (void (^)(id<MTLRenderCommandEncoder>,
                                         NSArray<id<MTLTexture>> *))commands {
  MTLRenderPassColorAttachmentDescriptor *colorAttachment =
      [[MTLRenderPassColorAttachmentDescriptor alloc] init];
  colorAttachment.texture = destTexture;
  colorAttachment.clearColor = MTLClearColorMake(0, 0, 0, 0);
  colorAttachment.loadAction = MTLLoadActionClear;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0] = colorAttachment;

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];

  float w = (float)destTexture.width;
  float h = (float)destTexture.height;
  MTLViewport viewport = {0, 0, w, h, -1.0, 1.0};
  [encoder setViewport:viewport];

  // See encodeRenderCommandsForDestinationImage: - UVs are mapped to the
  // sub-region of source addressed by the destination tile, so >100% parent
  // Scale (which makes FCP request only a sub-tile) renders sharply.
  float uvL = 0, uvR = 1, uvT = 0, uvB = 1;
  if (destinationImage) {
    FxRect dTile = destinationImage.tilePixelBounds;
    FxRect dImg = destinationImage.imagePixelBounds;
    float imgW = (float)(dImg.right - dImg.left);
    float imgH = (float)(dImg.top - dImg.bottom);
    if (imgW <= 0)
      imgW = 1;
    if (imgH <= 0)
      imgH = 1;
    uvL = (float)(dTile.left - dImg.left) / imgW;
    uvR = (float)(dTile.right - dImg.left) / imgW;
    uvT = (float)(dImg.top - dTile.top) / imgH;
    uvB = (float)(dImg.top - dTile.bottom) / imgH;
  }

  KKVertex2D vertices[] = {
      {{w / 2.0f, -h / 2.0f}, {uvR, uvB}},
      {{-w / 2.0f, -h / 2.0f}, {uvL, uvB}},
      {{w / 2.0f, h / 2.0f}, {uvR, uvT}},
      {{-w / 2.0f, h / 2.0f}, {uvL, uvT}},
  };
  simd_uint2 viewportSize = {(unsigned int)w, (unsigned int)h};

  [encoder setVertexBytes:vertices
                   length:sizeof(vertices)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewportSize
                   length:sizeof(viewportSize)
                  atIndex:KKVertexInputIndex_ViewportSize];

  commands(encoder, sourceTextures);

  [encoder endEncoding];
  return YES;
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  if (sourceImages.count < 1)
    return NO;
  *destinationImageRect = sourceImages[0].imagePixelBounds;
  return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  *sourceTileRect = destinationTileRect;
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                      pluginID:(NSString *)pluginID
                 fragmentBytes:(const void *)fragmentBytes
              fragmentBytesLen:(size_t)fragmentBytesLen
           fragmentBufferIndex:(NSUInteger)fragmentBufferIndex
                         error:(NSError *_Nullable *)outError {
  if (!sourceImages[0].ioSurface || !destinationImage.ioSurface) {
    if (outError) {
      *outError =
          [NSError errorWithDomain:@"co.overpolish.keyframeless"
                              code:-1
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    }
    return NO;
  }

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:pluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipelineState)
    return NO;

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder setRenderPipelineState:
                                                    pipelineState];
                                       [encoder
                                           setFragmentTexture:inputTextures[0]
                                                      atIndex:
                                                          KKTextureIndex_InputImage];
                                       [encoder
                                           setFragmentBytes:fragmentBytes
                                                     length:fragmentBytesLen
                                                    atIndex:
                                                        fragmentBufferIndex];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

- (BOOL)forceShowAllParametersIfEnabled:(UInt32)forceShowParamID
                               paramIDs:(NSArray<NSNumber *> *)paramIDs
                                 atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL forceShow = NO;
  [paramGetAPI getBoolValue:&forceShow
              fromParameter:forceShowParamID
                     atTime:time];
  if (!forceShow)
    return NO;

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  for (NSNumber *paramID in paramIDs) {
    UInt32 pid = paramID.unsignedIntValue;
    FxParameterFlags cur = 0;
    [paramGetAPI getParameterFlags:&cur fromParameter:pid];
    FxParameterFlags want = cur & ~kFxParameterFlag_HIDDEN;
    if (want != cur)
      [paramSetAPI setParameterFlags:want toParameter:pid];
  }
  return YES;
}

- (BOOL)forceShowAllParameters {
  return NO;
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                          groupKey:(NSString *)groupKey
                                            atTime:(CMTime)time {
  return nil;
}

- (BOOL)applyLaneValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label
               groupKey:(NSString *)groupKey
                 atTime:(CMTime)time {
  return NO;
}

- (void)setEditingDisabled:(BOOL)disabled
              forLaneLabel:(NSString *)label
                  groupKey:(NSString *)groupKey {
}

- (NSArray<KKTimingLane *> *)defaultLanesAtTime:(CMTime)time
                                    paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                    paramGetAPI {
  return nil;
}

- (NSArray<KKTimingLane *> *)reconcileLanes:(NSArray<KKTimingLane *> *)existing
                                     atTime:(CMTime)time
                                paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                paramGetAPI {
  return existing;
}

- (NSString *)kkReconcileFingerprintForAPI:(id<PROAPIAccessing>)apiManager {
  return nil;
}

- (BOOL)usesMotionBlur {
  return NO;
}

- (NSSet<NSString *> *)hiddenAnimatablePropertyLabels {
  return [NSSet set];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet set];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSCDefaultOff {
  return [NSSet set];
}

- (NSString *)kkSelectedGroupKey {
  return nil;
}

- (void)kkHandleGroupSegmentClickedForKey:(NSString *)groupKey {
}

- (void)kkRefreshSequencerSelectedGroup {
}

- (void)kkHandleLaneSegmentMutation:(KKLaneSegmentMutation)mutation
                               lane:(KKTimingLane *)lane
                            atIndex:(NSInteger)index
                             getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                             setAPI:(id<FxParameterSettingAPI_v5>)setAPI {
  // Default: no-op. Plugins override to keep out-of-band per-segment data
  // in sync with the sequencer's segment count.
}

- (void)kkLoadLaneSegmentForLabel:(NSString *)label
                         groupKey:(NSString *)groupKey
                          segment:(NSInteger)segmentIndex
                           getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                           setAPI:(id<FxParameterSettingAPI_v5>)setAPI {
  // Default: no-op. Scalar lanes use the values-based applyLaneValues:
  // path; this hook is for plugins with out-of-band per-segment payloads.
}

- (void)kkCopyLaneSegmentForLabel:(NSString *)label
                         groupKey:(NSString *)groupKey
                      fromSegment:(NSInteger)srcSegmentIndex
                        toSegment:(NSInteger)dstSegmentIndex
                           getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                           setAPI:(id<FxParameterSettingAPI_v5>)setAPI {
  // Default: no-op. The scalar values copy handled by
  // _handleSegmentValuesCopiedAtLane: covers value-based lanes.
}

- (NSString *)emptyLanesMessageWhenNoLanes {
  return nil;
}

- (NSString *)emptyLanesIconNameWhenNoLanes {
  return @"rectangle.on.rectangle.slash";
}

// FxPlug requires this when the plugin uses custom parameters - FCP needs
// the value classes ahead of unarchiving project files. Subclasses can
// override and call super to add their own custom-param IDs.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kKKParamMultiStageData ||
      parameterID == kKKParamGradientData ||
      parameterID == kKKParamColorExpanded ||
      parameterID == kKKParamTimingExpanded ||
      parameterID == kKKParamMotionBlurExpanded ||
      parameterID == kKKParamMotionBlurEnabled)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [NSSet set];
}

@end
