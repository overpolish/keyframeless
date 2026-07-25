/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Display <-> stored translation of `${...}` reference tokens, the available-
// source listing the reference picker shows, per-clip document scoping, and the
// manifest/curve publish entry points a plugin calls each render tick. The
// stored form keys on stable `uuid.rawLabel`; the display form on friendly
// `Clip Name.Param Name`.

#import "KKLinkBus.h"

#import <os/lock.h>

#import "KKLinkExpr.h"
#import "KKPluginInstanceState.h" // KKInstanceUUIDForAPI
#import "KKTimeline.h"
#import <FxPlug/FxPlugSDK.h> // PROAPIAccessing, FxProjectAPI

// Walk every `${...}` token in `src`, replacing each token's inner text with
// what `map(inner)` returns (nil = leave that token untouched). Back-to-front
// so earlier ranges stay valid as we splice. The shared core of both
// translators.
static NSString *KKLinkTransformExprTokens(NSString *src,
                                           NSString * (^map)(NSString *inner)) {
  if (src.length == 0)
    return src ?: @"";
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:@"\\$\\{([^}]*)\\}"
                                                   options:0
                                                     error:nil];
  });
  NSMutableString *out = [src mutableCopy];
  NSArray<NSTextCheckingResult *> *matches =
      [re matchesInString:src options:0 range:NSMakeRange(0, src.length)];
  for (NSTextCheckingResult *m in [matches reverseObjectEnumerator]) {
    NSString *inner = [[src substringWithRange:[m rangeAtIndex:1]]
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceCharacterSet]];
    NSString *repl = map(inner);
    if (repl)
      [out replaceCharactersInRange:m.range
                         withString:[NSString stringWithFormat:@"${%@}", repl]];
  }
  return out;
}

// `prefix` + "." leads `s` -> the remainder after the dot, else nil. The
// prefix-based matching (instead of dot-splitting) keeps layer refs
// unambiguous even when user-typed names contain dots.
static NSString *KKLinkTailAfterPrefix(NSString *s, NSString *prefix) {
  if (prefix.length == 0 || s.length <= prefix.length + 1)
    return nil;
  if (![s hasPrefix:prefix])
    return nil;
  if ([s characterAtIndex:prefix.length] != '.')
    return nil;
  return [s substringFromIndex:prefix.length + 1];
}

static NSString *KKLinkParamAtIndex(NSArray<NSString *> *list, NSUInteger i,
                                    NSString *fallback) {
  return i != NSNotFound && i < list.count ? list[i] : fallback;
}

NSString *
KKLinkStoredExpressionFromDisplay(NSString *display,
                                  NSArray<KKLinkManifest *> *manifests) {
  return KKLinkTransformExprTokens(display, ^NSString *(NSString *inner) {
    // Pass 1: a manifest that FULLY resolves the token (layer + param, or a
    // listed flat param). Clip display names are NOT unique ("Canvas @ 0:00"
    // twice when two clips start together), so the first prefix match may be
    // the WRONG clip - the one that actually advertises the named layer/param
    // must win, else the token stores a half-translated ref that never
    // resolves. When SEVERAL manifests fully resolve (a deleted clip's
    // manifest + curves linger on the bus beside its same-named replacement,
    // both resolving cleanly), the FRESHEST-seen one wins - the live clip
    // heartbeats its manifest, the corpse never does, so binding by age keeps
    // new expressions off dead sources.
    NSString *best = nil;
    double bestAge = 0.0;
    for (KKLinkManifest *man in manifests) {
      NSString *rest = KKLinkTailAfterPrefix(inner, man.displayName);
      if (!rest)
        continue;
      NSString *stored = nil;
      for (KKLinkLayerSource *layer in man.layers) {
        NSString *param = KKLinkTailAfterPrefix(rest, layer.displayName);
        if (!param)
          continue;
        NSUInteger i = [layer.paramDisplayNames indexOfObject:param];
        if (i == NSNotFound)
          continue;
        stored =
            [NSString stringWithFormat:@"%@.%@.%@", man.uuid, layer.layerID,
                                       layer.paramLabels[i]];
        break;
      }
      if (!stored) {
        NSUInteger i = [man.paramDisplayNames indexOfObject:rest];
        if (i != NSNotFound)
          stored = [NSString
              stringWithFormat:@"%@.%@", man.uuid, man.paramLabels[i]];
      }
      if (stored && (!best || man.lastSeenAgeSec < bestAge)) {
        best = stored;
        bestAge = man.lastSeenAgeSec;
      }
    }
    if (best)
      return best;
    // Pass 2: best-effort fallback for a hand-typed param the source doesn't
    // (yet) advertise - keep it uuid-keyed on the first name-matching clip so
    // it starts resolving if the source later publishes that param.
    for (KKLinkManifest *man in manifests) {
      NSString *rest = KKLinkTailAfterPrefix(inner, man.displayName);
      if (!rest)
        continue;
      for (KKLinkLayerSource *layer in man.layers) {
        NSString *param = KKLinkTailAfterPrefix(rest, layer.displayName);
        if (param)
          return [NSString
              stringWithFormat:@"%@.%@.%@", man.uuid, layer.layerID, param];
      }
      return [NSString stringWithFormat:@"%@.%@", man.uuid, rest];
    }
    return nil;
  });
}

