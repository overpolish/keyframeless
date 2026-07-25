/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageShaderModel.h"

#import "MirageScalarParse.h"

// An editing session churns many one-off source variants; past this many the
// least-recently-used model is dropped.
#define KK_SHADER_MODEL_CACHE_CAP 32

// Every inline `osc=` directive expands to a standard `@osc` block over the
// same primitives - the sugar the easy path rides, so ONE runtime handles both
// authored blocks and directive opt-ins. `explicitBinds` = uniforms an
// authored block already binds (the author's block wins). Returns the count
// written to `out`.
static int MirageSynthesizeOSCBlocks(const MirageScalarProp *props, int np,
                                     NSSet<NSString *> *explicitBinds,
                                     MirageOSCBlock *out, int max) {
  int n = 0;
  for (int i = 0; i < np && n < max; i++) {
    const MirageScalarProp *p = &props[i];
    if (p->oscKind[0] == '\0')
      continue;
    NSString *nm = @(p->name);
    if (!nm.length || [explicitBinds containsObject:nm])
      continue;
    MirageOSCBlock *b = &out[n];
    memset(b, 0, sizeof(*b));
    MirageOSCSetField(b->name, sizeof(b->name), nm);
    MirageOSCSetField(b->binds, sizeof(b->binds), nm);
    b->skipSnapping = p->skipSnapping; // `skipsnapping` on the sugar directive
    NSString *center =
        strlen(p->linkName)
            ? @(p->linkName)
            : [NSString
                  stringWithFormat:@"vec2(%g, %g)", p->rcenterx, p->rcentery];
    if (p->isPoint && strcmp(p->oscKind, "position") == 0) {
      // The position primitive (KKPositionOSC / KKPointOSCSet backing: full
      // editable motion path + tangents) is self-contained - the block only
      // declares.
      MirageOSCSetField(b->primitive, sizeof(b->primitive), @"position");
      n++;
      continue;
    }
    if (p->isPoint && strcmp(p->oscKind, "point") == 0) {
      // A PLAIN point handle (a centre, an offset): the glyph sits AT the
      // lane value and a drag writes the cursor back - the identity bijection
      // over the point primitive. No motion path.
      MirageOSCSetField(b->primitive, sizeof(b->primitive), @"point");
      MirageOSCSetField(b->forward, sizeof(b->forward), nm);
      MirageOSCSetField(b->inverse, sizeof(b->inverse), @"pos");
      n++;
      continue;
    }
    if (MirageScalarOSCIsRotate(p)) {
      MirageOSCSetField(b->primitive, sizeof(b->primitive), @"rotate");
      NSMutableString *ax = [NSMutableString string];
      for (int k = 0; k < p->oscAxisCount; k++)
        [ax appendFormat:@"%s%c", ax.length ? " " : "",
                         (char)tolower(p->oscAxes[k])];
      MirageOSCSetField(b->axes, sizeof(b->axes), ax);
      MirageOSCSetField(b->center, sizeof(b->center), center);
      n++;
      continue;
    }
    if (!MirageScalarRingEligible(p))
      continue;
    BOOL isRing = strcmp(p->oscKind, "ring") == 0;
    BOOL isBox = MirageScalarOSCIsBox(p);
    if (!isRing && !isBox)
      continue;
    // The value <-> geometry bijection in EXPR units (a percent lane's 0..100
    // arrives /100), through the shared radius-ring curve.
    double div = p->isPercent ? 100.0 : 1.0;
    double mn = p->fmin / div;
    double span = (p->fmax - p->fmin) / div;
    if (span <= 0)
      span = 1.0;
    b->linked = p->aspectLinked != 0;
    MirageOSCSetField(b->center, sizeof(b->center), center);
    if (isRing) {
      MirageOSCSetField(b->primitive, sizeof(b->primitive), @"ring");
      MirageOSCSetField(
          b->forward, sizeof(b->forward),
          [NSString
              stringWithFormat:@"ringExtent((%@ - %g) / %g)", nm, mn, span]);
      MirageOSCSetField(
          b->inverse, sizeof(b->inverse),
          [NSString stringWithFormat:@"%g + ringNorm(r) * %g", mn, span]);
      n++;
      continue;
    }
    // Centred box: half-extents through the same curve, per-axis. The extent
    // is a MIN-DIMENSION fraction; the rect lives in per-axis object units, so
    // `e`/`d` convert through the aspect (a scalar box stays square on
    // screen). The interior is inert (a centred box has no position to write);
    // the centred drag mechanic (shrink, aspect lock, fine mode) is
    // boxCenteredBoundForObjectMouse:, with fromRect as the bijection.
    MirageOSCSetField(b->primitive, sizeof(b->primitive), @"box");
    b->bodyDisabled = 1;
    int li = 0;
    MirageOSCSetField(b->localNames[li], sizeof(b->localNames[li]), @"c");
    MirageOSCSetField(b->localExprs[li], sizeof(b->localExprs[li]), center);
    li++;
    MirageOSCSetField(b->localNames[li], sizeof(b->localNames[li]), @"h");
    MirageOSCSetField(b->localExprs[li], sizeof(b->localExprs[li]),
                      [NSString stringWithFormat:@"ringExtent((%@ - %g) / %g)",
                                                 nm, mn, span]);
    li++;
    // NOTE: local names must dodge the expression constants (`e` is Euler).
    MirageOSCSetField(b->localNames[li], sizeof(b->localNames[li]), @"ext");
    MirageOSCSetField(b->localExprs[li], sizeof(b->localExprs[li]),
                      @"h * vec2(min(1.0, 1.0 / aspect), min(1.0, aspect))");
    li++;
    MirageOSCSetField(b->localNames[li], sizeof(b->localNames[li]), @"d");
    MirageOSCSetField(b->localExprs[li], sizeof(b->localExprs[li]),
                      @"max(c - rect.min, rect.max - c) * "
                      @"vec2(max(1.0, aspect), max(1.0, 1.0 / aspect))");
    li++;
    b->localCount = li;
    MirageOSCSetField(b->forward, sizeof(b->forward),
                      @"rect(c - ext, c + ext)");
    BOOL vec = p->isMulti && p->fieldCount != 1;
    MirageOSCSetField(
        b->inverse, sizeof(b->inverse),
        [NSString stringWithFormat:vec ? @"%g + ringNorm(d) * %g"
                                       : @"%g + ringNorm(max(d.x, d.y)) * %g",
                                   mn, span]);
    n++;
  }
  return n;
}

