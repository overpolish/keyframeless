/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageCustomShader.h"
#import "MirageDirectives.h" // MirageCommonDefault + the #motionblur mode
#import "MirageRack.h"
#import "MirageStateBlob.h"
#import "MirageSurfaceResponse.h"
#import "Plugin+Render_Internal.h"

#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>

// SHADER RACK, render half. One instance, an ordered chain of entries, each
// with its own independently transpiled pipelines and its own std140 uniform
// pool - nothing is renamed and nothing is concatenated at the GLSL level.
// Chaining happens here, in the render graph: entry k draws its whole pipeline
// (gamma planning, Buffer A-D, image pass) into a cached RGBA16F intermediate,
// entry k + 1 binds that as its iChannel0, and the last enabled entry draws
// into the FxPlug destination.
//
// The intermediates carry GAMMA-ENCODED values - the same space today's source
// conversion hands a Shadertoy shader - so a chain of ordinary shaders needs no
// conversion between entries at all. A `color-transform` entry is the exception
// and states its own case at the seam (Plugin+RenderMultipass.m).
//
// Round trips are unchanged: every upstream entry COMMITS AND DOES NOT WAIT on
// the frame's one shared queue, so ordering comes from commit order alone, and
// the destination pass's mandatory wait - the frame's only one - covers the
// whole chain. The `[RenderGuard]` canary must stay silent through a chain in
// steady playback exactly as it does through a single template.

@implementation MiragePlugin (RenderRack)

static void MirageApplyRackSelectionPreview(MirageShaderModel *model,
                                            NSString *source,
                                            MiragePluginState *state) {
  NSString *key = MirageSurfaceSelectionToggleForSource(source);
  const MirageScalarProp *props = model.scalarProps;
  for (int i = 0; key.length && i < model.scalarCount; i++)
    if ([key isEqualToString:@(props[i].name)] && props[i].isBool &&
        props[i].poolOffset >= 0 &&
        props[i].poolOffset < state->colorPoolCount) {
      state->colorPool[props[i].poolOffset].x = 1.0f;
      return;
    }
}