NSString *
KKLinkDisplayExpressionFromStored(NSString *stored,
                                  NSArray<KKLinkManifest *> *manifests) {
  return KKLinkTransformExprTokens(stored, ^NSString *(NSString *inner) {
    for (KKLinkManifest *man in manifests) {
      NSString *rest = KKLinkTailAfterPrefix(inner, man.uuid);
      if (!rest)
        continue;
      // Layered ref: `uuid.layerID.label` -> `Clip.Layer.Param`.
      for (KKLinkLayerSource *layer in man.layers) {
        NSString *raw = KKLinkTailAfterPrefix(rest, layer.layerID);
        if (!raw)
          continue;
        NSString *disp =
            KKLinkParamAtIndex(layer.paramDisplayNames,
                               [layer.paramLabels indexOfObject:raw], raw);
        return [NSString stringWithFormat:@"%@.%@.%@", man.displayName,
                                          layer.displayName, disp];
      }
      // Flat ref: `uuid.label` -> `Clip.Param`.
      NSString *disp = KKLinkParamAtIndex(
          man.paramDisplayNames, [man.paramLabels indexOfObject:rest], rest);
      return [NSString stringWithFormat:@"%@.%@", man.displayName, disp];
    }
    return nil;
  });
}

NSString *KKLinkAvailableSourcesJSON(NSString *excludeUUID,
                                     NSString *documentID) {
  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  for (KKLinkManifest *man in [KKLinkBus manifestsForDocumentID:documentID]) {
    if (man.uuid.length == 0 ||
        (excludeUUID.length && [man.uuid isEqualToString:excludeUUID]))
      continue;
    // Show the friendly param names the AI writes as ${Clip.Param}; empty-param
    // sources are still listed (a user may ask about them). Layered sources
    // also list layers so the AI can write ${Clip.Layer.Param}.
    NSArray<NSString *> *params =
        man.paramDisplayNames.count ? man.paramDisplayNames : man.paramLabels;
    NSMutableDictionary *entry = [@{
      @"clip" : man.displayName ?: @"",
      @"params" : params ?: @[]
    } mutableCopy];
    if (man.layers.count) {
      NSMutableArray<NSDictionary *> *layers = [NSMutableArray array];
      for (KKLinkLayerSource *l in man.layers)
        [layers addObject:@{
          @"layer" : l.displayName ?: @"",
          @"params" : (l.paramDisplayNames.count ? l.paramDisplayNames
                                                 : l.paramLabels)
              ?: @[]
        }];
      entry[@"layers"] = layers;
    }
    [out addObject:entry];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                 options:0
                                                   error:nil];
  return data ? [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding]
              : @"[]";
}

