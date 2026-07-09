/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MeshMiniViewerRenderer.h"

#import "MeshColorSpace.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKPositionMiniController.h>
#import <KeyframelessKit/KKScaleMiniController.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

NSString *const MeshMiniViewerDescriptorPath = @"/tmp/mesh-miniviewer.json";

NSString *const MeshMiniViewerRequestPath =
    @"/tmp/mesh-miniviewer-request.json";

NSString *MeshMiniViewerDescriptorPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MeshMiniViewerDescriptorPath;
  return [NSString stringWithFormat:@"/tmp/mesh-miniviewer-%@.json", uuid];
}

NSString *MeshMiniViewerRequestPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MeshMiniViewerRequestPath;
  return
      [NSString stringWithFormat:@"/tmp/mesh-miniviewer-request-%@.json", uuid];
}

@implementation MeshMiniViewerRenderer {
  NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;
  MTLPixelFormat _pipelineFormat;
  KKPositionMiniController *_originMini;
  KKScaleMiniController *_scaleMini;
}

// Mini-viewer Origin handle: the reusable Position controller, keyed on the
// "Origin" lane (mirrors the main viewer's KKPositionOSC). Built lazily (no
// -init override) so the renderer is fully constructed before the controller
// weak-refs it back.
- (KKPositionMiniController *)originMini {
  if (!_originMini)
    _originMini = [[KKPositionMiniController alloc] initWithRenderer:self
                                                           laneLabel:@"Origin"
                                                           pathLabel:@"Path"];
  return _originMini;
}

// Mini-viewer Scale box: the reusable Scale controller, keyed on the "Scale"
// lane (mirrors the main viewer's KKScaleOSC). Concentric with the Origin pivot
// (see -rotationCenterForContentRect:).
- (KKScaleMiniController *)scaleMini {
  if (!_scaleMini)
    _scaleMini = [[KKScaleMiniController alloc] initWithRenderer:self
                                                       laneLabel:@"Scale"];
  return _scaleMini;
}

// The Scale box centres on the Origin point. Reuse the Origin controller's
// placement for the current Origin value.
- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  CGPoint c = CGPointZero;
  NSArray<NSNumber *> *o = [self valuesForLabel:@"Origin"];
  if (o.count >= 2 && [self.originMini pointHandleCenter:&c
                                               forValues:o
                                          forContentRect:cr])
    return c;
  if ([self.originMini pointHandleCenter:&c forContentRect:cr])
    return c;
  return CGPointMake(CGRectGetMidX(cr), CGRectGetMidY(cr));
}

- (KKLane *)templateLaneForLabel:(NSString *)label {
  for (KKLane *l in self.laneTemplates)
    if ([l.label isEqualToString:label])
      return l;
  return [super templateLaneForLabel:label];
}