@implementation MirageShaderModel {
  MirageColorProp _colors[KK_SHADER_MAX_COLOR_PROPS];
  MirageScalarProp _scalars[KK_SHADER_MAX_SCALAR_PROPS];
  MirageAudioProp _audio[KK_SHADER_MAX_AUDIO_PROPS];
  MirageGradientProp _gradients[KK_SHADER_MAX_GRADIENT_PROPS];
  MirageOSCBlock
      _oscBlocks[KK_SHADER_MAX_SCALAR_PROPS + KK_SHADER_MAX_OSC_BLOCKS];
}

- (instancetype)initWithSource:(NSString *)source {
  if (!(self = [super init]))
    return nil;
  _source = [source copy];
  int cUsed = 0, sUsed = 0, aUsed = 0, gUsed = 0;
  _colorCount =
      MirageParseColorProps(source, _colors, KK_SHADER_MAX_COLOR_PROPS, &cUsed);
  _colorPoolUsed = cUsed;
  int sTrunc = 0;
  _scalarCount = MirageParseScalarProps(
      source, _scalars, KK_SHADER_MAX_SCALAR_PROPS, cUsed, &sUsed, &sTrunc);
  _scalarTruncated = sTrunc != 0;
  _scalarPoolUsed = sUsed;
  _audioCount = MirageParseAudioProps(source, _audio, KK_SHADER_MAX_AUDIO_PROPS,
                                      cUsed + sUsed, &aUsed);
  _audioPoolUsed = aUsed;
  _gradientCount =
      MirageParseGradientProps(source, _gradients, KK_SHADER_MAX_GRADIENT_PROPS,
                               cUsed + sUsed + aUsed, &gUsed);
  _gradientPoolUsed = gUsed;
  // The opt-in built-ins. No pool slots: they drive the shared uniforms, so
  // they take no offset and don't shift anything after them.
  _builtins = MirageParseBuiltins(source);

  // Unified OSC declarations: directive sugar first (mirroring the
  // checklist's source order), then authored blocks; an authored block
  // binding a uniform suppresses that uniform's sugar.
  MirageOSCBlock explicitBlocks[KK_SHADER_MAX_OSC_BLOCKS];
  int ne =
      MirageParseOSCBlocks(source, explicitBlocks, KK_SHADER_MAX_OSC_BLOCKS);
  NSMutableSet<NSString *> *explicitBinds = [NSMutableSet set];
  for (int i = 0; i < ne; i++)
    if (strlen(explicitBlocks[i].binds))
      [explicitBinds addObject:@(explicitBlocks[i].binds)];
  int ns = MirageSynthesizeOSCBlocks(_scalars, _scalarCount, explicitBinds,
                                     _oscBlocks, KK_SHADER_MAX_SCALAR_PROPS);
  memcpy(_oscBlocks + ns, explicitBlocks, (size_t)ne * sizeof(MirageOSCBlock));
  _oscBlockCount = ns + ne;
  return self;
}

