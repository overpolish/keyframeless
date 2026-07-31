/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageMiniViewerRenderer.h"
#import "MirageMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KKLog.h>

#import "Constants.h"        // MirageCustomDefaultShaderSource
#import "KKGLSLTranspiler.h" // GLSL -> MSL + channel binding
#import "MirageAudioPool.h"
#import "MirageCustomShader.h" // MirageCustomErrorShaderSource
#import "MirageDirectives.h"
#import "MirageFrameOffsets.h" // `// #frames` neighbour offsets
#import "MirageExprMiniSet.h"     // // @osc custom-handling handles
#import "MirageOSCBlockRuntime.h" // rotate blocks feed the rotation set
#import "MirageRenderUniforms.h"  // MirageMakeUniforms (shared with FCP render)
#import "MirageTypes.h"
#import "Plugin_Private.h" // +availableLanesForShaderSource:
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <math.h>
#import <simd/simd.h>

NSString *const MirageMiniViewerDescriptorPath = @"/tmp/mesh-miniviewer.json";

NSString *const MirageMiniViewerRequestPath =
    @"/tmp/mesh-miniviewer-request.json";

NSString *MirageMiniViewerDescriptorPathForUUID(NSString *uuid) {
  return KKMiniViewerFeedDescriptorPath(@"mesh", uuid);
}

NSString *MirageMiniViewerRequestPathForUUID(NSString *uuid) {
  return KKMiniViewerFeedRequestPath(@"mesh", uuid);
}

// Single-value `units="px"` lanes are authored in source-media pixels. The
// main renderer converts them to the active tile scale; do the same for the
// mini's render target so changing preview zoom cannot change their apparent
// size relative to the frame. Points and #multi pixel fields are normalized in
// lane storage and already scale themselves.
static void MirageScaleMiniPixelProps(MirageShaderModel *model,
                                      vector_float4 *pool, int poolCount,
                                      float renderW, float renderH,
                                      CGSize mediaSize) {
  if (!model || !pool || mediaSize.width <= 0.0 || mediaSize.height <= 0.0)
    return;
  float scaleX = renderW / (float)mediaSize.width;
  float scaleY = renderH / (float)mediaSize.height;
  float scale = fminf(scaleX, scaleY);
  if (!isfinite(scale) || scale <= 0.0f || scale == 1.0f)
    return;
  const MirageScalarProp *props = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++) {
    const MirageScalarProp *p = &props[i];
    if (p->isPoint || p->isMulti || p->fieldUnit[0] != 'p')
      continue;
    if (p->poolOffset < 0 || p->poolOffset >= poolCount)
      continue;
    pool[p->poolOffset].x *= scale;
  }
}

// One colour-matched `// #frames` neighbour, held across draws. The conversion
// it caches is a full-frame render pass plus an RGBA16Float allocation, and the
// pixels behind it only move when the render process pumps a new frame - so the
// work belongs to the pump, not to the redraw.
@interface _MirageNeighborConversion : NSObject
@property(nonatomic, strong) id<MTLTexture> raw;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL technicalTransform;
@property(nonatomic, strong) id<MTLTexture> converted;
@end

@implementation _MirageNeighborConversion
@end

@implementation MirageMiniViewerRenderer {
  NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;
  MTLPixelFormat _pipelineFormat;
  // Render-at-reference-resolution + downscale (so the small mini texture shows
  // a proper minified copy of a full-res render: grain, dither, everything).
  id<MTLTexture> _hiResTex;
  id<MTLRenderPipelineState> _blitPipeline;
  MTLPixelFormat _blitFormat;
  id<MTLSamplerState> _linearSampler;
  // Source last fed to -_syncMiniPointController, so the per-draw sync is a
  // cheap string compare instead of re-running the directive parse each frame.
  NSString *_pointSyncedSource;
  KKPointOSCSet *_pointSet;
  NSString *_rotSyncedSource;
  KKRotationOSCSet *_rotSet;
  MirageExprMiniSet *_exprSet;
  // Last logged `// #frames` bind state (declared count / first offset / pumped
  // count), so the diagnostic fires on a change instead of once per drawn frame.
  NSString *_neighborBindSignature;
  // Colour-matched neighbours, one entry per aux index. Same shape as the
  // _hiResTex / _pipelines caches: an ivar-held Metal object rebuilt only when
  // its key inputs change.
  NSMutableArray<_MirageNeighborConversion *> *_neighborConversions;
}

- (instancetype)init {
  if ((self = [super init]))
    self.watermarkProductID = KKLicenseProductMirage;
  return self;
}

// All point OSCs draw + drag uniformly through the KKPointOSCSet (via the
// Interaction category's extra-handle / extra-path forwards), so the base
// renderer has no single "primary" handle of its own.
- (NSString *)pointLabel {
  return nil;
}

// The generic mini-viewer should size `dest` to the pixels the preview
// actually occupies. Our normal single-sample path still renders through the
// 1080-tall fidelity intermediate in -hiResTargetForDest:, but motion-blur
// sampling deliberately skips that intermediate and renders N times straight
// into `dest`. Without this opt-in, `dest` stays at the source size (typically
// 1920x1080), turning a small inspector preview into N full-HD shader passes.
- (BOOL)prefersDisplayResolutionProcessing {
  return YES;
}

- (KKPointOSCSet *)pointSet {
  if (!_pointSet)
    _pointSet = [[KKPointOSCSet alloc] initWithRenderer:self];
  return _pointSet;
}