// The Origin handle is the reusable Position control (arc glyph); the base
// renderer draws + drags it keyed on `pointLabel`. No crop handle.
- (NSString *)cropLabel {
  return nil;
}
- (NSString *)pointLabel {
  return @"Origin";
}
- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}
// The Origin handle is the arc (above); this only sizes the Scale box's corner
// handles - shrink them so they aren't oversized (matches MagicMove).
- (CGFloat)pointHandleSizeScale {
  return 0.6;
}
// The Origin arc draws on top of the Scale box + rotation ring, so the
// hit-test / drag prefer it where they overlap.
- (BOOL)pointHandleBeatsRotation {
  return YES;
}
// Opt into the base mini rotation gizmo, Z axis only (2D pattern), keyed on the
// 1-component "Rotation" lane and centred on the Origin pivot (see
// -rotationCenterForContentRect:).
- (NSString *)rotationLabel {
  return @"Rotation";
}
- (KKRotationAxes)rotationEnabledAxes {
  return KKRotationAxisZ;
}
- (NSInteger)valueTypeForLabel:(NSString *)label {
  if ([label hasPrefix:@"Color "] || [label isEqualToString:@"Background"] ||
      [label isEqualToString:@"Foreground"] || [label isEqualToString:@"Mid"] ||
      [label isEqualToString:@"Bloom Color"])
    return KKLaneValueTypeColor;
  if ([label isEqualToString:@"Origin"] || [label isEqualToString:@"Scale"])
    return KKLaneValueTypeGeneric;
  return KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  int ci = MeshIndexForLabel(label, @"Color ");
  if (ci >= 0 && ci < KK_MESH_COLOR_COUNT) {
    const float *c = kMeshDefaultColorsSRGB[ci];
    return @[ @(c[0]), @(c[1]), @(c[2]), @(c[3]) ];
  }
  if ([label isEqualToString:@"Distortion"])
    return @[ @(KK_MESH_GRAD_DEFAULT_DISTORTION * 100.0) ];
  if ([label isEqualToString:@"Swirl"])
    return @[ @(KK_MESH_GRAD_DEFAULT_SWIRL * 100.0) ];
  if ([label isEqualToString:@"Speed"])
    return @[ @(KK_MESH_GRAD_DEFAULT_SPEED) ];
  if ([label isEqualToString:@"Seed"])
    return @[ @(KK_MESH_GRAD_DEFAULT_SEED) ];
  if ([label isEqualToString:@"Grain Mixer"])
    return @[ @(KK_MESH_GRAD_DEFAULT_GRAINMIXER * 100.0) ];
  if ([label isEqualToString:@"Grain"])
    return @[ @(KK_MESH_DEFAULT_GRAIN * 100.0) ];
  if ([label isEqualToString:@"Type"])
    return @[ @0.0 ];
  if ([label isEqualToString:@"Background"])
    return @[ @0.04, @0.04, @0.07, @1.0 ];
  if ([label isEqualToString:@"Foreground"])
    return @[ @0.85, @0.90, @0.98, @1.0 ];
  if ([label isEqualToString:@"Mid"])
    return @[ @0.25, @0.45, @0.95, @1.0 ];
  if ([label isEqualToString:@"Brightness"])
    return @[ @(KK_NEURO_DEFAULT_BRIGHTNESS * 100.0) ];
  if ([label isEqualToString:@"Contrast"])
    return @[ @(KK_NEURO_DEFAULT_CONTRAST * 100.0) ];
  if ([label isEqualToString:@"Steps"])
    return @[ @(KK_SIMPLEX_DEFAULT_STEPS) ];
  if ([label isEqualToString:@"Count"])
    return @[ @(KK_METABALLS_DEFAULT_COUNT) ];
  if ([label isEqualToString:@"Size"])
    return @[ @(KK_METABALLS_DEFAULT_SIZE * 100.0) ];
  if ([label isEqualToString:@"Bloom Color"])
    return @[ @1.0, @0.9, @0.7, @1.0 ];
  if ([label isEqualToString:@"Density"])
    return @[ @(KK_GODRAYS_DEFAULT_DENSITY * 100.0) ];
  if ([label isEqualToString:@"Spots"])
    return @[ @(KK_GODRAYS_DEFAULT_SPOTTY * 100.0) ];
  if ([label isEqualToString:@"Glow Size"])
    return @[ @(KK_GODRAYS_DEFAULT_MIDSIZE * 100.0) ];
  if ([label isEqualToString:@"Glow"])
    return @[ @(KK_GODRAYS_DEFAULT_MIDINTENSITY * 100.0) ];
  if ([label isEqualToString:@"Rays"])
    return @[ @(KK_GODRAYS_DEFAULT_INTENSITY * 100.0) ];
  if ([label isEqualToString:@"Bloom"])
    return @[ @(KK_GODRAYS_DEFAULT_BLOOM * 100.0) ];
  if ([label isEqualToString:@"Shape"])
    return @[ @0.0 ]; // simplex
  if ([label isEqualToString:@"Dither"])
    return @[ @3.0 ]; // 8x8 Bayer
  if ([label isEqualToString:@"Pixel Size"])
    return @[ @(KK_DITHER_DEFAULT_PXSIZE) ];
  if ([label isEqualToString:@"Softness"])
    return @[ @(KK_GRAIN_DEFAULT_SOFTNESS * 100.0) ];
  if ([label isEqualToString:@"Intensity"])
    return @[ @(KK_GRAIN_DEFAULT_INTENSITY * 100.0) ];
  if ([label isEqualToString:@"Noise"])
    return @[ @(KK_GRAIN_DEFAULT_NOISE * 100.0) ];
  if ([label isEqualToString:@"Pattern"])
    return @[ @(KK_GRAIN_DEFAULT_SHAPE - 1) ]; // pill is 0-based
  if ([label isEqualToString:@"Proportion"])
    return @[ @(KK_WARP_DEFAULT_PROPORTION * 100.0) ];
  if ([label isEqualToString:@"Shape Scale"])
    return @[ @(KK_WARP_DEFAULT_SHAPESCALE * 100.0) ];
  if ([label isEqualToString:@"Swirl Iterations"])
    return @[ @(KK_WARP_DEFAULT_SWIRLITER) ];
  if ([label isEqualToString:@"Base"])
    return @[ @(KK_WARP_DEFAULT_SHAPE) ];
  if ([label isEqualToString:@"Scale"])
    return @[ @100.0, @100.0 ];
  if ([label isEqualToString:@"Rotation"])
    return @[ @0.0 ];
  if ([label isEqualToString:@"Origin"])
    return @[ @0.5, @0.5 ];
  return [super defaultValuesForLabel:label];
}