+ (instancetype)modelForSource:(NSString *)source {
  static NSMutableDictionary<NSString *, MirageShaderModel *> *cache;
  static NSMutableOrderedSet<NSString *> *recency;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
    recency = [NSMutableOrderedSet orderedSet];
    lock = [NSLock new];
  });
  NSString *key = source ?: @"";
  [lock lock];
  MirageShaderModel *hit = cache[key];
  if (hit) {
    [recency removeObject:key];
    [recency addObject:key];
  }
  [lock unlock];
  if (hit)
    return hit;
  MirageShaderModel *m = [[self alloc] initWithSource:key];
  [lock lock];
  cache[key] = m;
  [recency removeObject:key];
  [recency addObject:key];
  while (recency.count > KK_SHADER_MODEL_CACHE_CAP) {
    [cache removeObjectForKey:recency.firstObject];
    [recency removeObjectAtIndex:0];
  }
  [lock unlock];
  return m;
}

- (const MirageOSCBlock *)oscBlocks {
  return _oscBlocks;
}

- (const MirageOSCBlock *)oscBlockForUniform:(const char *)uniformName {
  if (!uniformName || !uniformName[0])
    return NULL;
  for (int i = 0; i < _oscBlockCount; i++)
    if (strcmp(_oscBlocks[i].binds, uniformName) == 0)
      return &_oscBlocks[i];
  return NULL;
}

- (const MirageColorProp *)colorProps {
  return _colors;
}

- (int)fillColorPool:(vector_float4 *)pool
      valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel {
  for (int i = 0; i < KK_SHADER_COLOR_POOL; i++)
    pool[i] = (vector_float4){0, 0, 0, 0};
  for (int pi = 0; pi < _colorCount; pi++) {
    const MirageColorProp *p = &_colors[pi];
    if (p->isArray) {
      // Look up by the uniform NAME (lane identity), not the display label.
      NSArray<NSNumber *> *ccV =
          valuesForLabel([NSString stringWithFormat:@"%s Count", p->name]);
      int cc = ccV.count ? (int)lround(ccV[0].doubleValue) : p->defaultCount;
      if (cc < 0)
        cc = 0;
      if (cc > p->count)
        cc = p->count;
      for (int i = 0; i < p->count; i++) {
        NSArray<NSNumber *> *cv = valuesForLabel(
            [NSString stringWithFormat:@"%s %d", p->name, i + 1]);
        if (cv.count >= 4)
          pool[p->poolOffset + i] =
              (vector_float4){cv[0].floatValue, cv[1].floatValue,
                              cv[2].floatValue, cv[3].floatValue};
        else if (p->hasDefColors && i < p->defColorCount) {
          const float *d = p->defColors[i];
          pool[p->poolOffset + i] = (vector_float4){d[0], d[1], d[2], d[3]};
        } else {
          const float *d = kMirageDefaultPalette[i % 10];
          pool[p->poolOffset + i] = (vector_float4){d[0], d[1], d[2], d[3]};
        }
      }
      pool[p->poolOffset + p->count] = (vector_float4){(float)cc, 0, 0, 0};
    } else {
      NSArray<NSNumber *> *cv = valuesForLabel(@(p->name));
      if (cv.count >= 4)
        pool[p->poolOffset] =
            (vector_float4){cv[0].floatValue, cv[1].floatValue,
                            cv[2].floatValue, cv[3].floatValue};
      else if (p->hasDefColors) {
        const float *d = p->defColors[0];
        pool[p->poolOffset] = (vector_float4){d[0], d[1], d[2], d[3]};
      } else {
        // Fall back to the SAME per-index palette colour the catalog seeds the
        // lane with (pal[pi % 10]); using pal[0] for every single colour made
        // an un-seeded first render collapse all colours to one (purple).
        const float *d = kMirageDefaultPalette[pi % 10];
        pool[p->poolOffset] = (vector_float4){d[0], d[1], d[2], d[3]};
      }
    }
  }
  return _colorPoolUsed;
}