// Feed the set the current position lanes (the `#point osc` sugar arrives as
// `style = position` blocks from the shared runtimes). Cheap string compare
// skips the parse when the source is unchanged; the set itself no-ops when the
// label list is unchanged.
- (void)_syncMiniPointController {
  NSString *src = [self _customShaderSource] ?: @"";
  if ([src isEqualToString:_pointSyncedSource])
    return;
  _pointSyncedSource = [src copy];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  NSMutableSet<NSString *> *noSnap =
      [NSMutableSet set]; // `skipsnapping` labels
  // Blocks that remap their placement (authored toPos/fromPos), keyed by lane:
  // the mini has to apply the SAME warp as the viewer or an offset-valued
  // position lane draws here at the frame origin while the viewer draws it
  // where it belongs.
  NSMutableDictionary<NSString *, MirageOSCBlockRuntime *> *warped =
      [NSMutableDictionary dictionary];
  __weak KKMiniViewerRenderer *weakRenderer = self;
  for (MirageOSCBlockRuntime *b in
       [MirageOSCBlockRuntime runtimesForSource:src
                                          lanes:self.laneTemplates ?: @[]])
    if ([b.primitive isEqualToString:@"position"]) {
      [labels addObject:b.binds]; // uniform name = lane identity
      if (!b.snaps)
        [noSnap addObject:b.binds];
      if (b.hasForward && b.hasInverse) {
        // Without this every uniform the warp REFERENCES resolves to 0, so a
        // forward like `mid + uPosition` collapses to a constant and the handle
        // sits at a fixed wrong spot. Same provider the expr set uses.
        b.laneValueProvider = ^NSArray<NSNumber *> *(NSString *label) {
          return [weakRenderer rootValuesForLabel:label];
        };
        // `size` is the SOURCE media resolution, not the preview's - a warp
        // written against real pixels has to mean the same thing here as in
        // the viewer or the mini draws the handle somewhere else.
        b.mediaSizeProvider = ^CGSize(void) {
          return weakRenderer.canvas.sourceMediaSize;
        };
        warped[b.binds] = b;
      }
    }
  [self.pointSet setLaneLabels:labels];
  for (KKPositionMiniController *c in self.pointSet.controllers) {
    c.snapDisabled = [noSnap containsObject:c.laneLabel];
    MirageOSCBlockRuntime *b = warped[c.laneLabel];
    if (!b) {
      c.laneToObjectWarp = nil;
      c.objectToLaneWarp = nil;
      continue;
    }
    c.laneToObjectWarp = ^simd_float2(simd_float2 lane, double fraction) {
      CGSize mediaSize = weakRenderer.canvas.sourceMediaSize;
      double aspect =
          mediaSize.height > 0.0 ? mediaSize.width / mediaSize.height : 1.0;
      KKExprVal bound = {{lane.x, lane.y, 0, 0}, 2};
      return [b objectPointForBound:bound
                             aspect:aspect
                              mouse:(simd_float2){0, 0}
                          haveMouse:NO
                           fraction:fraction];
    };
    c.objectToLaneWarp = ^simd_float2(simd_float2 obj, double fraction) {
      CGSize mediaSize = weakRenderer.canvas.sourceMediaSize;
      double aspect =
          mediaSize.height > 0.0 ? mediaSize.width / mediaSize.height : 1.0;
      KKExprVal now = {{obj.x, obj.y, 0, 0}, 2};
      KKExprVal v = [b inverseBoundForObjectMouse:obj
                                         boundNow:now
                                           aspect:aspect
                                         fraction:fraction];
      return (simd_float2){(float)v.v[0], (float)v.v[1]};
    };
  }
}

- (KKRotationOSCSet *)rotSet {
  if (!_rotSet)
    _rotSet = [[KKRotationOSCSet alloc] initWithRenderer:self];
  return _rotSet;
}

- (MirageExprMiniSet *)exprSet {
  if (!_exprSet)
    _exprSet = [[MirageExprMiniSet alloc] initWithRenderer:self];
  return _exprSet;
}

// Feed the expr set the shader's current `// @osc` blocks. It parses + compiles
// via the shared MirageOSCBlockRuntime (its own cheap string-compare no-op).
// Seeds from lanes derived FRESH from the current source (not the createView
// laneTemplates snapshot, which goes stale on a code edit) so a box readout's
// per-component units track live `units={}` changes, matching the viewer.
- (void)_syncMiniExprController {
  NSString *src = [self _customShaderSource];
  NSArray<KKLane *> *lanes =
      src.length ? [MiragePlugin availableLanesForShaderSource:src]
                 : (self.laneTemplates ?: @[]);
  [self.exprSet syncWithSource:src lanes:lanes];
}

// The KKRotationAxes bitmask for a rotate block's `axes = x y z` subset
// (default Z), matching the viewer's mapping.
static NSInteger MirageMiniRotationAxesForNames(NSString *axes);