// One entry's render. Everything the single-template path decides per frame -
// pixel scale, who owns the blur, single pass vs buffer chain - decided here
// per ENTRY, because in a rack each of those is a property of the template that
// entry is running, not of the instance.
//
// Every entry goes through the multi-pass renderer, including one with no
// Buffer sections: with all four absent it precompiles nothing, steps no sim
// range and encodes only the image pass, which is the single-pass render with
// the chain seams already in it. Two implementations of "run one template" is
// exactly what a rack cannot afford to keep in step.
- (BOOL)_renderRackEntryAtIndex:(NSInteger)index
                    pluginState:(NSData *)pluginState
                          chain:(MirageRackChainSlot *)chain
                        isFinal:(BOOL)isFinal
                     renderTime:(CMTime)renderTime
                         mediaW:(CGFloat)mediaW
                         mediaH:(CGFloat)mediaH
                     encodeSRGB:(float)encodeSRGB
               destinationImage:(FxImageTile *)destinationImage
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages {
  MirageStateBlobHeader blob =
      MirageStateBlobReadHeaderAtIndex(pluginState, index);
  MiragePluginState base = blob.base;
  NSInteger n = blob.sampleCount;
  KKMotionBlurState mbState = blob.mbState;

  NSDictionary<NSString *, NSString *> *sections =
      MirageStateBlobReadSectionsAtIndex(pluginState, index);
  NSString *common = sections[@"Common"] ?: @"";
  NSString *imageSrc = sections[@"Image"];
  if (imageSrc.length == 0)
    imageSrc = kMiragePassthroughSource;
  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  // An intermediate stores gamma, whatever the FxPlug surface is; only the
  // final entry answers to the destination's own encoding.
  float entryEncodeSRGB = isFinal ? encodeSRGB : 1.0f;

  const float pixelScale = MirageRenderScale(sourceImages);
  MirageShaderModel *pxModel = [MirageShaderModel modelForSource:imageSrc];
  KKPluginInstanceState *compareState = KKInstanceStateForAPI(self.apiManager);
  NSString *selectedEntry =
      MirageRackEntryIDOrSentinel(compareState.selectedRackEntryID);
  NSString *thisEntry = MirageStateBlobEntryIDAtIndex(pluginState, index);
  BOOL showSelection = compareState.mirageCompareSelectionEnabled &&
                       [selectedEntry isEqualToString:thisEntry];
  if (showSelection)
    MirageApplyRackSelectionPreview(pxModel, imageSrc, &base);
  MirageScalePixelProps(pxModel, base.colorPool, base.colorPoolCount,
                        pixelScale);

  KKGLSLUniforms u =
      MirageBuildUniforms(&base, mediaW, mediaH, entryEncodeSRGB);

  MirageMotionBlurMode mbMode = MirageMotionBlurModeForSource(imageSrc);
  if (mbMode == MirageMotionBlurModeNative && mbState.enabled) {
    double frameDurNative = self.renderCache.frameDurSec;
    float shutterFrac =
        frameDurNative > 0.0
            ? (float)MIN(1.0, MAX(0.0, mbState.shutterSec / frameDurNative))
            : (float)MIN(1.0, MAX(0.0, mbState.shutterSec * 60.0));
    u.transition.y = shutterFrac;
    u.transition.z = (float)mbState.sampleCount;
  }

  NSArray<NSString *> *bufSources =
      MirageBufferSourcesFromSections(sections, withCommon, NULL);

  double frameDur = self.renderCache.frameDurSec;
  NSInteger frameIndex =
      (frameDur > 0.0) ? (NSInteger)llround(base.common.time / frameDur) : -1;
  float dtPerFrame = (float)(frameDur * base.common.speed);

  // Accumulate blur belongs to the entry that owns the destination. An upstream
  // entry is encoded ONCE per frame and every sub-sample of the final entry
  // reads the same intermediate - the same approximation the buffer chain
  // already makes one level down, for the same reason: re-running the whole
  // chain per sub-sample would cost N times the frame for a smear the final
  // pass can carry.
  MiragePluginState *mpStates = NULL;
  MirageSampleUniformsBlock sampleUniforms = nil;
  KKMotionBlurState entryMB = mbState;
  if (isFinal && mbMode == MirageMotionBlurModeAccumulate && mbState.enabled &&
      n > 1) {
    mpStates = malloc(sizeof(MiragePluginState) * (size_t)n);
    if (MirageStateBlobReadStatesAtIndex(pluginState, index, mpStates, n)) {
      for (NSInteger si = 0; si < n; si++)
        if (showSelection)
          MirageApplyRackSelectionPreview(pxModel, imageSrc, &mpStates[si]);
      for (NSInteger si = 0; si < n; si++)
        MirageScalePixelProps(pxModel, mpStates[si].colorPool,
                              mpStates[si].colorPoolCount, pixelScale);
      NSInteger sampleCount = n;
      sampleUniforms = ^(NSInteger i, KKGLSLUniforms *outU,
                         const simd_float4 **outPool, int *outCount) {
        NSInteger si = i < 0 ? 0 : (i >= sampleCount ? sampleCount - 1 : i);
        const MiragePluginState *st = &mpStates[si];
        *outU = MirageBuildUniforms(st, mediaW, mediaH, entryEncodeSRGB);
        *outPool = st->colorPool;
        *outCount = st->colorPoolCount;
      };
      self.lastRenderBlurSamples = n;
    } else {
      free(mpStates);
      mpStates = NULL;
      entryMB.enabled = NO;
    }
  } else {
    entryMB.enabled = NO;
  }

  BOOL ok = [self renderCustomMultipassWithUniforms:u
                                          colorPool:base.colorPool
                                          poolCount:base.colorPoolCount
                                        imageSource:withCommon(imageSrc)
                                      bufferSources:bufSources
                                         frameIndex:frameIndex
                                         dtPerFrame:dtPerFrame
                                            mbState:entryMB
                                         renderTime:renderTime
                                     sampleUniforms:sampleUniforms
                                     transitionMode:base.transitionMode
                                              chain:chain
                                   destinationImage:destinationImage
                                       sourceImages:sourceImages];
  if (mpStates)
    free(mpStates);
  return ok;
}

