/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKConstants.h"
#import "KKCurveDefaults.h"
#import "KKDataBlob.h"
#import "KKHostInfo.h"
#import "KKLinkBus.h"
#import "KKLog.h"
#import "KKPluginInstanceState.h"
#import <os/lock.h>

// Process-wide (all this plugin's instances share ONE XPC service process) live
// set + reconcile debounce. -pluginInstanceAddedToDocument adds each existing
// instance's uuid on document load; ~5s after the load burst settles we remove
// any manifest whose uuid never showed up (an effect deleted before this load).
static NSMutableSet<NSString *> *gKKLiveUUIDs;
static os_unfair_lock gKKLiveLock = OS_UNFAIR_LOCK_INIT;
static NSInteger gKKReconcileGen; // guarded by gKKLiveLock

#import "KKPlugin_Private.h"
#import "KKUpdateChecker.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <QuartzCore/QuartzCore.h>

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

- (void)kkInActionScope:(void (^)(void))block {
  id<FxCustomParameterActionAPI_v4> act =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act)
    return;
  [act startAction:self];
  @try {
    if (block)
      block();
  } @finally {
    // An exception escaping an open scope wedges FCP's undo machinery (its
    // next beginWithUndoState aborts) - always close.
    [act endAction:self];
  }
}

- (void)kkInParamAction:(void (^)(id<FxParameterRetrievalAPI_v6> getAPI,
                                  id<FxParameterSettingAPI_v5> setAPI,
                                  CMTime actionTime))block {
  id<PROAPIAccessing> api = self.apiManager;
  [self kkInActionScope:^{
    id<FxParameterRetrievalAPI_v6> getAPI =
        [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxCustomParameterActionAPI_v4> act =
        [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (block)
      block(getAPI, setAPI, act ? [act currentTime] : kCMTimeInvalid);
  }];
}

@synthesize motionBlurHeader = _motionBlurHeader;

+ (id)servicePrincipalDelegate {
  return [KKPrincipalDelegate shared];
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    // Sentinel for "never measured", so the first usable sample seeds the lead
    // outright instead of the smoothing crawling up from a bogus zero.
    _miniViewerPlayheadLead = -1.0;
    // Warm the parameter-link app-group container off-thread at process start,
    // so the first link resolve on the render thread doesn't stall on the ~1-2s
    // cold container lookup mid-frame. One call covers every plugin (each
    // FxPlug instance is its own XPC process); a no-op when nothing links.
    [KKLinkBus warmUp];
    // Scope the saved curve default to this plugin (Canvas and Mirage keep
    // their own), so intervals created in this process start at the user's
    // shape rather than the built-in EaseInOut.
    KKDefaultsSetActiveScope([self presetPluginKey]);
  }
  return self;
}

- (NSString *)presetPluginKey {
  return [NSBundle bundleForClass:[self class]].bundleIdentifier
             ?: NSStringFromClass([self class]);
}

- (NSArray<KKLane *> *)linkableLanesForManifest {
  return nil; // opt-out by default; a plugin opts in by overriding
}

- (NSArray<KKLinkLayerSource *> *)linkableLayersForManifest {
  return nil; // flat source by default; layered plugins (Canvas) override
}

- (NSString *)linkManifestEffectName {
  NSString *n =
      [NSBundle bundleForClass:[self class]].infoDictionary[@"CFBundleName"];
  return n.length ? n : NSStringFromClass([self class]);
}

- (NSString *)linkManifestDisplayName {
  return [self linkManifestEffectName]; // no per-instance name by default
}

// One serial queue per process for every publish this plugin makes. Serial so
// two ticks can never interleave their writes to the same manifest file (and so
// the "last signature wins" order the gate establishes on the render thread is
// the order the bus sees); background because nothing here needs the render
// thread - the bus is file-based pub/sub that other clips poll, so a few
// milliseconds of publish latency is invisible.
static dispatch_queue_t KKLinkPublishQueue(void) {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    q = dispatch_queue_create("co.overpolish.keyframeless.link-publish",
                              dispatch_queue_attr_make_with_qos_class(
                                  DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  });
  return q;
}

static const double kKKLinkRepublishSeconds = 10.0;

- (BOOL)shouldPublishLinkManifestForSignature:(NSString *)signature {
  double now = CACurrentMediaTime();
  BOOL changed = ![signature isEqualToString:self.linkPublishSignature];
  BOOL stale = self.linkPublishTimeMono <= 0.0 ||
               (now - self.linkPublishTimeMono) > kKKLinkRepublishSeconds;
  if (!changed && !stale)
    return NO;
  self.linkPublishSignature = signature;
  self.linkPublishTimeMono = now;
  return YES;
}

- (void)writeLinkManifest {
  if ([self linkableLanesForManifest] == nil &&
      [self linkableLayersForManifest] == nil)
    return; // not a link source - don't re-enter the host to find that out
  id<FxTimingAPI_v4> t =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!t)
    return;
  CMTime effStart = kCMTimeZero, dur = kCMTimeZero, effStartTL = kCMTimeZero;
  [t startTimeForEffect:&effStart];
  [t durationTimeForEffect:&dur];
  [t timelineTime:&effStartTL fromInputTime:effStart];
  [self writeLinkManifestWithClipStartSec:CMTimeGetSeconds(effStartTL)
                              durationSec:CMTimeGetSeconds(dur)];
}