// Feed the rotation set the shader's current `osc={..}` lanes: one spec per
// rotate directive (label + active-axis bitmask + clip-centre). Cheap string
// compare skips the parse when the source is unchanged.
- (void)_syncMiniRotController {
  NSString *src = [self _customShaderSource] ?: @"";
  if ([src isEqualToString:_rotSyncedSource])
    return;
  _rotSyncedSource = [src copy];
  NSMutableArray<NSDictionary<NSString *, id> *> *rots = [NSMutableArray array];
  if (src.length) {
    // Rotate blocks (the `osc={..}` sugar included) feed the spec-driven set,
    // keyed on their LANE label like the viewer gizmo. The two standard
    // `center =` shapes map onto the spec: a bare uniform name is a live link,
    // anything else evaluates once to a constant centre.
    __weak typeof(self) weakRenderer = self;
    for (MirageOSCBlockRuntime *b in
         [MirageOSCBlockRuntime runtimesForSource:src
                                            lanes:self.laneTemplates ?: @[]]) {
      if (![b.primitive isEqualToString:@"rotate"])
        continue;
      // Every uniform the centre expression REFERENCES resolves through this
      // provider; without it they all read 0, so Magic Move's
      // `uPosition + uAnchor - vec2(0.5)` collapsed to a constant -0.5,-0.5 and
      // put the rings half a frame off the top-left corner. The point + expr
      // sets already wire the same pair - this path was the one that didn't.
      b.laneValueProvider = ^NSArray<NSNumber *> *(NSString *label) {
        return [weakRenderer rootValuesForLabel:label];
      };
      b.mediaSizeProvider = ^CGSize(void) {
        return weakRenderer.canvas.sourceMediaSize;
      };
      NSString *centerSrc = [b.centerSource
          stringByTrimmingCharactersInSet:NSCharacterSet
                                              .whitespaceCharacterSet];
      BOOL isBareIdentifier =
          centerSrc.length &&
          [centerSrc
              rangeOfCharacterFromSet:
                  [[NSCharacterSet
                      characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX"
                          @"YZ0123456789_"] invertedSet]]
                  .location == NSNotFound;
      // A bare LOCAL (`center = cardCenter`) looks syntactically identical to
      // a bare uniform. Only classify it as the cheap live-link form when it
      // is actually a lane; otherwise evaluate the complete block per draw so
      // its locals and referenced lanes remain live.
      BOOL isLink = NO;
      if (isBareIdentifier)
        for (KKLane *lane in self.laneTemplates)
          if ([lane.key isEqualToString:centerSrc]) {
            isLink = YES;
            break;
          }
      simd_float2 c = {0.5f, 0.5f};
      if (centerSrc.length && !isLink)
        c = [b centerObjectForBound:KKExprScalar(0) aspect:1.0];
      NSMutableDictionary<NSString *, id> *spec = [@{
        @"label" : b.binds,
        @"axes" : @((int)MirageMiniRotationAxesForNames(b.axes)),
        @"centerX" : @(c.x),
        @"centerY" : @(c.y),
        @"linkLabel" : isLink ? centerSrc : @"",
      } mutableCopy];
      // An expression centre (anything but a bare uniform name) depends on the
      // lane's CURRENT value, so the constant baked above - evaluated against a
      // zero bound, since the spec is built once per source change - is only a
      // fallback. Resolve it per draw against the live root value, the same way
      // the ring blocks do, or the gizmo lands wherever a zero value maps to
      // (Magic Move put it half a canvas off the top-left corner).
      if (centerSrc.length && !isLink) {
        __weak typeof(self) weakSelf = self;
        MirageOSCBlockRuntime *rt = b;
        spec[@"centerFractionBlock"] = ^CGPoint(CGRect cr) {
          __strong typeof(weakSelf) self = weakSelf;
          if (!self)
            return CGPointMake(0.5, 0.5);
          double aspect =
              cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
          KKExprVal bound =
              [rt boundValueFromLaneValues:[self rootValuesForLabel:rt.binds]];
          simd_float2 oc = [rt centerObjectForBound:bound aspect:aspect];
          return CGPointMake(oc.x, oc.y);
        };
      }
      [rots addObject:spec];
    }
  }
  [self.rotSet setRotations:rots];
}

// The KKRotationAxes bitmask for a rotate block's `axes = x y z` subset
// (default Z), matching the viewer's mapping.
static NSInteger MirageMiniRotationAxesForNames(NSString *axes) {
  NSString *lower = axes.lowercaseString;
  NSInteger m = 0;
  if ([lower containsString:@"x"])
    m |= KKRotationAxisX;
  if ([lower containsString:@"y"])
    m |= KKRotationAxisY;
  if ([lower containsString:@"z"])
    m |= KKRotationAxisZ;
  return m ?: KKRotationAxisZ;
}

- (KKLane *)templateLaneForLabel:(NSString *)label {
  for (KKLane *l in self.laneTemplates)
    if ([l.key isEqualToString:label])
      return l;
  return [super templateLaneForLabel:label];
}

// No crop box in the mini viewer.
- (NSString *)cropLabel {
  return nil;
}

// Match the viewer's `#point osc` handle (KKPositionOSC draws an arc), so the
// mini-viewer point control looks the same as the on-screen one.
- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}

// (pointHandleSizeScale: the base's KKOSCAnchorDotScale default already
// matches the dot family - no override needed.)
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  // The plugin is Custom-only now; only the shared lanes have defaults here.
  if ([label isEqualToString:@"Speed"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SPEED) ];
  if ([label isEqualToString:@"Seed"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SEED) ];
  if ([label isEqualToString:@"Grain"])
    return @[ @(KK_CORE_GRAIN_DEFAULT * 100.0) ];
  if ([label isEqualToString:@"Grain Size"])
    return @[ @(KK_CORE_GRAINSIZE_DEFAULT) ];

  // Dynamic props declared by the shader. Right after a paste the timeline
  // isn't seeded with these lanes yet, so valuesForLabel lands here. Return the
  // shader-DECLARED default (not super's @[@0], which would drive a `// #float`
  // uniform to 0 and flatten the preview) so the mini matches the first render.
  NSString *src = [self _customShaderSource];
  MirageShaderModel *model = [MirageShaderModel modelForSource:src];
  const MirageScalarProp *sp = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++)
    if ([label isEqualToString:@(sp[i].name)]) { // uniform name = identity
      if (sp[i].isPoint)
        return @[ @(sp[i].pdefx), @(sp[i].pdefy) ];
      if (sp[i].isMulti) {
        NSMutableArray<NSNumber *> *d = [NSMutableArray array];
        for (int k = 0; k < sp[i].fieldCount && k < 4; k++)
          [d addObject:@(sp[i].mdef[k])];
        return d;
      }
      return @[ @(sp[i].isChoice ? (double)sp[i].cdefault : sp[i].fdefault) ];
    }

  // Colour props resolve their default exactly the way -fillColorPool: does
  // when handed no value: the shader's AUTHORED `default=` colours first, the
  // generic palette only for a prop that declared none. The render reaches that
  // fallback by passing nil (no lane => no value), but the mini answers every
  // lookup from here, so returning the palette unconditionally OVERRODE the
  // template's own colours - the preview showed purple/pink for any prop whose
  // lane the timeline hadn't been seeded with yet, i.e. every prop right after
  // a template switch.
  const MirageColorProp *cp = model.colorProps;
  for (int i = 0; i < model.colorCount; i++) {
    NSString *lbl = @(cp[i].name); // uniform name = identity
    if (!cp[i].isArray) {
      if ([label isEqualToString:lbl]) {
        const float *d = cp[i].hasDefColors ? cp[i].defColors[0]
                                            : kMirageDefaultPalette[i % 10];
        return @[ @(d[0]), @(d[1]), @(d[2]), @(d[3]) ];
      }
      continue;
    }
    if ([label isEqualToString:[NSString stringWithFormat:@"%@ Count", lbl]])
      return @[ @(cp[i].defaultCount) ];
    for (int n = 1; n <= cp[i].maxCount; n++)
      if ([label
              isEqualToString:[NSString stringWithFormat:@"%@ %d", lbl, n]]) {
        const float *d = (cp[i].hasDefColors && n - 1 < cp[i].defColorCount)
                             ? cp[i].defColors[n - 1]
                             : kMirageDefaultPalette[(n - 1) % 10];
        return @[ @(d[0]), @(d[1]), @(d[2]), @(d[3]) ];
      }
  }
  return [super defaultValuesForLabel:label];
}

