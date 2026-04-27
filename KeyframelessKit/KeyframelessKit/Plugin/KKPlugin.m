/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Update/KKUpdateChecker.h"
#import "../Views/KKTimingSlot.h"
#import "KKHostInfo.h"
#import "KKPlugin_Private.h"
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
@synthesize timingGraph = _timingGraph;

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

  NSNumber *prevSource = objc_getAssociatedObject(self, kKKLinkedSource);
  if (!prevSource || prevSource.unsignedIntValue != parameterID) {
    objc_setAssociatedObject(self, kKKLinkedSource, @(parameterID),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    double ratio = (valA > 0) ? valB / valA : 1.0;
    objc_setAssociatedObject(self, kKKLinkedRatio, @(ratio),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  NSNumber *ratioNum = objc_getAssociatedObject(self, kKKLinkedRatio);
  double ratio = ratioNum ? ratioNum.doubleValue : 1.0;

  objc_setAssociatedObject(self, kKKLinkedLocking, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [setAPI setFloatValue:valA * ratio toParameter:otherID atTime:time];
  objc_setAssociatedObject(self, kKKLinkedLocking, @NO,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  return YES;
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

  KKVertex2D vertices[] = {
      {{outputWidth / 2.0f, -outputHeight / 2.0f}, {1.0, 1.0}},
      {{-outputWidth / 2.0f, -outputHeight / 2.0f}, {0.0, 1.0}},
      {{outputWidth / 2.0f, outputHeight / 2.0f}, {1.0, 0.0}},
      {{-outputWidth / 2.0f, outputHeight / 2.0f}, {0.0, 0.0}},
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

  KKVertex2D vertices[] = {
      {{w / 2.0f, -h / 2.0f}, {1.0, 1.0}},
      {{-w / 2.0f, -h / 2.0f}, {0.0, 1.0}},
      {{w / 2.0f, h / 2.0f}, {1.0, 0.0}},
      {{-w / 2.0f, h / 2.0f}, {0.0, 0.0}},
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
    [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                       toParameter:paramID.unsignedIntValue];
  }
  return YES;
}

- (NSArray<KKTimingSlot *> *)timingGlobalSlots {
  return @[];
}

- (NSArray<KKTimingSlot *> *)timingSlotsForSection:(NSInteger)section {
  return @[];
}

- (NSArray<KKAnimatableProperty *> *)animatableProperties {
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

- (NSView *)holdPropertyView {
  return nil;
}

- (CGFloat)holdPropertyViewHeight {
  return 23.0;
}

- (void (^)(id, CMTime))holdPropertyApplyState {
  return nil;
}

@end
