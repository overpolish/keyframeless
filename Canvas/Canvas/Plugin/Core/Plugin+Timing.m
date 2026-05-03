/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

// Descriptor for an animatable per-path property. Adding a new animatable
// property in Canvas means adding one entry to `_kkAnimatableProperties()` —
// nothing else in this file branches on the property identity.
//
// readPath / writePath operate on NSArray<NSNumber *> so a single descriptor
// can represent a Float (1 scalar), a Point (2 scalars), or a Bool (1 scalar
// 0/1). The kind dictates how values are read from / written to FxPlug.
@interface KKCanvasAnimProp : NSObject
@property(copy) NSString *label;
@property UInt32 paramID;
/// Optional second FxPlug param ID for Point-kind lanes whose two
/// components live in *separate* float params (mirrors MagicMove's
/// Scale-as-two-floats-but-one-lane pattern). 0 = unused (default).
@property UInt32 secondaryParamID;
@property KKAnimatableParamKind kind;
@property(copy) BOOL (^enabledForPath)(KKBezierPath *p);
@property(copy) NSArray<NSNumber *> * (^readPath)(KKBezierPath *p);
@property(copy) void (^writePath)(KKBezierPath *p, NSArray<NSNumber *> *vals);
+ (instancetype)propWithLabel:(NSString *)label
                      paramID:(UInt32)paramID
             secondaryParamID:(UInt32)secondaryParamID
                         kind:(KKAnimatableParamKind)kind
                      enabled:(BOOL (^)(KKBezierPath *))enabled
                         read:(NSArray<NSNumber *> * (^)(KKBezierPath *))read
                        write:(void (^)(KKBezierPath *,
                                        NSArray<NSNumber *> *))write;
@end
@implementation KKCanvasAnimProp
+ (instancetype)propWithLabel:(NSString *)label
                      paramID:(UInt32)paramID
             secondaryParamID:(UInt32)secondaryParamID
                         kind:(KKAnimatableParamKind)kind
                      enabled:(BOOL (^)(KKBezierPath *))enabled
                         read:(NSArray<NSNumber *> * (^)(KKBezierPath *))read
                        write:(void (^)(KKBezierPath *,
                                        NSArray<NSNumber *> *))write {
  KKCanvasAnimProp *p = [self new];
  p.label = label;
  p.paramID = paramID;
  p.secondaryParamID = secondaryParamID;
  p.kind = kind;
  p.enabledForPath = enabled;
  p.readPath = read;
  p.writePath = write;
  return p;
}
@end

// --- FxPlug param read/write helpers, dispatched on KKAnimatableParamKind. ---

static NSArray<NSNumber *> *
_kkReadParamForDesc(id<FxParameterRetrievalAPI_v6> getAPI,
                    KKCanvasAnimProp *desc, CMTime time) {
  switch (desc.kind) {
  case KKAnimatableParamKindPoint: {
    if (desc.secondaryParamID) {
      // Two-float Point: x lives in primary param, y in secondary.
      double x = 1, y = 1;
      [getAPI getFloatValue:&x fromParameter:desc.paramID atTime:time];
      [getAPI getFloatValue:&y fromParameter:desc.secondaryParamID atTime:time];
      return @[ @(x), @(y) ];
    }
    double x = 0, y = 0;
    [getAPI getXValue:&x YValue:&y fromParameter:desc.paramID atTime:time];
    return @[ @(x), @(y) ];
  }
  case KKAnimatableParamKindBool: {
    BOOL b = NO;
    [getAPI getBoolValue:&b fromParameter:desc.paramID atTime:time];
    return @[ @(b ? 1.0 : 0.0) ];
  }
  case KKAnimatableParamKindFloat:
  default: {
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:desc.paramID atTime:time];
    return @[ @(v) ];
  }
  }
}

static void _kkWriteParamForDesc(id<FxParameterSettingAPI_v5> setAPI,
                                 KKCanvasAnimProp *desc,
                                 NSArray<NSNumber *> *vals, CMTime time) {
  switch (desc.kind) {
  case KKAnimatableParamKindPoint:
    if (desc.secondaryParamID) {
      if (vals.count >= 2) {
        [setAPI setFloatValue:vals[0].doubleValue
                  toParameter:desc.paramID
                       atTime:time];
        [setAPI setFloatValue:vals[1].doubleValue
                  toParameter:desc.secondaryParamID
                       atTime:time];
      }
    } else if (vals.count >= 2) {
      [setAPI setXValue:vals[0].doubleValue
                 YValue:vals[1].doubleValue
            toParameter:desc.paramID
                 atTime:time];
    }
    break;
  case KKAnimatableParamKindBool:
    if (vals.count >= 1)
      [setAPI setBoolValue:vals[0].doubleValue >= 0.5
               toParameter:desc.paramID
                    atTime:time];
    break;
  case KKAnimatableParamKindFloat:
  default:
    if (vals.count >= 1)
      [setAPI setFloatValue:vals[0].doubleValue
                toParameter:desc.paramID
                     atTime:time];
    break;
  }
}