- (int)fillScalarPool:(vector_float4 *)pool
       valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel {
  for (int pi = 0; pi < _scalarCount; pi++) {
    const MirageScalarProp *p = &_scalars[pi];
    // Look up by the uniform NAME (the lane identity), not the display label.
    NSArray<NSNumber *> *v = valuesForLabel(@(p->name));
    switch (p->kind) {
    case MirageScalarKindPoint: {
      double x = v.count >= 1 ? v[0].doubleValue : p->pdefx;
      double y = v.count >= 2 ? v[1].doubleValue : p->pdefy;
      pool[p->poolOffset] = (vector_float4){(float)x, (float)y, 0, 0};
      break;
    }
    case MirageScalarKindMulti: {
      // N components packed into .xyz (one pool vec4). Missing components fall
      // back to the per-component default.
      float c[4] = {0, 0, 0, 0};
      for (int k = 0; k < p->fieldCount && k < 4; k++)
        c[k] = (float)(v.count > k ? v[k].doubleValue : p->mdef[k]);
      if (MirageOSCBlockIsRotate([self oscBlockForUniform:p->name]))
        for (int k = 0; k < 4; k++)
          c[k] =
              roundf(c[k]); // rotation is whole degrees, even from an OSC drag
      if (p->isPercent)
        for (int k = 0; k < 4; k++)
          c[k] /= 100.0f; // lane is 0..100 %, shader wants 0..1
      pool[p->poolOffset] = (vector_float4){c[0], c[1], c[2], c[3]};
      break;
    }
    case MirageScalarKindFloat:
    case MirageScalarKindPercent:
    case MirageScalarKindProgress:
    case MirageScalarKindRandom:
    case MirageScalarKindInt:
    case MirageScalarKindAngle:
    case MirageScalarKindBool:
    case MirageScalarKindChoice: {
      double val = v.count ? v[0].doubleValue
                           : (p->isChoice ? (double)p->cdefault : p->fdefault);
      if (p->isAngle)
        val = round(val); // angles are whole degrees, even from an OSC drag
      if (p->isPercent)
        val /= 100.0; // lane is 0..100 %, shader wants 0..1
      pool[p->poolOffset] = (vector_float4){(float)val, 0, 0, 0};
      break;
    }
    }
  }
  return _colorPoolUsed + _scalarPoolUsed;
}

- (const MirageScalarProp *)scalarProps {
  return _scalars;
}

- (const MirageAudioProp *)audioProps {
  return _audio;
}

- (const MirageGradientProp *)gradientProps {
  return _gradients;
}

- (int)fillGradientPool:(vector_float4 *)pool
         valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel {
  for (int pi = 0; pi < _gradientCount; pi++) {
    const MirageGradientProp *p = &_gradients[pi];
    // Look up by the uniform NAME (lane identity), not the display label.
    NSArray<NSNumber *> *v = valuesForLabel(@(p->name));
    // The lane's flat stop array, or the directive's defaults when the lane
    // isn't there yet (a fresh instance, or a shader edited to add a gradient
    // before the lanes rebuild).
    float stops[KK_SHADER_MAX_GRADIENT_STOPS][KK_GRADIENT_STOP_STRIDE];
    int count = 0;
    if (v.count >= 2 * KK_GRADIENT_STOP_STRIDE) {
      count = (int)(v.count / KK_GRADIENT_STOP_STRIDE);
      if (count > p->maxStops)
        count = p->maxStops;
      for (int i = 0; i < count; i++)
        for (int k = 0; k < KK_GRADIENT_STOP_STRIDE; k++)
          stops[i][k] = v[i * KK_GRADIENT_STOP_STRIDE + k].floatValue;
    } else {
      count = p->defStopCount;
      if (count > p->maxStops)
        count = p->maxStops;
      memcpy(stops, p->defStops,
             sizeof(float) * (size_t)count * KK_GRADIENT_STOP_STRIDE);
    }
    // The sampler walks segments in order and saturates each one, so a stop
    // that sorts out of place would blend backwards. Interpolating between two
    // keyposes CAN reorder them (a stop dragged past its neighbour), so sort
    // here rather than trusting the editor. Insertion sort: at most 16 stops.
    for (int i = 1; i < count; i++) {
      float key[KK_GRADIENT_STOP_STRIDE];
      memcpy(key, stops[i], sizeof(key));
      int j = i - 1;
      while (j >= 0 && stops[j][0] > key[0]) {
        memcpy(stops[j + 1], stops[j], sizeof(key));
        j--;
      }
      memcpy(stops[j + 1], key, sizeof(key));
    }

    int mid = p->poolOffset + p->maxStops; // packed midpoints follow the stops
    for (int i = 0; i < p->maxStops; i++)
      pool[p->poolOffset + i] = (vector_float4){0, 0, 0, 0};
    for (int i = 0; i < (p->maxStops + 3) / 4; i++)
      pool[mid + i] = (vector_float4){0.5f, 0.5f, 0.5f, 0.5f};
    for (int i = 0; i < count; i++) {
      // rgb in .xyz, position in .w - the sampler needs both per stop, and
      // pairing them saves the pool a second array.
      pool[p->poolOffset + i] =
          (vector_float4){stops[i][1], stops[i][2], stops[i][3], stops[i][0]};
      pool[mid + (i >> 2)][i & 3] = stops[i][4];
    }
    pool[mid + (p->maxStops + 3) / 4] = (vector_float4){(float)count, 0, 0, 0};
  }
  return _colorPoolUsed + _scalarPoolUsed + _audioPoolUsed + _gradientPoolUsed;
}

@end