// The Custom type's user shader source from the timeline's "Mirage" code lane
// (the default plasma when empty), mirroring the FCP render read.
- (NSString *)_customShaderSource {
  KKLane *shaderLane = nil;
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.key isEqualToString:kMirageCodeLaneLabel]) {
      shaderLane = lane;
      break;
    }
  if (shaderLane.codeString.length)
    return shaderLane.codeString;
  if (!shaderLane)
    // Fresh instance: timeline not yet seeded. Mirror the FCP render and use
    // the baked plasma default so the mini matches. A present-but-empty
    // codeString means the user cleared it => passthrough.
    return MirageCustomDefaultShaderSource();
  return @"void mainImage(out vec4 O, in vec2 fc){ O = "
         @"texture(iChannel0, fc / iResolution.xy); }"; // passthrough when
                                                        // empty
}

// All Custom sections from the Mirage lane: Image (codeString) + non-empty
// extra tabs (Common / Buffer A-D) by name. Mirrors the FCP render's blob
// sections.
- (NSDictionary<NSString *, NSString *> *)_customSections {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  KKLane *shaderLane = nil;
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.key isEqualToString:kMirageCodeLaneLabel]) {
      shaderLane = lane;
      break;
    }
  if (!shaderLane) {
    // Fresh instance: seed the baked plasma default (mirrors the FCP render).
    out[@"Image"] = MirageCustomDefaultShaderSource();
    return out;
  }
  if (shaderLane.codeString.length)
    out[@"Image"] = shaderLane.codeString;
  for (NSDictionary *t in shaderLane.codeTabs) {
    NSString *n = t[@"name"], *c = t[@"code"];
    if ([n isKindOfClass:[NSString class]] &&
        [c isKindOfClass:[NSString class]] && c.length)
      out[n] = c;
  }
  return out;
}

// Runtime-compiled pipeline for a Custom shader: the GLSL is
// transpiled to MSL via glslang + SPIRV-Cross (the same shared, memoised path
// as the FCP render), then cached in _pipelines on the emitted MSL hash.
// Returns nil (logged) on failure; the caller falls back to the error pattern.
- (id<MTLRenderPipelineState>)_customPipelineForDevice:(id<MTLDevice>)device
                                           pixelFormat:(MTLPixelFormat)format
                                                source:(NSString *)userSource
                                            bufferMode:(BOOL)bufferMode {
  KKGLSLTranspileResult *tr = bufferMode ? KKTranspileGLSLBuffer(userSource)
                                         : KKTranspileGLSL(userSource);
  if (!tr.msl) {
    KKLogError(@"MirageMiniViewerRenderer: GLSL transpile failed: %@",
               tr.errorLog);
    return nil;
  }
  if (_pipelineFormat != format) {
    _pipelines = nil;
    _pipelineFormat = format;
  }
  if (!_pipelines)
    _pipelines = [NSMutableDictionary dictionary];
  NSString *key = [NSString stringWithFormat:@"custom:%@", tr.mslDigest];
  id<MTLRenderPipelineState> existing = _pipelines[key];
  if (existing)
    return existing;
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:tr.msl
                                            options:nil
                                              error:&err];
  if (!lib) {
    KKLogError(@"MirageMiniViewerRenderer: custom MSL compile failed: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:tr.vertexName];
  pd.fragmentFunction = [lib newFunctionWithName:tr.fragmentName];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"MirageMiniViewerRenderer: custom pipeline failed: %@", err);
    return nil;
  }
  _pipelines[key] = ps;
  return ps;
}

// A cached reference-resolution (1080-tall, dest aspect) intermediate render
// target, or nil when `dest` is already tall enough that rendering direct is
// fine. The type is rendered into this at full resolution and then downscaled
// into the small mini texture, so grain / dither / any resolution-dependent
// effect looks like a proper minified copy of the FCP render.
- (id<MTLTexture>)hiResTargetForDest:(id<MTLTexture>)dest {
  // Motion blur re-renders this N times per preview frame, and at 1080 that
  // made each sample as expensive as a full render tick. The intermediate only
  // buys correct MINIFICATION of grain / dither, which the blur's averaging
  // destroys anyway, so skip it while sampling. Mirage can't use the Fast
  // (velocity) technique - an arbitrary GLSL shader has no analytic velocity -
  // so the sample path has to be affordable on its own.
  if (self.previewMotionBlurSampling)
    return nil;
  NSUInteger dh = dest.height;
  const NSUInteger refH = 1080;
  if (dh == 0 || dh >= refH)
    return nil; // already high enough, render straight in
  NSUInteger refW = (NSUInteger)llround((double)refH * dest.width / (double)dh);
  if (refW < 1)
    refW = 1;
  if (!_hiResTex || _hiResTex.width != refW || _hiResTex.height != refH ||
      _hiResTex.pixelFormat != dest.pixelFormat) {
    // Mipmapped so the down-blit can area-average the whole minification
    // footprint (trilinear) instead of a single bilinear tap. Without this a
    // fine per-channel dither aliases into chroma speckle when shrunk.
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:dest.pixelFormat
                                     width:refW
                                    height:refH
                                 mipmapped:YES];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _hiResTex = [dest.device newTextureWithDescriptor:td];
  }
  return _hiResTex;
}