// Builds (and caches per fragment + format) the pipeline for the active type's
// fragment function, so the mini preview matches the FCP render.
- (id<MTLRenderPipelineState>)_pipelineForDevice:(id<MTLDevice>)device
                                     pixelFormat:(MTLPixelFormat)format
                                  fragmentShader:(NSString *)fragmentName {
  if (_pipelineFormat != format) {
    _pipelines = nil;
    _pipelineFormat = format;
  }
  if (!_pipelines)
    _pipelines = [NSMutableDictionary dictionary];
  id<MTLRenderPipelineState> existing = _pipelines[fragmentName];
  if (existing)
    return existing;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"MeshMiniViewerRenderer: no metal library: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  pd.fragmentFunction = [lib newFunctionWithName:fragmentName];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"MeshMiniViewerRenderer: pipeline failed: %@", err);
    return nil;
  }
  _pipelines[fragmentName] = ps;
  return ps;
}

// Generator render: no source. Runs the same Metal pipeline as the FCP render
// (vertexShader + solid-blue fragmentShader) straight into the preview dest.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    generateIntoTexture:(id<MTLTexture>)dest
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  // Dispatch on the active type, same as the FCP render.
  NSArray<NSNumber *> *typeV = [self valuesForLabel:@"Type"];
  int meshType =
      typeV.count ? (int)lround(typeV[0].doubleValue) : MeshType_Mesh;
  BOOL isDither = (meshType == MeshType_Dithering);
  BOOL isGrain = (meshType == MeshType_GrainGradient);
  BOOL isWarp = (meshType == MeshType_Warp);
  BOOL isNeuro = (meshType == MeshType_Neuro);
  BOOL isSimplex = (meshType == MeshType_Simplex);
  BOOL isMetaballs = (meshType == MeshType_Metaballs);
  BOOL isGodRays = (meshType == MeshType_GodRays);
  NSString *fragment = @"fragmentShader";
  if (isDither)
    fragment = @"ditheringFragment";
  else if (isGrain)
    fragment = @"grainGradientFragment";
  else if (isWarp)
    fragment = @"warpFragment";
  else if (isNeuro)
    fragment = @"neuroNoiseFragment";
  else if (isSimplex)
    fragment = @"simplexNoiseFragment";
  else if (isMetaballs)
    fragment = @"metaballsFragment";
  else if (isGodRays)
    fragment = @"godRaysFragment";
  id<MTLRenderPipelineState> pipeline =
      [self _pipelineForDevice:dest.device
                   pixelFormat:dest.pixelFormat
                fragmentShader:fragment];
  if (!pipeline)
    return NO;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  float W = (float)dest.width, H = (float)dest.height;
  MTLViewport vp = {0, 0, W, H, -1.0, 1.0};
  [e setViewport:vp];
  KKVertex2D verts[4] = {
      {{-W / 2, H / 2}, {0, 0}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{W / 2, -H / 2}, {1, 1}},
  };
  simd_uint2 vpSize = {(unsigned)W, (unsigned)H};
  // The mini-viewer renders into an 8-bit unorm texture shown directly on
  // screen, so gamma-encode (unlike FCP's linear float working buffer). The
  // mini is a static preview, so time tracks the edit fraction.
  int encodeSRGB = (dest.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                    dest.pixelFormat == MTLPixelFormatBGRA8Unorm)
                       ? 1
                       : 0;
  float timeSec = (float)self.editFraction;
  NSArray<NSNumber *> *seedV = [self valuesForLabel:@"Seed"];
  float seedShared =
      seedV.count ? seedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SEED;
  NSArray<NSNumber *> *originV = [self valuesForLabel:@"Origin"];
  vector_float2 originShared =
      (originV.count >= 2)
          ? (vector_float2){originV[0].floatValue, originV[1].floatValue}
          : (vector_float2){0.5f, 0.5f};
  // Common transforms: Scale stored as percent (100 = 1x), Rotation in degrees.
  NSArray<NSNumber *> *scaleV = [self valuesForLabel:@"Scale"];
  NSArray<NSNumber *> *rotV = [self valuesForLabel:@"Rotation"];
  vector_float2 scaleShared =
      (scaleV.count >= 2) ? (vector_float2){scaleV[0].floatValue / 100.0f,
                                            scaleV[1].floatValue / 100.0f}
                          : (vector_float2){1.0f, 1.0f};
  float rotationShared =
      rotV.count ? rotV[0].floatValue * (float)(M_PI / 180.0) : 0.0f;

  [e setRenderPipelineState:pipeline];
  [e setVertexBytes:verts
             length:sizeof(verts)
            atIndex:KKVertexInputIndex_Vertices];
  [e setVertexBytes:&vpSize
             length:sizeof(vpSize)
            atIndex:KKVertexInputIndex_ViewportSize];

  if (isDither) {
    DitheringUniforms d = DitheringDefault();
    NSArray<NSNumber *> *backV = [self valuesForLabel:@"Background"];
    NSArray<NSNumber *> *frontV = [self valuesForLabel:@"Foreground"];
    NSArray<NSNumber *> *shapeV = [self valuesForLabel:@"Shape"];
    NSArray<NSNumber *> *ditherV = [self valuesForLabel:@"Dither"];
    NSArray<NSNumber *> *pxV = [self valuesForLabel:@"Pixel Size"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    if (backV.count >= 4)
      d.colorBack = (vector_float4){backV[0].floatValue, backV[1].floatValue,
                                    backV[2].floatValue, backV[3].floatValue};
    if (frontV.count >= 4)
      d.colorFront =
          (vector_float4){frontV[0].floatValue, frontV[1].floatValue,
                          frontV[2].floatValue, frontV[3].floatValue};
    if (shapeV.count)
      d.shape = (int)lround(shapeV[0].doubleValue) + 1;
    if (ditherV.count)
      d.type = (int)lround(ditherV[0].doubleValue) + 1;
    if (pxV.count)
      d.pxSize = pxV[0].floatValue;
    d.speed = speedV.count ? speedV[0].floatValue : KK_DITHER_DEFAULT_SPEED;
    d.seed = seedShared;
    d.origin = originShared;
    d.scale = scaleShared;
    d.rotation = rotationShared;
    d.resolution = (vector_float2){W, H};
    d.time = timeSec;
    [e setFragmentBytes:&d length:sizeof(d) atIndex:MeshFragmentIndex_Grid];
  } else if (isGrain) {
    GrainGradientUniforms g = GrainGradientDefault();
    int gCount = 0;
    int gMax = KK_MESH_COLOR_COUNT < KK_GRAIN_GRAD_COLORS
                   ? KK_MESH_COLOR_COUNT
                   : KK_GRAIN_GRAD_COLORS;
    for (int i = 0; i < gMax; i++) {
      NSArray<NSNumber *> *v = [self valuesForLabel:MeshColorLabel(i)];
      if (v.count >= 4)
        g.colors[gCount++] = (vector_float4){v[0].floatValue, v[1].floatValue,
                                             v[2].floatValue, v[3].floatValue};
      else {
        const float *c = kMeshDefaultColorsSRGB[i];
        g.colors[gCount++] = (vector_float4){c[0], c[1], c[2], c[3]};
      }
    }
    g.colorsCount = gCount > 0 ? gCount : 1;
    NSArray<NSNumber *> *backV = [self valuesForLabel:@"Background"];
    NSArray<NSNumber *> *softV = [self valuesForLabel:@"Softness"];
    NSArray<NSNumber *> *intenV = [self valuesForLabel:@"Intensity"];
    NSArray<NSNumber *> *noiseV = [self valuesForLabel:@"Noise"];
    NSArray<NSNumber *> *patternV = [self valuesForLabel:@"Pattern"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    if (backV.count >= 4)
      g.colorBack = (vector_float4){backV[0].floatValue, backV[1].floatValue,
                                    backV[2].floatValue, backV[3].floatValue};
    g.softness =
        softV.count ? softV[0].floatValue / 100.0f : KK_GRAIN_DEFAULT_SOFTNESS;
    g.intensity = intenV.count ? intenV[0].floatValue / 100.0f
                               : KK_GRAIN_DEFAULT_INTENSITY;
    g.noise =
        noiseV.count ? noiseV[0].floatValue / 100.0f : KK_GRAIN_DEFAULT_NOISE;
    if (patternV.count)
      g.shape = (int)lround(patternV[0].doubleValue) + 1;
    g.speed = speedV.count ? speedV[0].floatValue : KK_GRAIN_DEFAULT_SPEED;
    g.seed = seedShared;
    g.origin = originShared;
    g.scale = scaleShared;
    g.rotation = rotationShared;
    g.resolution = (vector_float2){W, H};
    g.time = timeSec;
    [e setFragmentBytes:&g length:sizeof(g) atIndex:MeshFragmentIndex_Grid];
  } else if (isWarp) {
    WarpUniforms w = WarpDefault();
    int wCount = 0;
    for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
      NSArray<NSNumber *> *v = [self valuesForLabel:MeshColorLabel(i)];
      if (v.count >= 4)
        w.colors[wCount++] = (vector_float4){v[0].floatValue, v[1].floatValue,
                                             v[2].floatValue, v[3].floatValue};
      else {
        const float *c = kMeshDefaultColorsSRGB[i];
        w.colors[wCount++] = (vector_float4){c[0], c[1], c[2], c[3]};
      }
    }
    w.colorsCount = wCount > 0 ? wCount : 1;
    NSArray<NSNumber *> *propV = [self valuesForLabel:@"Proportion"];
    NSArray<NSNumber *> *softV = [self valuesForLabel:@"Softness"];
    NSArray<NSNumber *> *shapeScaleV = [self valuesForLabel:@"Shape Scale"];
    NSArray<NSNumber *> *distV = [self valuesForLabel:@"Distortion"];
    NSArray<NSNumber *> *swirlV = [self valuesForLabel:@"Swirl"];
    NSArray<NSNumber *> *swirlIterV = [self valuesForLabel:@"Swirl Iterations"];
    NSArray<NSNumber *> *baseV = [self valuesForLabel:@"Base"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    w.proportion =
        propV.count ? propV[0].floatValue / 100.0f : KK_WARP_DEFAULT_PROPORTION;
    w.softness =
        softV.count ? softV[0].floatValue / 100.0f : KK_GRAIN_DEFAULT_SOFTNESS;
    w.shapeScale = shapeScaleV.count ? shapeScaleV[0].floatValue / 100.0f
                                     : KK_WARP_DEFAULT_SHAPESCALE;
    w.distortion = distV.count ? distV[0].floatValue / 100.0f
                               : KK_MESH_GRAD_DEFAULT_DISTORTION;
    w.swirl = swirlV.count ? swirlV[0].floatValue / 100.0f
                           : KK_MESH_GRAD_DEFAULT_SWIRL;
    w.swirlIterations =
        swirlIterV.count ? swirlIterV[0].floatValue : KK_WARP_DEFAULT_SWIRLITER;
    if (baseV.count)
      w.shape = (int)lround(baseV[0].doubleValue);
    w.speed = speedV.count ? speedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;
    w.seed = seedShared;
    w.origin = originShared;
    w.scale = scaleShared;
    w.rotation = rotationShared;
    w.resolution = (vector_float2){W, H};
    w.time = timeSec;
    [e setFragmentBytes:&w length:sizeof(w) atIndex:MeshFragmentIndex_Grid];
  } else if (isNeuro) {
    NeuroNoiseUniforms nn = NeuroNoiseDefault();
    NSArray<NSNumber *> *frontV = [self valuesForLabel:@"Foreground"];
    NSArray<NSNumber *> *midV = [self valuesForLabel:@"Mid"];
    NSArray<NSNumber *> *backV = [self valuesForLabel:@"Background"];
    NSArray<NSNumber *> *brightV = [self valuesForLabel:@"Brightness"];
    NSArray<NSNumber *> *contrastV = [self valuesForLabel:@"Contrast"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    if (frontV.count >= 4)
      nn.colorFront =
          (vector_float4){frontV[0].floatValue, frontV[1].floatValue,
                          frontV[2].floatValue, frontV[3].floatValue};
    if (midV.count >= 4)
      nn.colorMid = (vector_float4){midV[0].floatValue, midV[1].floatValue,
                                    midV[2].floatValue, midV[3].floatValue};
    if (backV.count >= 4)
      nn.colorBack = (vector_float4){backV[0].floatValue, backV[1].floatValue,
                                     backV[2].floatValue, backV[3].floatValue};
    nn.brightness = brightV.count ? brightV[0].floatValue / 100.0f
                                  : KK_NEURO_DEFAULT_BRIGHTNESS;
    nn.contrast = contrastV.count ? contrastV[0].floatValue / 100.0f
                                  : KK_NEURO_DEFAULT_CONTRAST;
    nn.speed = speedV.count ? speedV[0].floatValue : 1.0f;
    nn.seed = seedShared;
    nn.origin = originShared;
    nn.scale = scaleShared;
    nn.rotation = rotationShared;
    nn.resolution = (vector_float2){W, H};
    nn.time = timeSec;
    [e setFragmentBytes:&nn length:sizeof(nn) atIndex:MeshFragmentIndex_Grid];
  } else if (isSimplex) {
    SimplexNoiseUniforms sn = SimplexNoiseDefault();
    int snCount = 0;
    for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
      NSArray<NSNumber *> *v = [self valuesForLabel:MeshColorLabel(i)];
      if (v.count >= 4)
        sn.colors[snCount++] = (vector_float4){
            v[0].floatValue, v[1].floatValue, v[2].floatValue, v[3].floatValue};
      else {
        const float *c = kMeshDefaultColorsSRGB[i];
        sn.colors[snCount++] = (vector_float4){c[0], c[1], c[2], c[3]};
      }
    }
    sn.colorsCount = snCount > 0 ? snCount : 1;
    NSArray<NSNumber *> *stepsV = [self valuesForLabel:@"Steps"];
    NSArray<NSNumber *> *softV = [self valuesForLabel:@"Softness"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    sn.stepsPerColor =
        stepsV.count ? stepsV[0].floatValue : KK_SIMPLEX_DEFAULT_STEPS;
    sn.softness = softV.count ? softV[0].floatValue / 100.0f
                              : KK_SIMPLEX_DEFAULT_SOFTNESS;
    sn.speed = speedV.count ? speedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;
    sn.seed = seedShared;
    sn.origin = originShared;
    sn.scale = scaleShared;
    sn.rotation = rotationShared;
    sn.resolution = (vector_float2){W, H};
    sn.time = timeSec;
    [e setFragmentBytes:&sn length:sizeof(sn) atIndex:MeshFragmentIndex_Grid];
  } else if (isMetaballs) {
    MetaballsUniforms mb = MetaballsDefault();
    int mbCount = 0;
    for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
      NSArray<NSNumber *> *v = [self valuesForLabel:MeshColorLabel(i)];
      if (v.count >= 4)
        mb.colors[mbCount++] = (vector_float4){
            v[0].floatValue, v[1].floatValue, v[2].floatValue, v[3].floatValue};
      else {
        const float *c = kMeshDefaultColorsSRGB[i];
        mb.colors[mbCount++] = (vector_float4){c[0], c[1], c[2], c[3]};
      }
    }
    mb.colorsCount = mbCount > 0 ? mbCount : 1;
    NSArray<NSNumber *> *backV = [self valuesForLabel:@"Background"];
    NSArray<NSNumber *> *countV = [self valuesForLabel:@"Count"];
    NSArray<NSNumber *> *sizeV = [self valuesForLabel:@"Size"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    if (backV.count >= 4)
      mb.colorBack = (vector_float4){backV[0].floatValue, backV[1].floatValue,
                                     backV[2].floatValue, backV[3].floatValue};
    mb.ballCount =
        countV.count ? countV[0].floatValue : KK_METABALLS_DEFAULT_COUNT;
    mb.ballSize =
        sizeV.count ? sizeV[0].floatValue / 100.0f : KK_METABALLS_DEFAULT_SIZE;
    mb.speed = speedV.count ? speedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;
    mb.seed = seedShared;
    mb.origin = originShared;
    mb.scale = scaleShared;
    mb.rotation = rotationShared;
    mb.resolution = (vector_float2){W, H};
    mb.time = timeSec;
    [e setFragmentBytes:&mb length:sizeof(mb) atIndex:MeshFragmentIndex_Grid];
  } else if (isGodRays) {
    GodRaysUniforms gr = GodRaysDefault();
    int grCount = 0;
    int grMax = KK_MESH_COLOR_COUNT < 5 ? KK_MESH_COLOR_COUNT : 5;
    for (int i = 0; i < grMax; i++) {
      NSArray<NSNumber *> *v = [self valuesForLabel:MeshColorLabel(i)];
      if (v.count >= 4)
        gr.colors[grCount++] = (vector_float4){
            v[0].floatValue, v[1].floatValue, v[2].floatValue, v[3].floatValue};
      else {
        const float *c = kMeshDefaultColorsSRGB[i];
        gr.colors[grCount++] = (vector_float4){c[0], c[1], c[2], c[3]};
      }
    }
    gr.colorsCount = grCount > 0 ? grCount : 1;
    NSArray<NSNumber *> *backV = [self valuesForLabel:@"Background"];
    NSArray<NSNumber *> *bloomColorV = [self valuesForLabel:@"Bloom Color"];
    NSArray<NSNumber *> *densityV = [self valuesForLabel:@"Density"];
    NSArray<NSNumber *> *spottyV = [self valuesForLabel:@"Spots"];
    NSArray<NSNumber *> *midSizeV = [self valuesForLabel:@"Glow Size"];
    NSArray<NSNumber *> *midIntenV = [self valuesForLabel:@"Glow"];
    NSArray<NSNumber *> *raysV = [self valuesForLabel:@"Rays"];
    NSArray<NSNumber *> *bloomV = [self valuesForLabel:@"Bloom"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    if (backV.count >= 4)
      gr.colorBack = (vector_float4){backV[0].floatValue, backV[1].floatValue,
                                     backV[2].floatValue, backV[3].floatValue};
    if (bloomColorV.count >= 4)
      gr.colorBloom =
          (vector_float4){bloomColorV[0].floatValue, bloomColorV[1].floatValue,
                          bloomColorV[2].floatValue, bloomColorV[3].floatValue};
    gr.density = densityV.count ? densityV[0].floatValue / 100.0f
                                : KK_GODRAYS_DEFAULT_DENSITY;
    gr.spotty = spottyV.count ? spottyV[0].floatValue / 100.0f
                              : KK_GODRAYS_DEFAULT_SPOTTY;
    gr.midSize = midSizeV.count ? midSizeV[0].floatValue / 100.0f
                                : KK_GODRAYS_DEFAULT_MIDSIZE;
    gr.midIntensity = midIntenV.count ? midIntenV[0].floatValue / 100.0f
                                      : KK_GODRAYS_DEFAULT_MIDINTENSITY;
    gr.intensity = raysV.count ? raysV[0].floatValue / 100.0f
                               : KK_GODRAYS_DEFAULT_INTENSITY;
    gr.bloom =
        bloomV.count ? bloomV[0].floatValue / 100.0f : KK_GODRAYS_DEFAULT_BLOOM;
    gr.speed = speedV.count ? speedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;
    gr.seed = seedShared;
    gr.origin = originShared;
    gr.scale = scaleShared;
    gr.rotation = rotationShared;
    gr.resolution = (vector_float2){W, H};
    gr.time = timeSec;
    [e setFragmentBytes:&gr length:sizeof(gr) atIndex:MeshFragmentIndex_Grid];
  } else {
    // Same colour swatches + controls as the FCP render (valuesForLabel falls
    // back to defaults).
    MeshGradientUniforms grid;
    memset(&grid, 0, sizeof(grid));
    int count = 0;
    for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
      NSArray<NSNumber *> *v = [self valuesForLabel:MeshColorLabel(i)];
      if (v.count >= 4) {
        grid.colors[count++] = (vector_float4){
            v[0].floatValue, v[1].floatValue, v[2].floatValue, v[3].floatValue};
      } else {
        const float *c = kMeshDefaultColorsSRGB[i];
        grid.colors[count++] = (vector_float4){c[0], c[1], c[2], c[3]};
      }
    }
    grid.colorsCount = count > 0 ? count : 1;
    NSArray<NSNumber *> *distV = [self valuesForLabel:@"Distortion"];
    NSArray<NSNumber *> *swirlV = [self valuesForLabel:@"Swirl"];
    NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
    NSArray<NSNumber *> *mixV = [self valuesForLabel:@"Grain Mixer"];
    NSArray<NSNumber *> *grainV = [self valuesForLabel:@"Grain"];
    grid.distortion = distV.count ? distV[0].floatValue / 100.0f
                                  : KK_MESH_GRAD_DEFAULT_DISTORTION;
    grid.swirl = swirlV.count ? swirlV[0].floatValue / 100.0f
                              : KK_MESH_GRAD_DEFAULT_SWIRL;
    grid.speed =
        speedV.count ? speedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;
    grid.seed = seedShared;
    grid.origin = originShared;
    grid.grainMixer = mixV.count ? mixV[0].floatValue / 100.0f
                                 : KK_MESH_GRAD_DEFAULT_GRAINMIXER;
    grid.grainOverlay =
        grainV.count ? grainV[0].floatValue / 100.0f : KK_MESH_DEFAULT_GRAIN;
    grid.scale = scaleShared;
    grid.rotation = rotationShared;
    grid.time = timeSec;
    [e setFragmentBytes:&grid
                 length:sizeof(grid)
                atIndex:MeshFragmentIndex_Grid];
  }

  [e setFragmentBytes:&encodeSRGB
               length:sizeof(encodeSRGB)
              atIndex:MeshFragmentIndex_EncodeSRGB];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
  return YES;
}

// Dead for the generator: no source is ever published to the mini-viewer feed,
// so the source path never runs (see -miniViewer:generateIntoTexture:). Kept as
// a no-op to satisfy the KKMiniViewerRenderer contract.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return NO;
}

// Base point-handle overrides forwarded to the reusable Position controller.
// The base drives the constant-lane Origin handle's draw / hit / drag lifecycle
// (gated by _pointActiveForContentRect -> isConstantLabel); these place it,
// hit-test it, and commit its drag through the controller.
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  return [self.originMini pointHandleCenter:outCenter forContentRect:cr];
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)cr {
  return [self.originMini pointHandleCenter:outCenter
                                  forValues:values
                             forContentRect:cr];
}
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self.originMini pointHandleHitAtPoint:p contentRect:cr];
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas {
  // The no-modifier form is only called on drag begin (base
  // beginHandleDragAtPoint): capture the press state, then apply.
  [self.originMini beginPointDragAtPoint:p contentRect:cr];
  [self.originMini applyPointDragToPoint:p
                             contentRect:cr
                                  canvas:canvas
                               modifiers:0];
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  [self.originMini applyPointDragToPoint:p
                             contentRect:cr
                                  canvas:canvas
                               modifiers:modifiers];
}

