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
@interface KKCanvasAnimProp : NSObject
@property(copy) NSString *label;
@property UInt32 paramID;
@property KKAnimatableParamKind kind;
@property(copy) BOOL (^enabledForPath)(KKBezierPath *p);
@property(copy) double (^readPath)(KKBezierPath *p);
@property(copy) void (^writePath)(KKBezierPath *p, double v);
@end
@implementation KKCanvasAnimProp
@end

static NSArray<KKCanvasAnimProp *> *_kkAnimatableProperties(void) {
  static NSArray<KKCanvasAnimProp *> *sProps = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    KKCanvasAnimProp *strokeWidth = [KKCanvasAnimProp new];
    strokeWidth.label = @"Stroke Width";
    strokeWidth.paramID = kParamStrokeWidth;
    strokeWidth.kind = KKAnimatableParamKindFloat;
    strokeWidth.enabledForPath = ^BOOL(KKBezierPath *p) {
      return p.strokeEnabled;
    };
    strokeWidth.readPath = ^double(KKBezierPath *p) {
      return p.strokeWidth;
    };
    strokeWidth.writePath = ^(KKBezierPath *p, double v) {
      p.strokeWidth = (float)v;
    };
    sProps = @[ strokeWidth ];
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
    if (d.paramID == paramID)
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
                                  NSUInteger idx) {
  KKTimingLane *lane =
      [KKTimingLane defaultLaneForLabel:desc.label
                             baseValues:@[ @(desc.readPath(p)) ]];
  lane.valueComponentKinds = @[ @(desc.kind) ];
  lane.groupKey = p.layerID;
  lane.groupLabel = _kkGroupLabelForPath(p, idx);
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
    if (p.isGroup || p.layerID.length == 0)
      continue;
    for (KKCanvasAnimProp *desc in props) {
      KKTimingLane *lane =
          byKey[[NSString stringWithFormat:@"%@\x1f%@", p.layerID, desc.label]];
      if (!lane)
        continue;
      NSArray<NSNumber *> *vals = KKTimingLaneValueAtFraction(lane, frac);
      if (vals.count >= 1)
        desc.writePath(p, vals[0].doubleValue);
    }
  }
}

- (NSArray<KKTimingLane *> *)defaultLanesAtTime:(CMTime)time
                                    paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                    paramGetAPI {
  NSArray<KKBezierPath *> *paths = _kkReadPaths(paramGetAPI);
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  NSMutableArray<KKTimingLane *> *lanes = [NSMutableArray array];
  NSUInteger idx = 0;
  for (KKBezierPath *p in paths) {
    idx++;
    if (p.isGroup || p.layerID.length == 0)
      continue;
    for (KKCanvasAnimProp *desc in props) {
      if (desc.enabledForPath(p))
        [lanes addObject:_kkBuildLane(desc, p, idx)];
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
    if (p.isGroup || p.layerID.length == 0)
      continue;
    NSString *liveLabel = _kkGroupLabelForPath(p, idx);
    for (KKCanvasAnimProp *desc in props) {
      BOOL applies = desc.enabledForPath(p);
      NSString *key =
          [NSString stringWithFormat:@"%@\x1f%@", p.layerID, desc.label];
      KKTimingLane *prev = byKey[key];
      if (prev) {
        if (![prev.groupLabel isEqualToString:liveLabel] ||
            prev.pluginVisible != applies) {
          KKTimingLane *m = [prev copy];
          m.groupLabel = liveLabel;
          m.pluginVisible = applies;
          prev = m;
        }
        [out addObject:prev];
      } else if (applies) {
        [out addObject:_kkBuildLane(desc, p, idx)];
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
  return @[ @(desc.readPath(p)) ];
}

/// Returns the layerID of the currently-selected non-group path, or nil if
/// there's no single selection. Used to scope inspector-slider writes (the
/// slider only reflects the selected layer; lanes for other layers must
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
  if (idx >= paths.count || paths[idx].isGroup)
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
  double newValue = values[0].doubleValue;
  desc.writePath(p, newValue);
  _kkWritePaths(setAPI, paths);

  // If this lane's layer is the one currently shown in the inspector, push
  // the value into the slider's FxPlug param so the slider reflects the
  // segment's value. Other layers' lanes stay independent of the slider —
  // we never write the param for them.
  if ([groupKey isEqualToString:[self _kkSelectedLayerID]]) {
    [setAPI setFloatValue:newValue toParameter:desc.paramID atTime:time];
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
  double newValue = 0;
  [getAPI getFloatValue:&newValue
          fromParameter:paramID
                 atTime:[actAPI currentTime]];

  // Mirror the slider value into pathData immediately. Otherwise a
  // subsequent segment-click reads a stale path value for its write-back
  // step (drawOSC's slider→pathData sync hasn't ticked yet) and clobbers
  // the segment we just edited.
  NSMutableArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  KKBezierPath *p = _kkPathByLayerID(paths, selID);
  if (p && fabs(desc.readPath(p) - newValue) > 1e-6) {
    desc.writePath(p, newValue);
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
    NSNumber *cur = seg.values.firstObject;
    if (cur && fabs(cur.doubleValue - newValue) < 1e-6)
      break;
    KKTimingLane *m = [lane copy];
    NSMutableArray<KKTimingSegment *> *segs = [m.segments mutableCopy];
    KKTimingSegment *mSeg = [seg copy];
    mSeg.values = @[ @(newValue) ];
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
