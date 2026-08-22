/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageMiniViewerRenderer.h"
#import "MirageMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KKLog.h>

#import "Constants.h"
#import "KKGLSLTranspiler.h" // GLSL -> MSL + channel binding
#import "MirageAudioPool.h"
#import "MirageCustomShader.h" // MirageCustomErrorShaderSource
#import "MirageDirectives.h"
#import "MirageExprMiniSet.h"     // // @osc custom-handling handles
#import "MirageFrameOffsets.h"    // `// #frames` neighbour offsets
#import "MirageLocalCatalog.h"
#import "MirageOSCBlockRuntime.h" // rotate blocks feed the rotation set
#import "MirageRenderUniforms.h"  // MirageMakeUniforms (shared with FCP render)
#import "MirageTypes.h"
#import "Plugin+Render_Internal.h" // kMiragePassthroughSource
#import "Plugin_Private.h"         // +availableLanesForShaderSource:
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKSlotInstances.h> // slot lane keys + instance order
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

@implementation _MirageNeighborConversion
@end

@implementation _MirageMiniChainInputs
@end

@implementation MirageMiniViewerRenderer

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
// host-raster fidelity intermediate in -hiResTargetForDest:, but motion-blur
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
  // Entry-qualified, like the viewer's `_oscBlockSig`: two rack entries running
  // the same template have identical source while binding different lanes, so
  // source alone would leave the previous entry's controllers up.
  NSString *sig =
      [NSString stringWithFormat:@"%@\n%@", [self _oscEntryID], src];
  if ([sig isEqualToString:_pointSyncedSource])
    return;
  _pointSyncedSource = [sig copy];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  NSMutableSet<NSString *> *noSnap =
      [NSMutableSet set]; // `skipsnapping` labels
  // Blocks that remap their placement (authored toPos/fromPos), keyed by lane:
  // the mini has to apply the SAME warp as the viewer or an offset-valued
  // position lane draws here at the frame origin while the viewer draws it
  // where it belongs.
  NSMutableDictionary<NSString *, MirageOSCBlockRuntime *> *warped =
      [NSMutableDictionary dictionary];
  __weak MirageMiniViewerRenderer *weakRenderer = self;
  for (MirageOSCBlockRuntime *b in
       [MirageOSCBlockRuntime runtimesForSource:src
                                          lanes:self.laneTemplates ?: @[]
                                    rackEntryID:[self _oscEntryID]])
    if ([b.primitive isEqualToString:@"position"]) {
      // The rack-scoped key, not the bare uniform name: the mini controller
      // reads, writes and gates visibility by its laneLabel, exactly as
      // KKPositionOSC does in the viewer.
      [labels addObject:b.laneKey];
      if (!b.snaps)
        [noSnap addObject:b.laneKey];
      if (b.hasForward && b.hasInverse) {
        // Without this every uniform the warp REFERENCES resolves to 0, so a
        // forward like `mid + uPosition` collapses to a constant and the handle
        // sits at a fixed wrong spot. Same provider the expr set uses.
        // Referenced uniforms arrive under the shader's own bare identifier,
        // so they are scoped to the entry before they reach the timeline.
        b.laneValueProvider = ^NSArray<NSNumber *> *(NSString *label) {
          return [weakRenderer
              rootValuesForLabel:[weakRenderer _oscScopedKey:label]];
        };
        // `size` is the SOURCE media resolution, not the preview's - a warp
        // written against real pixels has to mean the same thing here as in
        // the viewer or the mini draws the handle somewhere else.
        b.mediaSizeProvider = ^CGSize(void) {
          return weakRenderer.canvas.sourceMediaSize;
        };
        warped[b.laneKey] = b;
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
  [self.exprSet syncWithSource:src lanes:lanes rackEntryID:[self _oscEntryID]];
}

// The KKRotationAxes bitmask for a rotate block's `axes = x y z` subset
// (default Z), matching the viewer's mapping.
static NSInteger MirageMiniRotationAxesForNames(NSString *axes);

// Feed the rotation set the shader's current `osc={..}` lanes: one spec per
// rotate directive (label + active-axis bitmask + clip-centre). Cheap string
// compare skips the parse when the source is unchanged.
- (void)_syncMiniRotController {
  NSString *src = [self _customShaderSource] ?: @"";
  NSString *sig =
      [NSString stringWithFormat:@"%@\n%@", [self _oscEntryID], src];
  if ([sig isEqualToString:_rotSyncedSource])
    return;
  _rotSyncedSource = [sig copy];
  NSMutableArray<NSDictionary<NSString *, id> *> *rots = [NSMutableArray array];
  if (src.length) {
    // Rotate blocks (the `osc={..}` sugar included) feed the spec-driven set,
    // keyed on their LANE label like the viewer gizmo. The two standard
    // `center =` shapes map onto the spec: a bare uniform name is a live link,
    // anything else evaluates once to a constant centre.
    __weak MirageMiniViewerRenderer *weakRenderer = self;
    for (MirageOSCBlockRuntime *b in
         [MirageOSCBlockRuntime runtimesForSource:src
                                            lanes:self.laneTemplates ?: @[]
                                      rackEntryID:[self _oscEntryID]]) {
      if (![b.primitive isEqualToString:@"rotate"])
        continue;
      // Every uniform the centre expression REFERENCES resolves through this
      // provider; without it they all read 0, so Magic Move's
      // `uPosition + uAnchor - vec2(0.5)` collapsed to a constant -0.5,-0.5 and
      // put the rings half a frame off the top-left corner. The point + expr
      // sets already wire the same pair - this path was the one that didn't.
      b.laneValueProvider = ^NSArray<NSNumber *> *(NSString *label) {
        return [weakRenderer
            rootValuesForLabel:[weakRenderer _oscScopedKey:label]];
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
      // `laneTemplates` is the WHOLE rack's set, so the bare identifier the
      // shader wrote is matched in this entry's namespace - otherwise a second
      // entry's `center = uOrigin` never classifies as a link and falls to the
      // per-draw evaluation path.
      NSString *centerKey = [self _oscScopedKey:centerSrc];
      BOOL isLink = NO;
      if (isBareIdentifier)
        for (KKLane *lane in self.laneTemplates)
          if ([lane.key isEqualToString:centerKey]) {
            isLink = YES;
            break;
          }
      simd_float2 c = {0.5f, 0.5f};
      if (centerSrc.length && !isLink)
        c = [b centerObjectForBound:KKExprScalar(0) aspect:1.0];
      NSMutableDictionary<NSString *, id> *spec = [@{
        @"label" : b.laneKey,
        @"axes" : @((int)MirageMiniRotationAxesForNames(b.axes)),
        @"centerX" : @(c.x),
        @"centerY" : @(c.y),
        @"linkLabel" : isLink ? centerKey : @"",
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
          KKExprVal bound = [rt
              boundValueFromLaneValues:[self rootValuesForLabel:rt.laneKey]];
          simd_float2 oc = [rt centerObjectForBound:bound aspect:aspect];
          return CGPointMake(oc.x, oc.y);
        };
      }
      // A DISPLAY-ONLY `angleOffset =` follows the same per-draw shape as an
      // expression centre: it may read other lanes (a #choice preset), so it
      // resolves live rather than baking a value from the source-change tick.
      if (b.hasAngleOffset) {
        __weak typeof(self) weakSelf = self;
        MirageOSCBlockRuntime *rt = b;
        spec[@"offsetDegBlock"] = ^NSArray<NSNumber *> *(void) {
          __strong typeof(weakSelf) self = weakSelf;
          if (!self)
            return @[];
          KKExprVal bound = [rt
              boundValueFromLaneValues:[self rootValuesForLabel:rt.laneKey]];
          CGSize media = self.canvas.sourceMediaSize;
          double aspect = media.height > 0 ? media.width / media.height : 1.0;
          double deg[3];
          [rt angleOffsetDegreesForBound:bound aspect:aspect out:deg];
          return @[ @(deg[0]), @(deg[1]), @(deg[2]) ];
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
  // SHADER RACK: the key names its entry, and the shader-declared default is a
  // question about THAT entry's source. Peeled first, because a rack key wraps
  // a `#slots` one (`~Rack#<id>.<group>#<inst>.<control>`) and the slot parse
  // below expects the inner half. Every bare key belongs to the sentinel and
  // passes through untouched, so a project that has never been racked answers
  // exactly as it did.
  NSString *entryID = kMirageRackSentinelEntryID;
  NSString *bare = nil;
  MirageRackParseLaneKey(label ?: @"", &entryID, &bare);
  if (bare.length)
    label = bare;
  // A `// #slots` instance lane whose keyframes aren't stamped yet answers from
  // the PROTOTYPE it was copied from, which is the control the key names. Every
  // instance therefore starts at the shader's declared default rather than at
  // super's @[@0], the same way a non-repeating control does.
  NSString *slotControl = nil;
  if (KKSlotParseLaneKey(label, NULL, NULL, &slotControl) && slotControl.length)
    label = slotControl;
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
  NSString *src = [self _customShaderSourceForEntry:entryID];
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

// The Custom type's user shader source for ONE rack entry, from that entry's
// code lane (the chosen default when the sentinel's is missing entirely),
// mirroring the FCP render read.
- (NSString *)_customShaderSourceForEntry:(NSString *)entryID {
  KKLane *shaderLane =
      MirageRackCodeLaneForEntry(self.timeline, entryID, kMirageCodeLaneLabel);
  if (shaderLane.codeString.length)
    return shaderLane.codeString;
  // Fresh instance: timeline not yet seeded. Mirror the FCP render and use the
  // chosen default so the mini matches. A present-but-empty codeString
  // means the user cleared it => passthrough. The seed is the SENTINEL's alone,
  // matching MirageEvalStateAtFrac: a later rack entry exists only because its
  // registry slot was persisted, so a missing code lane there means no shader,
  // not an unwritten one.
  if (!shaderLane &&
      (!entryID.length || [entryID isEqualToString:kMirageRackSentinelEntryID]))
    return MirageDefaultShaderSource();
  return kMiragePassthroughSource;
}

// The entry the on-screen controls belong to, defaulted to the sentinel - both
// the pre-selection answer and the only entry an unracked project has.
- (NSString *)_oscEntryID {
  return MirageRackEntryIDOrSentinel(self.rackEntryID);
}

// A shader-authored (bare) key in that entry's namespace, idempotently, so a
// call site may hand over either half of the boundary.
- (NSString *)_oscScopedKey:(NSString *)key {
  return MirageRackScopedLaneKey([self _oscEntryID], key);
}

// The source the SOURCE-DERIVED on-screen controls (the point / rotation / expr
// sets) and the bare-label defaults are read from: the SELECTED entry's, which
// is the entry the viewer's own OSC is scoped to - the two stay in lockstep
// through the selection rather than through the sentinel. Chain-wide rendering
// asks per entry (-_customShaderSourceForEntry:) instead.
- (NSString *)_customShaderSource {
  return [self _customShaderSourceForEntry:[self _oscEntryID]];
}

// All Custom sections from one entry's code lane: Image (codeString) +
// non-empty extra tabs (Common / Buffer A-D) by name. Mirrors the FCP render's
// per-entry blob sections.
- (NSDictionary<NSString *, NSString *> *)_customSectionsForEntry:
    (NSString *)entryID {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  KKLane *shaderLane =
      MirageRackCodeLaneForEntry(self.timeline, entryID, kMirageCodeLaneLabel);
  if (!shaderLane) {
    // Fresh instance: seed every pass of the chosen default (mirrors FCP).
    // Sentinel only - see -_customShaderSourceForEntry:.
    if (!entryID.length || [entryID isEqualToString:kMirageRackSentinelEntryID])
      [out addEntriesFromDictionary:MirageDefaultShaderSections()];
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

// The instant the chain's SHAPE is resolved at - which entries are switched on.
// The same clock the uniforms use (the smooth published fraction during live
// playback, the scrub/static playhead otherwise), so the preview cannot show a
// bypass the frame it is drawing doesn't have.

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

@end