// Motion-path overlay (animated Origin): keypose anchors + tangent handles,
// owned by the controller. The base hides the point handle for a non-constant
// lane, so the path takes over.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathPolylineForContentRect:(CGRect)cr {
  return [self.originMini motionPathPolylineForContentRect:cr];
}
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathAnchorsForContentRect:(CGRect)cr {
  return [self.originMini motionPathAnchorsForContentRect:cr];
}
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)cr {
  return [self.originMini motionPathHandleSegmentsForContentRect:cr];
}
- (CGFloat)motionPathGhostAlpha {
  return [self ghostAlphaForLabel:@"Path"];
}

// Scale transform box: geometry + hit-test + drag live in the reusable
// KKScaleMiniController; these are the thin delegate forwards.
- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *boxes = [[super miniViewer:canvas
                                      boxesForContentRect:cr] mutableCopy];
  CGRect sb;
  if ([self.scaleMini boxRect:&sb forContentRect:cr]) {
    [boxes addObject:[KKMiniBox boxWithRect:sb
                              handleCenters:[self.scaleMini
                                                handleCentersForContentRect:cr]
                                    readout:[self.scaleMini readoutText]
                                 ghostAlpha:[self.scaleMini ghostAlpha]]];
  }
  return boxes;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  self.canvas = canvas;
  // Constant Origin handle first, then the motion-path tangents / anchors,
  // then the Scale box, then the base (crop/rotation - none here).
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.originMini pathHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.originMini pathAnchorHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas;
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:self.pointLabel]
               ?: KKPointMoveCursor();
  if ([self.originMini pathHandleHitAtPoint:p contentRect:cr] ||
      [self.originMini pathAnchorHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Path"] ?: KKPointMoveCursor();
  NSInteger scaleIdx;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:&scaleIdx])
    return [self kkVisibilityCursorForLabel:@"Scale"]
               ?: KKResizeCursorForBoxHandle(scaleIdx);
  return [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  self.canvas = canvas;
  // Constant Origin handle takes the grab first (base sets _pointGrabbed +
  // applies), else the motion-path anchors / tangents.
  if ([self pointHandleHitAtPoint:p contentRect:cr]) {
    [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  if ([self.originMini beginPathDragAtPoint:p contentRect:cr])
    return;
  if ([self.scaleMini beginDragAtPoint:p contentRect:cr])
    return;
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (self.originMini.pathGrabbed) {
    [self.originMini applyPathDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  if (self.scaleMini.isDragging) {
    [self.scaleMini applyDragToPoint:p
                         contentRect:cr
                           modifiers:modifiers
                              canvas:canvas];
    return;
  }
  if (![self pointHandleIsActive]) {
    [super miniViewer:canvas
        dragHandleToPoint:p
              contentRect:cr
                modifiers:modifiers];
    return;
  }
  [self applyPointDragToPoint:p
                  contentRect:cr
                       canvas:canvas
                    modifiers:modifiers];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  self.canvas = canvas;
  return [self.originMini toggleSmoothAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  self.canvas = canvas;
  // Base claims the Origin point handle first; then the path anchors/handles.
  if ([super miniViewer:canvas optClickHandleAtPoint:p contentRect:cr])
    return YES;
  if (self.onHandleVisibilityToggled &&
      ([self.originMini pathHandleHitAtPoint:p contentRect:cr] ||
       [self.originMini pathAnchorHitAtPoint:p contentRect:cr])) {
    self.onHandleVisibilityToggled(@"Path");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  if (self.onHandleVisibilityToggled &&
      [self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL]) {
    self.onHandleVisibilityToggled(@"Scale");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  return NO;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY {
  [self.originMini snapGuideHasX:hasX
                               X:outX
                    fromKeyposeX:fromKeyposeX
                            hasY:hasY
                               Y:outY
                    fromKeyposeY:fromKeyposeY];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  [self.scaleMini endDrag];
  // endDrag resets the snap engine and reports whether a motion-path drag was
  // active (so the host persists the full blob).
  if ([self.originMini endDrag]) {
    if (self.onTimelinePersist)
      self.onTimelinePersist(self.timeline);
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [super miniViewerEndHandleDrag:canvas];
}

@end