- (void)writeLinkManifestWithClipStartSec:(double)tlStart
                              durationSec:(double)durSec {
  NSArray<KKLane *> *lanes = [self linkableLanesForManifest];
  NSArray<KKLinkLayerSource *> *layers = [self linkableLayersForManifest];
  if (lanes == nil && layers == nil)
    return; // not a link source
  // CMTimeGetSeconds returns NaN for an INVALID CMTime, and the timing API
  // hands one back when this fires before the clip is fully placed (applying
  // by DOUBLE-CLICK in the effects browser hits this; a drag-apply does not).
  // NaN fails every comparison, so `durSec <= 0.0` waves it through, and the
  // NaN reaches NSJSONSerialization in the manifest writer, which RAISES on a
  // non-finite number. Uncaught, that kills the XPC process, and FCP then
  // aborts in POOnScreenControl hitCheckWithViewCoords: against the dead
  // connection on the next mouse move. Test finiteness explicitly.
  if (!isfinite(durSec) || !isfinite(tlStart)) {
    KKLogWarn(@"KKPlugin: link manifest skipped, timing not ready "
              @"(dur %f, tlStart %f)",
              durSec, tlStart);
    return;
  }
  if (durSec <= 0.0)
    return;
  // Everything the host has to answer is resolved HERE, inside the callback:
  // the instance uuid (a parameter read, memoized per api object) and the
  // document id (an FxProjectAPI call, memoized per uuid). Both are near-free
  // after the first tick, and neither is legal off this thread. What follows
  // them - assembling the manifest, serializing every referenceable lane into
  // its own curve file, and the writes - touches no FxPlug API at all, so it
  // goes to the publish queue.
  NSString *uuid = KKInstanceUUIDForAPI(self.apiManager);
  if (uuid.length == 0)
    return; // no identity yet (fresh instance before any UI) - skip
  NSString *documentID = KKLinkDocumentIDForAPI(self.apiManager);
  NSString *effectName = [self linkManifestEffectName];
  NSString *displayName = [self linkManifestDisplayName];
  dispatch_async(KKLinkPublishQueue(), ^{
    if (layers != nil) {
      KKLinkWriteManifestWithLayersForUUID(uuid, documentID, lanes ?: @[],
                                           layers, tlStart, durSec, effectName,
                                           displayName);
      // Publish each layer's actual curves so a `${uuid.layerID.label}`
      // reference on another clip resolves.
      for (KKLinkLayerSource *layer in layers)
        KKLinkPublishReferenceableLayerForUUID(uuid, layer, tlStart,
                                               tlStart + durSec);
      if (lanes.count)
        KKLinkPublishReferenceableLanesForUUID(uuid, lanes, tlStart,
                                               tlStart + durSec);
      return;
    }
    KKLinkWriteManifestForUUID(uuid, documentID, lanes, tlStart, durSec,
                               effectName, displayName);
    // Publish the same lanes' actual curves so a `${uuid.label}` reference on
    // another clip resolves (the manifest only advertises the label set).
    KKLinkPublishReferenceableLanesForUUID(uuid, lanes, tlStart,
                                           tlStart + durSec);
  });
}