- (BOOL)renderRackChainForDestinationImage:(FxImageTile *)destinationImage
                              sourceImages:
                                  (NSArray<FxImageTile *> *)sourceImages
                               pluginState:(NSData *)pluginState
                                    atTime:(CMTime)renderTime
                                    mediaW:(CGFloat)mediaW
                                    mediaH:(CGFloat)mediaH
                                encodeSRGB:(float)encodeSRGB {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return NO;
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLCommandQueue> frameQueue = [cache commandQueueWithRegistryID:registryID
                                                         pixelFormat:pf];
  if (!frameQueue)
    return NO;

  NSInteger entryCount = MirageStateBlobEntryCount(pluginState);
  // A DISABLED entry is skipped whole: no pipeline, no pass, no intermediate.
  // Whatever the chain held flows on to the next enabled entry unchanged, and
  // with every entry off that is the source clip itself.
  //
  // Decided at sample 0, the render time. The flag is carried per sub-frame
  // sample because the lane is animatable, but a chain's SHAPE cannot vary
  // within one frame - an entry cannot render for half a shutter - so the
  // frame's own instant is what selects it.
  NSMutableArray<NSNumber *> *enabled = [NSMutableArray array];
  NSMutableArray<NSString *> *entryIDs = [NSMutableArray array];
  for (NSInteger i = 0; i < entryCount; i++) {
    [entryIDs addObject:MirageStateBlobEntryIDAtIndex(pluginState, i)];
    if (MirageStateBlobEntryEnabled(pluginState, i, 0))
      [enabled addObject:@(i)];
  }

  NSMutableArray<NSString *> *shape =
      [NSMutableArray arrayWithCapacity:entryCount];
  for (NSInteger i = 0; i < entryCount; i++)
    [shape addObject:[NSString stringWithFormat:@"%@%@", entryIDs[i],
                                                [enabled containsObject:@(i)]
                                                    ? @""
                                                    : @"(skipped)"]];
  NSString *signature = [shape componentsJoinedByString:@" -> "];
  if (![signature isEqualToString:self.lastRackChainSignature]) {
    self.lastRackChainSignature = signature;
    KKLogDebug(@"[Mirage] rack chain entries=%ld enabled=%ld | %@",
               (long)entryCount, (long)enabled.count, signature);
  }

  // Every entry off: pass the clip through rather than leaving the destination
  // cleared. Encoded as one final entry running the passthrough shader, so it
  // takes the ordinary destination path and the frame keeps its single wait.
  if (enabled.count == 0) {
    MiragePluginState base;
    memset(&base, 0, sizeof(base));
    base.common = MirageCommonDefault();
    KKMotionBlurState off;
    memset(&off, 0, sizeof(off));
    KKGLSLUniforms u = MirageBuildUniforms(&base, mediaW, mediaH, encodeSRGB);
    MirageRackChainSlot *slot = [MirageRackChainSlot new];
    slot.queue = frameQueue;
    slot.surfaceLinear = (encodeSRGB == 0.0f);
    BOOL ok = [self renderCustomMultipassWithUniforms:u
                                            colorPool:base.colorPool
                                            poolCount:0
                                          imageSource:kMiragePassthroughSource
                                        bufferSources:@[ @"", @"", @"", @"" ]
                                           frameIndex:-1
                                           dtPerFrame:0.0f
                                              mbState:off
                                           renderTime:renderTime
                                       sampleUniforms:nil
                                       transitionMode:0
                                                chain:slot
                                     destinationImage:destinationImage
                                         sourceImages:sourceImages];
    [cache returnCommandQueueToCache:frameQueue];
    return ok;
  }

  self.lastRenderBlurSamples = 0;
  NSUInteger W = (NSUInteger)mediaW, H = (NSUInteger)mediaH;
  id<MTLTexture> carried = nil;
  BOOL ok = YES;
  for (NSUInteger position = 0; position < enabled.count; position++) {
    NSInteger index = enabled[position].integerValue;
    BOOL isFinal = position + 1 == enabled.count;
    NSString *entryID = entryIDs[index];
    MirageRackChainSlot *slot = [MirageRackChainSlot new];
    slot.queue = frameQueue;
    slot.entryID = entryID;
    slot.surfaceLinear = (encodeSRGB == 0.0f);
    slot.input = carried;
    if (!isFinal) {
      slot.output = [self reusableChainTextureForEntry:entryID
                                                device:device
                                                 width:W
                                                height:H];
      // No intermediate to draw into (allocation refused): stop and let this
      // entry own the destination, which is a shortened chain rather than a
      // black frame.
      if (!slot.output)
        isFinal = YES;
    }
    ok = [self _renderRackEntryAtIndex:index
                           pluginState:pluginState
                                 chain:slot
                               isFinal:isFinal
                            renderTime:renderTime
                                mediaW:mediaW
                                mediaH:mediaH
                            encodeSRGB:encodeSRGB
                      destinationImage:destinationImage
                          sourceImages:sourceImages];
    if (!ok || isFinal)
      break;
    carried = slot.output;
  }
  [cache returnCommandQueueToCache:frameQueue];
  return ok;
}

@end