- (id<MTLRenderPipelineState>)blitPipelineForDevice:(id<MTLDevice>)device
                                             format:(MTLPixelFormat)format {
  if (_blitPipeline && _blitFormat == format)
    return _blitPipeline;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib)
    return nil;
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"meshBlitVertex"];
  pd.fragmentFunction = [lib newFunctionWithName:@"meshBlitFragment"];
  pd.colorAttachments[0].pixelFormat = format;
  _blitPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
  _blitFormat = format;
  if (!_blitPipeline)
    KKLogError(@"MirageMiniViewerRenderer: blit pipeline failed: %@", err);
  return _blitPipeline;
}

- (id<MTLSamplerState>)linearSamplerForDevice:(id<MTLDevice>)device {
  if (_linearSampler)
    return _linearSampler;
  MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.mipFilter = MTLSamplerMipFilterLinear; // trilinear: area-average on shrink
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  _linearSampler = [device newSamplerStateWithDescriptor:sd];
  return _linearSampler;
}

// Downscale the reference-res intermediate into the mini dest with linear
// filtering (averages the fine grain instead of showing raw coarse pixels).
- (void)blitFrom:(id<MTLTexture>)src
             into:(id<MTLTexture>)dest
    commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  id<MTLRenderPipelineState> bp = [self blitPipelineForDevice:dest.device
                                                       format:dest.pixelFormat];
  if (!bp)
    return;
  // Build the mip chain so the trilinear sampler averages the full footprint.
  if (src.mipmapLevelCount > 1) {
    id<MTLBlitCommandEncoder> mip = [commandBuffer blitCommandEncoder];
    [mip generateMipmapsForTexture:src];
    [mip endEncoding];
  }
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [e setRenderPipelineState:bp];
  [e setFragmentTexture:src atIndex:0];
  [e setFragmentSamplerState:[self linearSamplerForDevice:dest.device]
                     atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
}

// The mini feed publishes the source sRGB-encoded (KKMiniViewerFeed writes
// FCP's linear source through a BGRA8_sRGB texture), so a plain BGRA8 read
// samples GAMMA. Return an _sRGB-typed view of the same IOSurface so sampling
// returns LINEAR, matching the main render (which samples FCP's linear source).
// Falls back to `source` when it has no backing IOSurface or isn't plain BGRA8.
- (id<MTLTexture>)_linearSourceView:(id<MTLTexture>)source {
  if (!source.iosurface || source.pixelFormat != MTLPixelFormatBGRA8Unorm)
    return source;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                   width:source.width
                                  height:source.height
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> v = [source.device newTextureWithDescriptor:d
                                                   iosurface:source.iosurface
                                                       plane:0];
  return v ?: source;
}

// The `// #frames` neighbour textures to bind for `source`, in DIRECTIVE order.
//
// Call this BEFORE opening any render encoder on `commandBuffer`: matching a
// neighbour's colour to iChannel0 encodes its own render pass, exactly like the
// srcLin / toLin conversions this sits beside, and a command buffer permits one
// live encoder at a time.
//
// The conversions are CACHED per aux index and reused until the render process
// pumps a new frame. A drag redraws the mini many times against neighbours that
// cannot have changed, and each conversion is a full-frame pass plus an
// RGBA16Float allocation - multiplied by the filmstrip's slot count, since the
// effect pass runs once per slot. Reconverting per redraw was the mini's lag on
// a `#frames` shader.
//
// The render process pumps the neighbours it resolved into the feed's auxiliary
// textures, so a trails / echo / temporal shader previews on the real frames.
// Between FCP renders the last pumped set stays - tuning on a parked playhead
// has to keep previewing, so nothing here invalidates them.
//
// Three deterministic fallbacks, all of which return a short/empty array that
// KKBindCustomNeighborTextures fills with the caller's current-frame fallback
// (skipping the bind is not an option: a declared-but-unbound sampler aborts
// under Metal API Validation):
//   - the shader declares no offsets, so there is nothing to bind;
//   - nothing pumped yet (cold boot, or a shader without `// #frames`);
//   - the pumped count disagrees with the directive, which is a pump from
//     before a directive edit - clamping is wrong-but-stable, mis-indexing
//     would show frames the shader never asked for.
- (NSArray *)_neighborTexturesForSource:(NSString *)source
                     technicalTransform:(BOOL)technicalTransform
                          commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  MirageFrameOffsets fo = MirageFrameOffsetsForSource(source, NULL);
  if (fo.count <= 0)
    return @[];
  NSUInteger available = self.canvas.auxTextureCount;
  NSString *signature =
      [NSString stringWithFormat:@"%d/%+d/%lu", fo.count, fo.offsets[0],
                                 (unsigned long)available];
  if (![signature isEqualToString:_neighborBindSignature]) {
    _neighborBindSignature = [signature copy];
    KKLogDebug(@"[Mirage] mini bind neighbours declared=%d firstOffset=%+d "
               @"pumped=%lu",
               fo.count, fo.offsets[0], (unsigned long)available);
  }
  if (available != (NSUInteger)fo.count)
    return @[];
  if (!_neighborConversions)
    _neighborConversions = [NSMutableArray array];
  while (_neighborConversions.count < available)
    [_neighborConversions addObject:[[_MirageNeighborConversion alloc] init]];
  while (_neighborConversions.count > available)
    [_neighborConversions removeLastObject];

  NSMutableArray *out = [NSMutableArray arrayWithCapacity:available];
  for (NSUInteger i = 0; i < available; i++) {
    id<MTLTexture> raw = [self.canvas auxTextureAtIndex:i];
    _MirageNeighborConversion *entry = _neighborConversions[i];
    if (!raw) {
      entry.raw = nil;
      entry.converted = nil;
      [out addObject:[NSNull null]];
      continue;
    }
    // Keyed on the PUBLISHER's generation as well as the texture object: the
    // feed writes each new frame into the same IOSurface, so the wrapper object
    // alone would report "unchanged" forever and the preview would freeze on
    // the first pumped neighbours.
    uint64_t generation = [self.canvas auxTextureGenerationAtIndex:i];
    if (entry.converted && entry.raw == raw && entry.generation == generation &&
        entry.technicalTransform == technicalTransform) {
      [out addObject:entry.converted];
      continue;
    }
    // The same colour handling iChannel0 gets a few lines above, so a temporal
    // blend mixes like values: the feed's surface is display-encoded, so read
    // it linearly, then re-encode to gamma for an ordinary Shadertoy shader.
    id<MTLTexture> tex = [self _linearSourceView:raw];
    if (!technicalTransform)
      tex = KKGammaEncodeSourceTextureOnBuffer(commandBuffer, tex) ?: tex;
    entry.raw = raw;
    entry.generation = generation;
    entry.technicalTransform = technicalTransform;
    // Written by THIS command buffer and read by later ones. Safe without a
    // fence: every mini draw commits on the one view queue, and command buffers
    // on a queue execute in commit order. Metal retains a resource for as long
    // as any encoded buffer references it, so replacing the entry cannot pull a
    // texture out from under a frame still in flight.
    entry.converted = tex;
    [out addObject:tex ?: (id)[NSNull null]];
  }

  return out;
}