static BOOL _kkValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++) {
    if (fabs(a[i].doubleValue - b[i].doubleValue) > 1e-6)
      return NO;
  }
  return YES;
}

static NSArray<KKCanvasAnimProp *> *_kkAnimatableProperties(void) {
  static NSArray<KKCanvasAnimProp *> *sProps = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    BOOL (^transformEnabled)(KKBezierPath *) = ^BOOL(KKBezierPath *p) {
      return p.transformEnabled;
    };

    KKCanvasAnimProp *strokeWidth =
        [KKCanvasAnimProp propWithLabel:@"Stroke Width"
            paramID:kParamStrokeWidth
            secondaryParamID:0
            kind:KKAnimatableParamKindFloat
            enabled:^BOOL(KKBezierPath *p) {
              return p.strokeEnabled && !p.isGroup;
            }
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.strokeWidth) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 1)
                p.strokeWidth = vals[0].floatValue;
            }];

    // Position uses 0.5,0.5 as neutral (FCP convention); the path stores the
    // offset from neutral so render-time translation is just translateBy:.
    KKCanvasAnimProp *position = [KKCanvasAnimProp propWithLabel:@"Position"
        paramID:kParamPosition
        secondaryParamID:0
        kind:KKAnimatableParamKindPoint
        enabled:transformEnabled
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(0.5 + p.translateX), @(0.5 + p.translateY) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 2) {
            p.translateX = vals[0].floatValue - 0.5f;
            p.translateY = vals[1].floatValue - 0.5f;
          }
        }];

    // Single Scale lane carrying [scaleX, scaleY] — mirrors MagicMove. The
    // two inspector sliders live in separate float FxPlug params; the lane
    // reads/writes both via primary + secondary IDs.
    KKCanvasAnimProp *scale = [KKCanvasAnimProp propWithLabel:@"Scale"
        paramID:kParamScaleX
        secondaryParamID:kParamScaleY
        kind:KKAnimatableParamKindPoint
        enabled:transformEnabled
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.scaleX), @(p.scaleY) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 2) {
            p.scaleX = vals[0].floatValue;
            p.scaleY = vals[1].floatValue;
          }
        }];

    KKCanvasAnimProp *anchor = [KKCanvasAnimProp propWithLabel:@"Anchor"
        paramID:kParamAnchor
        secondaryParamID:0
        kind:KKAnimatableParamKindPoint
        enabled:transformEnabled
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.anchorX), @(p.anchorY) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 2) {
            p.anchorX = vals[0].floatValue;
            p.anchorY = vals[1].floatValue;
          }
        }];

    KKCanvasAnimProp * (^transformFloatProp)(NSString *, UInt32,
                                             float (^)(KKBezierPath *),
                                             void (^)(KKBezierPath *, float)) =
        ^(NSString *label, UInt32 paramID, float (^getter)(KKBezierPath *),
          void (^setter)(KKBezierPath *, float)) {
          return [KKCanvasAnimProp propWithLabel:label
              paramID:paramID
              secondaryParamID:0
              kind:KKAnimatableParamKindFloat
              enabled:transformEnabled
              read:^NSArray<NSNumber *> *(KKBezierPath *p) {
                return @[ @(getter(p)) ];
              }
              write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
                if (vals.count >= 1)
                  setter(p, vals[0].floatValue);
              }];
        };

    KKCanvasAnimProp *rotZ = transformFloatProp(
        @"Rot Z", kParamRotation,
        ^(KKBezierPath *p) {
          return p.rotationZ;
        },
        ^(KKBezierPath *p, float v) {
          p.rotationZ = v;
        });
    KKCanvasAnimProp *rotX = transformFloatProp(
        @"Rot X", kParamRotationX,
        ^(KKBezierPath *p) {
          return p.rotationX;
        },
        ^(KKBezierPath *p, float v) {
          p.rotationX = v;
        });
    KKCanvasAnimProp *rotY = transformFloatProp(
        @"Rot Y", kParamRotationY,
        ^(KKBezierPath *p) {
          return p.rotationY;
        },
        ^(KKBezierPath *p, float v) {
          p.rotationY = v;
        });

    sProps = @[ strokeWidth, position, scale, anchor, rotZ, rotX, rotY ];
  });
  return sProps;
}

