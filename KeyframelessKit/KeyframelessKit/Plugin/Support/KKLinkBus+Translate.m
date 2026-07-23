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
#import "KKTimingStage.h"
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

// Split a ref inner on its LAST dot into head + tail; NO returned (tail nil)
// for a bare same-clip ref (no dot), which the caller leaves untouched.
static BOOL KKLinkSplitRefInner(NSString *inner, NSString **outHead,
                                NSString **outTail) {
  NSRange dot = [inner rangeOfString:@"." options:NSBackwardsSearch];
  if (dot.location == NSNotFound)
    return NO;
  *outHead = [inner substringToIndex:dot.location];
  *outTail = [inner substringFromIndex:dot.location + 1];
  return YES;
}

NSString *
KKLinkStoredExpressionFromDisplay(NSString *display,
                                  NSArray<KKLinkManifest *> *manifests) {
  return KKLinkTransformExprTokens(display, ^NSString *(NSString *inner) {
    NSString *clip = nil, *param = nil;
    if (!KKLinkSplitRefInner(inner, &clip, &param))
      return nil;
    for (KKLinkManifest *man in manifests)
      if ([man.displayName isEqualToString:clip]) {
        NSUInteger i = [man.paramDisplayNames indexOfObject:param];
        NSString *rawLabel = (i != NSNotFound && i < man.paramLabels.count)
                                 ? man.paramLabels[i]
                                 : param;
        return [NSString stringWithFormat:@"%@.%@", man.uuid, rawLabel];
      }
    return nil;
  });
}

NSString *
KKLinkDisplayExpressionFromStored(NSString *stored,
                                  NSArray<KKLinkManifest *> *manifests) {
  return KKLinkTransformExprTokens(stored, ^NSString *(NSString *inner) {
    NSString *uuid = nil, *param = nil;
    if (!KKLinkSplitRefInner(inner, &uuid, &param))
      return nil;
    for (KKLinkManifest *man in manifests)
      if ([man.uuid isEqualToString:uuid]) {
        NSUInteger i = [man.paramLabels indexOfObject:param];
        NSString *disp = (i != NSNotFound && i < man.paramDisplayNames.count)
                             ? man.paramDisplayNames[i]
                             : param;
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
    // sources are still listed (a user may ask about them).
    NSArray<NSString *> *params =
        man.paramDisplayNames.count ? man.paramDisplayNames : man.paramLabels;
    [out addObject:@{
      @"clip" : man.displayName ?: @"",
      @"params" : params ?: @[]
    }];
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
// editor (source text, no value) or a palette-generator bar (UI-only, no
// value).
static BOOL KKLinkLaneIsReferenceable(KKLane *lane) {
  if (lane.label.length == 0)
    return NO;
  if (lane.valueType == KKLaneValueTypeCode)
    return NO;
  if (lane.paletteGeneratorBar)
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

void KKLinkWriteManifest(id<PROAPIAccessing> api, NSArray<KKLane *> *lanes,
                         double clipStartSec, double clipDurSec,
                         NSString *effectName) {
  NSString *uuid = KKInstanceUUIDForAPI(api);
  if (uuid.length == 0)
    return; // no identity yet (fresh instance before any UI) - skip this tick
  KKLinkManifest *m = [[KKLinkManifest alloc] init];
  m.uuid = uuid;
  m.effectName = effectName ?: @"";
  m.documentID = KKLinkDocumentIDForAPI(api) ?: @"";
  m.displayName =
      [NSString stringWithFormat:@"%@ @ %@", effectName ?: @"Effect",
                                 KKLinkTimecode(clipStartSec)];
  m.clipStartSec = clipStartSec;
  m.clipDurSec = clipDurSec;
  NSMutableArray<NSString *> *params = [NSMutableArray array];
  NSMutableArray<NSString *> *displays = [NSMutableArray array];
  for (KKLane *lane in lanes)
    if (KKLinkLaneIsReferenceable(lane)) {
      [params addObject:lane.label];
      // The lane object still carries its (non-serialized) display name here at
      // write time (built from the plugin's templates), so the picker can show
      // a friendly "Center" for a raw "uCenter" uniform key.
      [displays addObject:lane.displayName ?: lane.label];
    }
  m.paramLabels = params;
  m.paramDisplayNames = displays;
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
    NSString *linkID = [NSString stringWithFormat:@"%@.%@", uuid, lane.label];
    [KKLinkBus publishLane:lane
                    linkID:linkID
             timelineStart:tlStart
               timelineEnd:tlEnd
                      unit:nil];
  }
}