// Custom mini render: Buffer A-D render into offscreen RGBA16F textures on the
// shared command buffer, then the Image pass draws into the hi-res intermediate
// (downscaled to dest). Mirrors the FCP render's multi-pass routing
// (iChannelN->Buffer[N], source/noise fallback); Common is prepended to each. A
// FEEDBACK shader (a buffer reading itself / a later buffer) re-simulates a
// short window at capped resolution so the static preview accumulates; others
// do a single full-res step. The mini keeps no state across renders (unlike the
// FCP render), so this is an approximate preview, not a frame-exact match.
- (BOOL)_encodeCustomEffectFromSource:(id<MTLTexture>)source
                                 into:(id<MTLTexture>)dest
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  id<MTLDevice> device = dest.device;
  NSDictionary<NSString *, NSString *> *sections = [self _customSections];
  NSString *common = sections[@"Common"] ?: @"";
  NSString *image = sections[@"Image"];
  if (image.length == 0)
    image = @"void mainImage(out vec4 O, in vec2 fc){ O = "
            @"texture(iChannel0, fc / iResolution.xy); }"; // passthrough
  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  id<MTLTexture> renderTex = [self hiResTargetForDest:dest];
  BOOL downscale = (renderTex != nil);
  if (!renderTex)
    renderTex = dest;
  MTLPixelFormat fmt = renderTex.pixelFormat;
  float W = (float)renderTex.width, H = (float)renderTex.height;
  int encodeSRGB = (dest.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                    dest.pixelFormat == MTLPixelFormatBGRA8Unorm)
                       ? 1
                       : 0;
  // Match the FCP render's iTime, which uses seconds (frac * durSec), not the
  // bare 0..1 fraction - otherwise the preview animates durSec-times too slow.
  // Fall back to the raw fraction when the duration hasn't been pushed yet.
  float timeSec = (float)(self.editFraction * (self.clipDurationSeconds > 0.0
                                                   ? self.clipDurationSeconds
                                                   : 1.0));
  NSArray<NSNumber *> *seedV = [self valuesForLabel:@"Seed"];
  float seed = seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
  NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
  float speed =
      speedV.count ? speedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;
  float iTime = timeSec * speed + fmodf(seed, 10000.0f);
  NSArray<NSNumber *> *grV = [self valuesForLabel:@"Grain"];
  NSArray<NSNumber *> *grSzV = [self valuesForLabel:@"Grain Size"];
  float grain = grV.count ? grV[0].floatValue / 100.0f : KK_CORE_GRAIN_DEFAULT;
  float grainSize =
      grSzV.count ? grSzV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;

  // Shares the uniform-struct layout with the FCP render (MirageMakeUniforms)
  // so the CPU<->shader contract can't drift. chanRes[0] = the render
  // resolution {W,H}, matching the main render (its iChannelResolution[0]
  // equals iResolution) so aspect-reading shaders preview the same as output.
  // FCP's polled playhead advances in coarse ~4-frame steps during playback
  // (~14Hz). The mini-viewer draw path already derives a smooth, lead-corrected
  // 60fps fraction from the published feed and places it in `editFraction`.
  // Use that same clock for every live shader input; otherwise iTime moves
  // smoothly while iProgress and #audio visibly stair-step at ~14-20fps.
  // Outside live playback, playheadFraction remains the correct scrub/static
  // value (editFraction may instead be the keypose whose popover is open).
  BOOL livePlayback = self.canvas.livePlaybackActive;
  double previewFraction =
      livePlayback ? self.editFraction : self.playheadFraction;
  KKGLSLUniforms base =
      MirageMakeUniforms(W, H, iTime, grain, grainSize, (float)previewFraction,
                         (float)encodeSRGB, (simd_float4){W, H, 1.0f, 0.0f});
  // `// #motionblur native`: the shader does its own blur, so hand it the same
  // shutter the viewer does or the preview shows a different image (a trail
  // pinned to its floor decay). Gated on the mode exactly as the FCP render is,
  // so accumulate / off / absent all keep iMotionBlur at 0 in both paths.
  if (MirageMotionBlurModeForSource(image) == MirageMotionBlurModeNative) {
    base.transition.y = self.motionBlurShutterFraction;
    base.transition.z = (float)self.previewMotionBlurSamples;
  }
  // A shader's `// #color` properties -> the colour pool (bound after the fixed
  // uniforms, same as the FCP render).
  simd_float4 colorPool[KK_SHADER_COLOR_POOL];
  NSArray<NSNumber *> * (^values)(NSString *) =
      ^NSArray<NSNumber *> *(NSString *label) {
    return [self valuesForLabel:label];
  };
  MirageShaderModel *poolModel = [MirageShaderModel modelForSource:image];
  int colorPoolN = [poolModel fillColorPool:colorPool valuesForLabel:values];
  colorPoolN = [poolModel fillScalarPool:colorPool valuesForLabel:values];
  MirageScaleMiniPixelProps(poolModel, colorPool, colorPoolN, W, H,
                            self.canvas.sourceMediaSize);
  // Sampled at the playhead's PROJECT time, pushed by the inspector - the same
  // instant the viewer is showing, so the preview and the render agree. Still
  // called when that's unknown (a large negative reads as outside the
  // spectrogram = silence): the audio members must be COUNTED either way, or
  // the block's tail goes unwritten and samples whatever the buffer last held.
  double audioTimeSec = self.audioTimelineTimeSec;
  if (livePlayback && self.clipTimelineStartSec >= 0.0 &&
      self.clipDurationSeconds > 0.0)
    audioTimeSec =
        self.clipTimelineStartSec + previewFraction * self.clipDurationSeconds;
  colorPoolN = MirageFillAudioPool(poolModel, colorPool, audioTimeSec, values);
  // `// #gradient` ramps last, so the three pools above keep their offsets.
  colorPoolN = [poolModel fillGradientPool:colorPool valuesForLabel:values];
  NSArray<NSNumber *> *transitionModeV =
      [self valuesForLabel:@"Transition Mode"];
  int transitionMode =
      transitionModeV.count
          ? (int)MAX(0, MIN(2, lround(transitionModeV[0].doubleValue)))
          : 0;
  base.transition.w = (float)transitionMode;
  BOOL technicalTransform = KKLooksLikeColorTransformShader(image);
  // The cross-process feed is always sRGB-encoded BGRA8, even for a technical
  // transform. Recover the same linear values the main FxPlug render receives;
  // the distinction is only that an ordinary Shadertoy shader is encoded back
  // to gamma below, while color-transform consumes those host values directly.
  id<MTLTexture> srcLin = [self _linearSourceView:source];
  // srcLin is linear (FCP's float source, or the sRGB view that linearises the
  // mini's gamma surface). Shadertoy wants gamma-space input and the output
  // wrapper re-decodes for a float dest, so encode to gamma here to match the
  // main render - otherwise the source double-decodes and the preview darkens.
  // Encodes onto the shared command buffer, ahead of the buffer/image passes.
  if (!technicalTransform)
    srcLin = KKGammaEncodeSourceTextureOnBuffer(commandBuffer, srcLin);
  id<MTLSamplerState> srcSampler = KKCustomSourceSampler(device);
  id<MTLTexture> noiseTex = KKCustomChannelNoiseTexture(device);
  id<MTLTexture> transparentTex =
      transitionMode != 0 ? KKCustomTransparentTexture(device) : nil;
  if (transitionMode == 1)
    srcLin = transparentTex;
  id<MTLTexture> ch1Raw = self.canvas.channel1Texture;
  id<MTLTexture> toLin = ch1Raw ? [self _linearSourceView:ch1Raw] : nil;
  if (toLin)
    toLin = KKGammaEncodeSourceTextureOnBuffer(commandBuffer, toLin);
  if (transitionMode == 2)
    toLin = transparentTex;
  // `// #frames` neighbours resolve HERE, alongside srcLin/toLin and ahead of
  // every render encoder below, because their colour match is itself a render
  // pass on this same command buffer - and a command buffer allows exactly one
  // live encoder. Resolving them at the bind site asked for a second encoder
  // while the image pass was open, which Metal aborts on.
  NSArray *neighborTex = [self _neighborTexturesForSource:image
                                       technicalTransform:technicalTransform
                                            commandBuffer:commandBuffer];
  id<MTLSamplerState> noiseSampler = KKCustomChannelSampler(device);

  // Precompile buffer pipelines + transpile; detect FEEDBACK (a buffer reading
  // itself or a later buffer, i.e. any channel c >= its own index).
  NSArray<NSString *> *bufNames =
      @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  id<MTLRenderPipelineState> bufPS[4] = {nil, nil, nil, nil};
  KKGLSLTranspileResult *bufTR[4] = {nil, nil, nil, nil};
  BOOL present[4] = {NO, NO, NO, NO};
  BOOL needsFeedback = NO;
  for (int k = 0; k < 4; k++) {
    NSString *bs = sections[bufNames[k]];
    if (bs.length == 0 || W == 0 || H == 0)
      continue;
    NSString *bsrc = withCommon(bs);
    bufPS[k] = [self _customPipelineForDevice:device
                                  pixelFormat:MTLPixelFormatRGBA16Float
                                       source:bsrc
                                   bufferMode:YES];
    if (!bufPS[k])
      continue;
    present[k] = YES;
    bufTR[k] = KKTranspileGLSLBuffer(bsrc);
    for (int c = k; c < 4; c++)
      if (bufTR[k].declaredChannelMask & (1u << c))
        needsFeedback = YES;
  }

  // Feedback shaders re-sim a short window (so the static preview accumulates)
  // at a capped resolution (the mini is a preview - keep it cheap).
  // Non-feedback buffers do a single full-res step. `srcLin` is only bound to a
  // channel that has no buffer, so re-sim reads its own previous frame, not the
  // source.
  NSUInteger bufW = (NSUInteger)W, bufH = (NSUInteger)H;
  if (needsFeedback && bufH > (NSUInteger)KK_FEEDBACK_SIM_MAXDIM) {
    bufH = KK_FEEDBACK_SIM_MAXDIM;
    bufW = (NSUInteger)llround((double)W * (double)KK_FEEDBACK_SIM_MAXDIM /
                               (double)H);
  }
  NSInteger frames = needsFeedback ? 48 : 1;
  float dt = (1.0f / 60.0f) * speed; // approximate per-frame iTime step

  id<MTLTexture> setTex[2][4] = {{nil, nil, nil, nil}, {nil, nil, nil, nil}};
  int prevI = 0;
  for (NSInteger f = 0; f < frames; f++) {
    int curI = 1 - prevI;
    BOOL first = (f == 0);
    KKGLSLUniforms fu = base;
    fu.resTime = (simd_float4){(float)bufW, (float)bufH, 1.0f,
                               iTime - (float)(frames - 1 - f) * dt};
    fu.extra.y = (float)f; // iFrame: 0 on the first step (seed-on-frame-0 sims)
    fu.extra.w = 1.0f;     // buffers store raw data (no sRGB encode)
    for (int k = 0; k < 4; k++) {
      if (!bufPS[k])
        continue;
      id<MTLTexture> cur = setTex[curI][k];
      if (!cur) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                         width:bufW
                                        height:bufH
                                     mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        cur = [device newTextureWithDescriptor:td];
        setTex[curI][k] = cur;
      }
      if (!cur)
        continue;
      NSMutableArray *chArr = [NSMutableArray arrayWithCapacity:4];
      KKGLSLUniforms bufU = fu;
      for (int c = 0; c < 4; c++) {
        id<MTLTexture> ct = nil;
        if (present[c]) {
          if (c < k)
            ct = setTex[curI][c];
          else if (!first)
            ct = setTex[prevI][c];
        } else if (c == 0) {
          ct = srcLin;
        } else if (c == 1) {
          ct = toLin;
        }
        [chArr addObject:ct ?: (id)[NSNull null]];
        if (ct)
          bufU.chanRes[c] =
              (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
      }
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = cur;
      rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
      rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> be =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [be setViewport:(MTLViewport){0, 0, (double)bufW, (double)bufH, -1.0,
                                    1.0}];
      [be setRenderPipelineState:bufPS[k]];
      KKBindGLSLUniforms(be, &bufU, colorPool, colorPoolN);
      KKBindCustomChannelTextures(be, bufTR[k], chArr, srcSampler, noiseTex,
                                  noiseSampler);
      [be drawPrimitives:MTLPrimitiveTypeTriangleStrip
             vertexStart:0
             vertexCount:4];
      [be endEncoding];
    }
    prevI = curI;
  }
  id<MTLTexture> bufTex[4];
  for (int c = 0; c < 4; c++)
    bufTex[c] = setTex[prevI][c];

  NSString *imgSrc = withCommon(image);
  id<MTLRenderPipelineState> imagePS = [self _customPipelineForDevice:device
                                                          pixelFormat:fmt
                                                               source:imgSrc
                                                           bufferMode:NO];
  if (!imagePS) {
    imgSrc = withCommon(MirageCustomErrorShaderSource());
    imagePS = [self _customPipelineForDevice:device
                                 pixelFormat:fmt
                                      source:imgSrc
                                  bufferMode:NO];
  }
  if (!imagePS)
    return NO;
  KKGLSLTranspileResult *imgTR = KKTranspileGLSL(imgSrc);
  // iChannel1 = the feed's second texture (Mirage's "To" image well, i.e. a
  // transition's incoming clip) when one was published. Same colour handling as
  // iChannel0 above, so a two-texture shader previews the way it renders.
  NSMutableArray *imgCh = [NSMutableArray arrayWithCapacity:4];
  KKGLSLUniforms imgU = base;
  for (int c = 0; c < 4; c++) {
    id<MTLTexture> ct = bufTex[c];
    if (!ct && c == 0)
      ct = srcLin;
    if (!ct && c == 1)
      ct = toLin; // nil when no well -> NSNull -> noise, as before
    [imgCh addObject:ct ?: (id)[NSNull null]];
    if (ct)
      imgU.chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  MTLRenderPassDescriptor *irpd =
      [MTLRenderPassDescriptor renderPassDescriptor];
  irpd.colorAttachments[0].texture = renderTex;
  irpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  irpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  irpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:irpd];
  [e setViewport:(MTLViewport){0, 0, W, H, -1.0, 1.0}];
  [e setRenderPipelineState:imagePS];
  KKBindGLSLUniforms(e, &imgU, colorPool, colorPoolN);
  KKBindCustomChannelTextures(e, imgTR, imgCh, srcSampler, noiseTex,
                              noiseSampler);
  KKBindCustomNeighborTextures(e, imgTR, neighborTex, srcSampler,
                               (bufTex[0] ?: srcLin) ?: noiseTex);
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];

  if (downscale)
    [self blitFrom:renderTex into:dest commandBuffer:commandBuffer];
  return YES;
}