static KKCanvasAnimProp *_kkPropForLabel(NSString *label) {
  for (KKCanvasAnimProp *d in _kkAnimatableProperties())
    if ([d.label isEqualToString:label])
      return d;
  return nil;
}

static KKCanvasAnimProp *_kkPropForParamID(UInt32 paramID) {
  for (KKCanvasAnimProp *d in _kkAnimatableProperties())
    if (d.paramID == paramID || d.secondaryParamID == paramID)
      return d;
  return nil;
}

static NSMutableArray<KKBezierPath *> *
_kkReadPaths(id<FxParameterRetrievalAPI_v6> getAPI) {
  NSString *str = nil;
  [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length == 0)
    return [NSMutableArray array];
  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  return [KKBezierPath pathsFromBlob:blob];
}

static void _kkWritePaths(id<FxParameterSettingAPI_v5> setAPI,
                          NSArray<KKBezierPath *> *paths) {
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  [setAPI setStringParameterValue:[blob base64EncodedStringWithOptions:0]
                      toParameter:kParamPathData];
}

static KKBezierPath *_kkPathByLayerID(NSArray<KKBezierPath *> *paths,
                                      NSString *layerID) {
  if (layerID.length == 0)
    return nil;
  for (KKBezierPath *p in paths)
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

static NSString *_kkGroupLabelForPath(KKBezierPath *p, NSUInteger idx) {
  return p.name.length
             ? p.name
             : [NSString stringWithFormat:@"Layer %lu", (unsigned long)idx];
}

static KKTimingLane *_kkBuildLane(KKCanvasAnimProp *desc, KKBezierPath *p,
                                  NSUInteger idx, NSSet<NSString *> *oscLabels,
                                  NSSet<NSString *> *oscDefaultOff) {
  KKTimingLane *lane = [KKTimingLane defaultLaneForLabel:desc.label
                                              baseValues:desc.readPath(p)];
  // Two-float Point lanes (Scale-style: independent X/Y sliders, single
  // sequencer lane) report two Float component kinds — matches MagicMove.
  if (desc.kind == KKAnimatableParamKindPoint && desc.secondaryParamID) {
    lane.valueComponentKinds =
        @[ @(KKAnimatableParamKindFloat), @(KKAnimatableParamKindFloat) ];
  } else {
    lane.valueComponentKinds = @[ @(desc.kind) ];
  }
  lane.groupKey = p.layerID;
  lane.groupLabel = _kkGroupLabelForPath(p, idx);
  lane.hasOSC = [oscLabels containsObject:desc.label];
  if (lane.hasOSC && [oscDefaultOff containsObject:desc.label])
    lane.oscVisible = NO;
  return lane;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation CanvasPlugin (Timing)

+ (void)kkApplyLanes:(NSArray<KKTimingLane *> *)lanes
          atFraction:(double)frac
             toPaths:(NSArray<KKBezierPath *> *)paths {
  if (!lanes.count || !paths.count)
    return;
  // Index lanes by (groupKey, propertyLabel).
  NSMutableDictionary<NSString *, KKTimingLane *> *byKey =
      [NSMutableDictionary dictionary];
  for (KKTimingLane *l in lanes) {
    if (!l.enabled || !l.groupKey.length || !l.propertyLabel.length)
      continue;
    byKey[[NSString
        stringWithFormat:@"%@\x1f%@", l.groupKey, l.propertyLabel]] = l;
  }
  if (!byKey.count)
    return;
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  for (KKBezierPath *p in paths) {
    if (p.layerID.length == 0)
      continue;
    for (KKCanvasAnimProp *desc in props) {
      KKTimingLane *lane =
          byKey[[NSString stringWithFormat:@"%@\x1f%@", p.layerID, desc.label]];
      if (!lane)
        continue;
      NSArray<NSNumber *> *vals = KKTimingLaneValueAtFraction(lane, frac);
      // Position lane: when the active transition has a custom bezier
      // motion path, traverse the curve instead of taking the engine's
      // linearly-interpolated x/y.
      if (desc.kind == KKAnimatableParamKindPoint && vals.count >= 2) {
        KKTimingSegment *active =
            KKTimingSegmentForFraction(lane.segments, frac);
        if (active && active.type == KKSegmentTypeTransition &&
            active.pathData.length > 0) {
          KKBezierPath *path = [KKBezierPath pathWithData:active.pathData];
          NSUInteger idx = [lane.segments indexOfObjectIdenticalTo:active];
          NSArray<NSNumber *> *fromVals =
              KKTimingBoundaryBefore(idx, lane.segments);
          NSArray<NSNumber *> *toVals =
              KKTimingBoundaryAfter(idx, lane.segments);
          if (fromVals.count >= 2 && toVals.count >= 2) {
            double segDur = active.end - active.start;
            double t = (segDur > 0) ? (frac - active.start) / segDur : 1.0;
            t = MAX(0.0, MIN(1.0, t));
            BOOL isAnimateOut = (idx == lane.segments.count - 1);
            double ti = isAnimateOut ? (1.0 - t) : t;
            double easedT = KKApplyEasing(ti, active.easing, active.intensity,
                                          active.frequency);
            if (isAnimateOut)
              easedT = 1.0 - easedT;
            simd_float2 pt =
                [path positionAtT:(float)easedT
                            start:(simd_float2){(float)fromVals[0].doubleValue,
                                                (float)fromVals[1].doubleValue}
                              end:(simd_float2){(float)toVals[0].doubleValue,
                                                (float)toVals[1].doubleValue}];
            vals = @[ @(pt.x), @(pt.y) ];
          }
        }
      }
      if (vals.count >= 1)
        desc.writePath(p, vals);
    }
  }
}

- (NSArray<KKTimingLane *> *)defaultLanesAtTime:(CMTime)time
                                    paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                    paramGetAPI {
  NSArray<KKBezierPath *> *paths = _kkReadPaths(paramGetAPI);
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  NSSet<NSString *> *oscLabels = [self animatablePropertyLabelsWithOSC];
  NSSet<NSString *> *oscDefaultOff =
      [self animatablePropertyLabelsWithOSCDefaultOff];
  NSMutableArray<KKTimingLane *> *lanes = [NSMutableArray array];
  NSUInteger idx = 0;
  for (KKBezierPath *p in paths) {
    idx++;
    if (p.layerID.length == 0)
      continue;
    for (KKCanvasAnimProp *desc in props) {
      if (desc.enabledForPath(p))
        [lanes addObject:_kkBuildLane(desc, p, idx, oscLabels, oscDefaultOff)];
    }
  }
  return lanes.count ? lanes : nil;
}

- (NSArray<KKTimingLane *> *)reconcileLanes:(NSArray<KKTimingLane *> *)existing
                                     atTime:(CMTime)time
                                paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                paramGetAPI {
  NSArray<KKBezierPath *> *paths = _kkReadPaths(paramGetAPI);
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  NSSet<NSString *> *oscLabels = [self animatablePropertyLabelsWithOSC];
  NSSet<NSString *> *oscDefaultOff =
      [self animatablePropertyLabelsWithOSCDefaultOff];

  // Index existing lanes by (groupKey, propertyLabel) so we can carry forward
  // segment data when a path/property is still present.
  NSMutableDictionary<NSString *, KKTimingLane *> *byKey =
      [NSMutableDictionary dictionary];
  for (KKTimingLane *l in existing) {
    if (!l.groupKey.length || !l.propertyLabel.length)
      continue;
    byKey[[NSString
        stringWithFormat:@"%@\x1f%@", l.groupKey, l.propertyLabel]] = l;
  }

  NSMutableArray<KKTimingLane *> *out = [NSMutableArray array];
  NSUInteger idx = 0;
  for (KKBezierPath *p in paths) {
    idx++;
    if (p.layerID.length == 0)
      continue;
    NSString *liveLabel = _kkGroupLabelForPath(p, idx);
    for (KKCanvasAnimProp *desc in props) {
      BOOL applies = desc.enabledForPath(p);
      BOOL liveHasOSC = [oscLabels containsObject:desc.label];
      NSString *key =
          [NSString stringWithFormat:@"%@\x1f%@", p.layerID, desc.label];
      KKTimingLane *prev = byKey[key];
      if (prev) {
        if (![prev.groupLabel isEqualToString:liveLabel] ||
            prev.pluginVisible != applies || prev.hasOSC != liveHasOSC) {
          KKTimingLane *m = [prev copy];
          m.groupLabel = liveLabel;
          m.pluginVisible = applies;
          m.hasOSC = liveHasOSC;
          prev = m;
        }
        [out addObject:prev];
      } else if (applies) {
        [out addObject:_kkBuildLane(desc, p, idx, oscLabels, oscDefaultOff)];
      }
    }
  }
  return out;
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                          groupKey:(NSString *)groupKey
                                            atTime:(CMTime)time {
  KKCanvasAnimProp *desc = _kkPropForLabel(label);
  if (!desc)
    return nil;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  KKBezierPath *p = _kkPathByLayerID(_kkReadPaths(getAPI), groupKey);
  if (!p)
    return nil;
  return desc.readPath(p);
}

/// Returns the layerID of the currently-selected layer (path or group), or
/// nil if there's no single selection. Used to scope inspector-slider writes
/// (the slider only reflects the selected layer; lanes for other layers must
/// stay independent of slider edits).
- (NSString *)_kkSelectedLayerID {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
  if (sel.count != 1)
    return nil;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  NSUInteger idx = sel.firstIndex;
  if (idx >= paths.count)
    return nil;
  return paths[idx].layerID;
}

- (BOOL)applyLaneValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label
               groupKey:(NSString *)groupKey
                 atTime:(CMTime)time {
  KKCanvasAnimProp *desc = _kkPropForLabel(label);
  if (!desc || values.count < 1)
    return NO;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI)
    return NO;
  NSMutableArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  KKBezierPath *p = _kkPathByLayerID(paths, groupKey);
  if (!p)
    return NO;
  desc.writePath(p, values);
  _kkWritePaths(setAPI, paths);

  // If this lane's layer is the one currently shown in the inspector, push
  // the value into the slider's FxPlug param so the slider reflects the
  // segment's value. Other layers' lanes stay independent of the slider —
  // we never write the param for them.
  if ([groupKey isEqualToString:[self _kkSelectedLayerID]]) {
    _kkWriteParamForDesc(setAPI, desc, values, time);
  }
  return YES;
}

- (void)setEditingDisabled:(BOOL)disabled
              forLaneLabel:(NSString *)label
                  groupKey:(NSString *)groupKey {
  // Canvas has no per-layer FxPlug params to flag; HTH transitions are
  // surfaced by the sequencer UI alone.
}

/// Routes an inspector-slider change into the selected layer's lane:
/// writes the new value into that lane's currently-selected segment.
/// No-op when there's no single-layer selection or no matching lane.
/// Mirrors MagicMove's `_mmHandleAnimatableParameterChange:`, scoped
/// per-layer via `groupKey`.
- (void)kkPushParamToLane:(UInt32)paramID {
  KKCanvasAnimProp *desc = _kkPropForParamID(paramID);
  if (!desc)
    return;
  NSString *selID = [self _kkSelectedLayerID];
  if (selID.length == 0)
    return;
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return;
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI) {
    [actAPI endAction:self];
    return;
  }
  CMTime now = [actAPI currentTime];
  NSArray<NSNumber *> *newValues = _kkReadParamForDesc(getAPI, desc, now);

  // Mirror the slider value into pathData immediately. Otherwise a
  // subsequent segment-click reads a stale path value for its write-back
  // step (drawOSC's slider→pathData sync hasn't ticked yet) and clobbers
  // the segment we just edited.
  NSMutableArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  KKBezierPath *p = _kkPathByLayerID(paths, selID);
  if (p && !_kkValuesEqual(desc.readPath(p), newValues)) {
    desc.writePath(p, newValues);
    _kkWritePaths(setAPI, paths);
  }

  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  NSMutableArray<KKTimingLane *> *lanes =
      json.length ? [[KKTimingLane lanesFromJSON:json] mutableCopy] : nil;
  if (!lanes.count) {
    [actAPI endAction:self];
    return;
  }
  BOOL changed = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKTimingLane *lane = lanes[i];
    if (![lane.propertyLabel isEqualToString:desc.label] ||
        ![lane.groupKey isEqualToString:selID])
      continue;
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      break;
    KKTimingSegment *seg = lane.segments[selSeg];
    if (_kkValuesEqual(seg.values, newValues))
      break;
    KKTimingLane *m = [lane copy];
    NSMutableArray<KKTimingSegment *> *segs = [m.segments mutableCopy];
    KKTimingSegment *mSeg = [seg copy];
    mSeg.values = newValues;
    segs[selSeg] = mSeg;
    m.segments = segs;
    lanes[i] = m;
    changed = YES;
    break;
  }
  if (changed) {
    KKApplyHTHNormalizationInPlace(lanes);
    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
  }
  [actAPI endAction:self];
}

@end
#pragma clang diagnostic pop