// FxPlug's ADD signal (FxTileableEffect, @optional): fires when this instance
// becomes part of the document - on ADD and on every document LOAD, once per
// existing instance as it deserializes. There is NO removal counterpart in the
// SDK (verified: FCP never tells a plugin an effect was deleted, and pins the
// instance for undo so no teardown fires either). Treat the load-time burst of
// uuids as the set of LIVE effects - anything on the bus that isn't in it was
// deleted before this load, so reconcile drops it. In-session deletes can't be
// caught (no signal); they clear on the next reopen, or via the manual "Remove
// from list".
//
// Do NOT publish a manifest from this callback, including from a deferred main
// queue block. Publishing resolves FxProjectAPI -documentID: synchronously.
// During a long document load FCP can begin waiting for this XPC instance while
// still holding the project lock needed to answer that call, deadlocking both
// processes. A next-turn or fixed-delay dispatch only makes the race rarer.
// Mirage and Canvas publish from their render callbacks instead, where the host
// has established the FxPlug transaction that permits the synchronous query.
- (void)pluginInstanceAddedToDocument {
  NSString *uuid = KKInstanceUUIDForAPI(self.apiManager);
  if (uuid.length == 0)
    return;

  // Debounce a reconcile ~5s after the LAST add of this load burst: any
  // manifest for THIS effect whose uuid isn't in the live set by then belonged
  // to a deleted effect (it never deserialized), so drop it. Scoped by effect
  // name so one plugin never prunes another plugin's manifests. No staleness ->
  // idle effects, which DO fire this callback on load, are never touched.
  //
  // The generation bump takes the live set's lock rather than standing alone:
  // FxPlug delivers this callback on a CONCURRENT queue (one per instance
  // during a load burst), so an unsynchronised ++ raced both its peers and the
  // read below. Bumping it in the same critical section as the insert also
  // makes "uuid is live" and "generation N" one atomic step, which is the real
  // invariant - a generation only means anything paired with the set it was
  // taken against.
  NSString *effectName = [self linkManifestEffectName];
  os_unfair_lock_lock(&gKKLiveLock);
  if (!gKKLiveUUIDs)
    gKKLiveUUIDs = [NSMutableSet set];
  [gKKLiveUUIDs addObject:uuid];
  NSInteger gen = ++gKKReconcileGen;
  os_unfair_lock_unlock(&gKKLiveLock);

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        // Generation check and set snapshot under ONE acquisition: read apart,
        // a later add landing between them would pass the check and then hand
        // reconcile a set from a different generation.
        os_unfair_lock_lock(&gKKLiveLock);
        BOOL superseded = (gen != gKKReconcileGen);
        NSSet<NSString *> *live = superseded ? nil : [gKKLiveUUIDs copy];
        os_unfair_lock_unlock(&gKKLiveLock);
        if (superseded)
          return; // a later add is still arriving; its timer does the work
        [KKLinkBus reconcileEffectName:effectName keepingUUIDs:live];
      });
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
  return [self encodeRenderCommandsForDestinationImage:destinationImage
                                          sourceImages:sourceImages
                                                 setup:nil
                                              commands:commands];
}

- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                               sourceImages:
                                   (NSArray<FxImageTile *> *)sourceImages
                                      setup:(void (^)(id<MTLCommandBuffer>
                                                          commandBuffer))setup
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           NSArray<id<MTLTexture>>
                                               *inputTextures))commands {
  return [self encodeRenderCommandsForDestinationImage:destinationImage
                                          sourceImages:sourceImages
                                          commandQueue:nil
                                                 setup:setup
                                              commands:commands];
}

- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                               sourceImages:
                                   (NSArray<FxImageTile *> *)sourceImages
                               commandQueue:(id<MTLCommandQueue>)suppliedQueue
                                      setup:(void (^)(id<MTLCommandBuffer>
                                                          commandBuffer))setup
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
      suppliedQueue
          ?: [cache commandQueueWithRegistryID:registryID
                                   pixelFormat:pixelFormat];
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

  // Input preparation rides this buffer, ahead of the render encoder below.
  if (setup)
    setup(commandBuffer);

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
  // The one mandatory round trip: FxPlug requires the destination filled before
  // the render callback returns. On a supplied queue this also drains whatever
  // the caller committed ahead of it.
  [commandBuffer waitUntilCompleted];

  if (!suppliedQueue)
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
          [NSError errorWithDomain:@"com.keyframeless"
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

- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline {
  if (!timeline)
    return timeline;
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime dur = kCMTimeZero;
  [timingAPI durationTimeForEffect:&dur];
  double durSec = CMTimeGetSeconds(dur);
  if (durSec <= 0)
    return timeline;
  KKTimeline *out = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [out.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *l = [lanes[i] copy];
    l.lastKnownClipDuration = durSec;
    lanes[i] = l;
  }
  out.lanes = lanes;
  return out;
}

- (BOOL)forceShowAllParameters {
  return NO;
}

// FxPlug requires this when the plugin uses custom parameters - FCP needs
// the value classes ahead of unarchiving project files. Subclasses can
// override and call super to add their own custom-param IDs.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kKKParamTimelineData ||
      parameterID == kKKParamMotionBlurData ||
      parameterID == kKKParamGradientData ||
      parameterID == kKKParamColorExpanded ||
      parameterID == kKKParamMotionBlurExpanded ||
      parameterID == kKKParamMotionBlurEnabled)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [NSSet set];
}

@end

FxImageTile *KKImageTileForParameterID(NSArray<FxImageTile *> *sourceImages,
                                       UInt32 parameterID) {
  for (FxImageTile *tile in sourceImages) {
    if (tile.imageSource == kFxImageTileRequestSourceParameter &&
        tile.parameterID == parameterID)
      return tile;
  }
  return nil;
}