// Effect render: the plugin is Custom-only, so this always runs the Custom
// (single- or multi-pass) GLSL path. `source` is the mini-viewer's source frame
// (bound as iChannel0).
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return [self _encodeCustomEffectFromSource:source
                                        into:dest
                               commandBuffer:commandBuffer];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  // The generic mini renderer knows only the inspector's blur switch; Mirage's
  // per-shader mode lives in the Image source. Native shaders render ONCE and
  // consume iMotionBlur/iMotionBlurSamples themselves, while Off shaders also
  // render once. Letting either fall through to the generic Accurate path
  // multiplies the whole custom render by N. For a feedback preview that is
  // especially pathological: 16 samples x 48 warm-up frames = 768 buffer
  // passes per displayed frame. Temporarily suppress only the generic wrapper;
  // Mirage's separate motionBlurShutterFraction/motionBlurSamples properties
  // still reach a Native shader in -_encodeCustomEffectFromSource:.
  NSDictionary<NSString *, NSString *> *sections = [self _customSections];
  NSString *imageSource = sections[@"Image"] ?: @"";
  MirageMotionBlurMode blurMode = MirageMotionBlurModeForSource(imageSource);
  BOOL bypassGenericBlur = (blurMode != MirageMotionBlurModeAccumulate);
  BOOL savedPreviewBlurEnabled = self.previewMotionBlurEnabled;
  if (bypassGenericBlur)
    self.previewMotionBlurEnabled = NO;

  BOOL ok = [super miniViewer:canvas
         processSourceTexture:source
                  intoTexture:dest
                commandBuffer:commandBuffer];
  if (bypassGenericBlur)
    self.previewMotionBlurEnabled = savedPreviewBlurEnabled;
  return ok;
}

@end