// "M:SS" (or "H:MM:SS" past an hour) for a clip's project-start seconds, the
// human anchor in the auto display name. Not frame-accurate - just enough to
// tell clips apart at a glance in the reference menu.
static NSString *KKLinkTimecode(double sec) {
  if (sec < 0)
    sec = 0;
  long total = (long)(sec + 0.5);
  long h = total / 3600, m = (total % 3600) / 60, s = total % 60;
  if (h > 0)
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
  return [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

// A lane an expression can actually consume: a numeric value lane, not a code
// editor (source text, no value), a palette-generator bar (UI-only, no
// value), a gradient (variable-length stop array - no single value an
// expression's <=4 components could carry), or an OSC-edited geometry lane
// (e.g. Canvas Points, whose keyposes are morph snapshots, not values).
static BOOL KKLinkLaneIsReferenceable(KKLane *lane) {
  if (lane.key.length == 0)
    return NO;
  if (lane.valueType == KKLaneValueTypeCode ||
      lane.valueType == KKLaneValueTypeGradient)
    return NO;
  if (lane.paletteGeneratorBar || lane.oscEditedOnly)
    return NO;
  return YES;
}

// Sticky per-UUID (process-wide), NOT per-api: FxProjectAPI -documentID:
// returns a clip's HOME project index only at document-load / while its project
// is active. The SAME clip is also rendered through OTHER api objects
// (thumbnail, mini-viewer, background) that resolve "not inside a project" -
// and those wrote the manifest (keyed by uuid) with an empty doc, clobbering
// the good value. The first NON-empty resolve for a uuid is the reliable home
// index (the load burst partitions clips cleanly by project); remember it here
// so no later empty resolve from any api can overwrite it. Process-static
// because all of one plugin's instances share one XPC process, and a uuid maps
// to exactly one clip. Re-derived each launch (a fresh process), which is fine
// - the index is assigned by open order and we only ever compare within one
// session.
static NSMutableDictionary<NSString *, NSString *> *gDocIDByUUID;
static os_unfair_lock gDocIDLock = OS_UNFAIR_LOCK_INIT;

NSString *KKLinkDocumentIDForAPI(id<PROAPIAccessing> api) {
  if (!api)
    return nil;
  NSString *uuid = KKInstanceUUIDForAPI(api);
  if (uuid.length) {
    os_unfair_lock_lock(&gDocIDLock);
    NSString *known = gDocIDByUUID[uuid];
    os_unfair_lock_unlock(&gDocIDLock);
    if (known.length)
      return known; // first good resolve wins; never regress to empty
  }

  id<FxProjectAPI> projAPI = [api apiForProtocol:@protocol(FxProjectAPI)];
  if (!projAPI)
    return nil;
  NSUInteger docID = 0;
  NSError *err = nil;
  if (![projAPI documentID:&docID error:&err])
    return nil; // e.g. thumbnail / background render: "not inside a project"
  NSString *result = [NSString stringWithFormat:@"%lu", (unsigned long)docID];
  if (uuid.length) {
    os_unfair_lock_lock(&gDocIDLock);
    if (!gDocIDByUUID)
      gDocIDByUUID = [NSMutableDictionary dictionary];
    gDocIDByUUID[uuid] = result;
    os_unfair_lock_unlock(&gDocIDLock);
  }
  return result;
}

NSString *KKLinkDocumentIDForSelfUUID(NSString *uuid) {
  if (uuid.length == 0)
    return nil;
  for (KKLinkManifest *m in [KKLinkBus allManifests])
    if ([m.uuid isEqualToString:uuid])
      return m.documentID.length ? m.documentID : nil;
  return nil;
}

// Referenceable param label + display lists for `lanes`. The lane object
// still carries its (non-serialized) display name at write time (built from
// the plugin's templates), so the picker can show a friendly "Center" for a
// raw "uCenter" uniform key.
static void KKLinkParamLists(NSArray<KKLane *> *lanes,
                             NSArray<NSString *> **outLabels,
                             NSArray<NSString *> **outDisplays) {
  NSMutableArray<NSString *> *params = [NSMutableArray array];
  NSMutableArray<NSString *> *displays = [NSMutableArray array];
  for (KKLane *lane in lanes)
    if (KKLinkLaneIsReferenceable(lane)) {
      [params addObject:lane.key];
      [displays addObject:lane.displayName ?: lane.label];
    }
  *outLabels = params;
  *outDisplays = displays;
}

static KKLinkManifest *
KKLinkBaseManifest(id<PROAPIAccessing> api, NSArray<KKLane *> *lanes,
                   double clipStartSec, double clipDurSec, NSString *effectName,
                   NSString *displayBaseName) {
  NSString *uuid = KKInstanceUUIDForAPI(api);
  if (uuid.length == 0)
    return nil; // no identity yet (fresh instance before any UI) - skip
  KKLinkManifest *m = [[KKLinkManifest alloc] init];
  m.uuid = uuid;
  m.effectName = effectName ?: @"";
  m.documentID = KKLinkDocumentIDForAPI(api) ?: @"";
  // The instance's own name when it has one, else the effect's.
  NSString *base = displayBaseName.length
                       ? displayBaseName
                       : (effectName.length ? effectName : @"Effect");
  m.displayName = [NSString
      stringWithFormat:@"%@ @ %@", base, KKLinkTimecode(clipStartSec)];
  m.clipStartSec = clipStartSec;
  m.clipDurSec = clipDurSec;
  NSArray<NSString *> *labels, *displays;
  KKLinkParamLists(lanes, &labels, &displays);
  m.paramLabels = labels;
  m.paramDisplayNames = displays;
  return m;
}

void KKLinkWriteManifest(id<PROAPIAccessing> api, NSArray<KKLane *> *lanes,
                         double clipStartSec, double clipDurSec,
                         NSString *effectName, NSString *displayBaseName) {
  KKLinkManifest *m = KKLinkBaseManifest(api, lanes, clipStartSec, clipDurSec,
                                         effectName, displayBaseName);
  if (m)
    [KKLinkBus writeManifest:m];
}

void KKLinkWriteManifestWithLayers(id<PROAPIAccessing> api,
                                   NSArray<KKLane *> *topLevelLanes,
                                   NSArray<KKLinkLayerSource *> *layers,
                                   double clipStartSec, double clipDurSec,
                                   NSString *effectName,
                                   NSString *displayBaseName) {
  KKLinkManifest *m =
      KKLinkBaseManifest(api, topLevelLanes, clipStartSec, clipDurSec,
                         effectName, displayBaseName);
  if (!m)
    return;
  NSMutableArray<KKLinkLayerSource *> *out =
      [NSMutableArray arrayWithCapacity:layers.count];
  for (KKLinkLayerSource *src in layers) {
    if (src.layerID.length == 0)
      continue;
    KKLinkLayerSource *l = [[KKLinkLayerSource alloc] init];
    l.layerID = src.layerID;
    l.displayName = src.displayName.length ? src.displayName : src.layerID;
    NSArray<NSString *> *labels, *displays;
    KKLinkParamLists(src.lanes ?: @[], &labels, &displays);
    l.paramLabels = labels;
    l.paramDisplayNames = displays;
    [out addObject:l];
  }
  m.layers = out;
  [KKLinkBus writeManifest:m];
}

void KKLinkPublishReferenceableLanes(id<PROAPIAccessing> api,
                                     NSArray<KKLane *> *lanes, double tlStart,
                                     double tlEnd) {
  NSString *uuid = KKInstanceUUIDForAPI(api);
  if (uuid.length == 0)
    return; // no identity yet - the token another clip stores can't resolve
  for (KKLane *lane in lanes) {
    if (!KKLinkLaneIsReferenceable(lane))
      continue;
    // Key MUST match the token `${uuid.label}` a subscriber stores (see the
    // popover's stored form); loadCurve reads the same `<uuid>.<label>` file.
    NSString *linkID = [NSString stringWithFormat:@"%@.%@", uuid, lane.key];
    [KKLinkBus publishLane:lane
                    linkID:linkID
             timelineStart:tlStart
               timelineEnd:tlEnd
                      unit:nil];
  }
}

void KKLinkPublishReferenceableLayer(id<PROAPIAccessing> api,
                                     KKLinkLayerSource *layer, double tlStart,
                                     double tlEnd) {
  NSString *uuid = KKInstanceUUIDForAPI(api);
  if (uuid.length == 0 || layer.layerID.length == 0)
    return;
  for (KKLane *lane in layer.lanes) {
    if (!KKLinkLaneIsReferenceable(lane))
      continue;
    // Key MUST match the layered token `${uuid.layerID.label}` a subscriber
    // stores; loadCurve reads the same `<uuid>.<layerID>.<label>` file, so
    // resolution needs no layer awareness at all.
    NSString *linkID =
        [NSString stringWithFormat:@"%@.%@.%@", uuid, layer.layerID, lane.key];
    [KKLinkBus publishLane:lane
                    linkID:linkID
             timelineStart:tlStart
               timelineEnd:tlEnd
                      unit:nil];
  }
}
