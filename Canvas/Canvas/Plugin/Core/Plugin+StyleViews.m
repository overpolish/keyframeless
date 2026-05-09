/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CapStyleView.h"
#import "FillStyleView.h"
#import "JoinStyleView.h"
#import "KKParamSync.h"
#import "KKPillStyleView.h"
#import "LayerList_Private.h"
#import "MarkerStyleView.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "StrokeStyleView.h"
#import <KeyframelessKit/KKGradientSampling.h>

// Wires a cycle (KKPillStyleView) row to a custom int param. Reads the
// persisted value to seed `selectedIndex`, and on each click writes the
// param + mutates the selected path (if any) inside ONE action scope so
// the change registers as a single undoable entry.
//
// `pathBlock` is invoked inside the same scope as the param write, given
// the path and the new index. Pass nil if no path mutation is needed.
static void KKWireCycleViewToParam(
    id apiManager, KKPillStyleView *_Nonnull v, UInt32 paramID,
    void (^_Nullable pathBlock)(KKBezierPath *_Nonnull path, NSInteger index)) {
  // Initial-value read: createView is a custom-view callback (no host
  // scope) — open one so getCustomParameterValue resolves.
  id<FxCustomParameterActionAPI_v4> initAct =
      [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [initAct startAction:apiManager];
  id<FxParameterRetrievalAPI_v6> initGet =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  v.selectedIndex = KKReadCustomParamInt(initGet, paramID);
  [initAct endAction:apiManager];

  __weak id weakAPI = apiManager;
  void (^pathBlockCopy)(KKBezierPath *, NSInteger) = [pathBlock copy];
  v.onSelectionChanged = ^(NSInteger index) {
    id api = weakAPI;
    if (!api)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI =
        [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:api];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKWriteCustomParamInt(setAPI, (int)index, paramID);
    if (pathBlockCopy)
      KKModifySelectedPathPropertyInScope(api, getAPI, setAPI,
                                          ^(KKBezierPath *p) {
                                            pathBlockCopy(p, index);
                                          });
    [actAPI endAction:api];
  };
}

@implementation CanvasPlugin (StyleViews)

- (nullable NSView *)createStyleViewForParameterID:(UInt32)parameterID
    NS_RETURNS_RETAINED {
  __weak id weakAPI = self.apiManager;
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;

  if (parameterID == kParamLineCap) {
    KKCapStyleView *v = [[KKCapStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    KKLayerInstanceState *lstCap = lst;
    KKWireCycleViewToParam(self.apiManager, v, kParamLineCap,
                           ^(KKBezierPath *p, NSInteger i) {
                             p.lineCap = (uint8_t)i;
                             lstCap.cachedLineCap = (uint8_t)i;
                           });
    if (lst)
      lst.capStyleView = v;
    return v;
  }

  if (parameterID == kParamLineJoin) {
    KKJoinStyleView *v = [[KKJoinStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    KKLayerInstanceState *lstJoin = lst;
    KKWireCycleViewToParam(self.apiManager, v, kParamLineJoin,
                           ^(KKBezierPath *p, NSInteger i) {
                             p.lineJoin = (uint8_t)i;
                             lstJoin.cachedLineJoin = (uint8_t)i;
                           });
    if (lst)
      lst.joinStyleView = v;
    return v;
  }

  if (parameterID == kParamStrokeStyle) {
    KKStrokeStyleView *v = [[KKStrokeStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    KKLayerInstanceState *lstStroke = lst;
    KKWireCycleViewToParam(self.apiManager, v, kParamStrokeStyle,
                           ^(KKBezierPath *p, NSInteger i) {
                             p.strokeStyle = (uint8_t)i;
                             lstStroke.cachedStrokeStyle = (uint8_t)i;
                           });
    if (lst)
      lst.strokeStyleView = v;
    return v;
  }

  if (parameterID == kParamStartMarker) {
    KKMarkerStyleView *v = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.isStart = YES;
    KKLayerInstanceState *lstStart = lst;
    KKWireCycleViewToParam(self.apiManager, v, kParamStartMarker,
                           ^(KKBezierPath *p, NSInteger i) {
                             p.startMarker = (uint8_t)i;
                             lstStart.cachedStartMarker = (uint8_t)i;
                           });
    if (lst)
      lst.startMarkerView = v;
    return v;
  }

  if (parameterID == kParamEndMarker) {
    KKMarkerStyleView *v = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.isStart = NO;
    KKLayerInstanceState *lstEnd = lst;
    KKWireCycleViewToParam(self.apiManager, v, kParamEndMarker,
                           ^(KKBezierPath *p, NSInteger i) {
                             p.endMarker = (uint8_t)i;
                             lstEnd.cachedEndMarker = (uint8_t)i;
                           });
    if (lst)
      lst.endMarkerView = v;
    return v;
  }

  if (parameterID == kParamSketchFillStyle) {
    KKFillStyleView *v = [[KKFillStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    KKLayerInstanceState *lstFill = lst;
    KKWireCycleViewToParam(self.apiManager, v, kParamSketchFillStyle,
                           ^(KKBezierPath *p, NSInteger i) {
                             p.sketchFillStyle = (uint8_t)i;
                             lstFill.cachedFillStyle = (uint8_t)i;
                           });
    if (lst)
      lst.fillStyleView = v;
    return v;
  }

  if (parameterID == kParamSketchSeed) {
    KKSeedView *seedView = [[KKSeedView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    seedView.autoresizingMask = NSViewWidthSizable;

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *pathStr = KKCanvasReadPathData(paramGetAPI);
    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    if (pathStr.length > 0 && selIdx >= 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                         options:0];
      NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if ((NSUInteger)selIdx < paths.count) {
        uint32_t seed = paths[selIdx].sketchSeed;
        if (seed == 0) {
          seed = arc4random();
          paths[selIdx].sketchSeed = seed;
          id<FxParameterSettingAPI_v5> setAPI = [self.apiManager
              apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
          NSData *newBlob = [KKBezierPath blobFromPaths:paths];
          KKCanvasWritePathData([newBlob base64EncodedStringWithOptions:0],
                                setAPI);
        }
        seedView.seed = seed;
      }
    }

    __weak KKSeedView *weakSeedView = seedView;
    seedView.onReroll = ^{
      id api = weakAPI;
      if (!api)
        return;
      __block uint32_t newSeed = 0;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *path) {
        newSeed = arc4random();
        path.sketchSeed = newSeed;
      });
      KKSeedView *sv = weakSeedView;
      if (sv && newSeed != 0)
        sv.seed = newSeed;
    };
    seedView.onSeedChanged = ^(uint32_t newSeed) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *path) {
        path.sketchSeed = newSeed;
      });
    };

    return seedView;
  }

  if (parameterID == kParamStrokeGradientUI ||
      parameterID == kParamFillGradientUI) {
    BOOL isStroke = (parameterID == kParamStrokeGradientUI);

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *pathStr = KKCanvasReadPathData(paramGetAPI);
    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    NSString *json = nil;
    if (pathStr.length > 0 && selIdx >= 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                         options:0];
      NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if ((NSUInteger)selIdx < paths.count) {
        json = isStroke ? paths[selIdx].strokeGradientJSON
                        : paths[selIdx].fillGradientJSON;
      }
    }
    if (json.length == 0)
      json = KKDefaultGradientJSON();

    KKGradientControl *control =
        [[KKGradientControl alloc] initWithFrame:NSMakeRect(0, 0, 200, 36)];
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
    if (stops)
      control.stops = stops;

    control.onStopsChanged = ^(NSArray<KKGradientStop *> *newStops) {
      id api = weakAPI;
      if (!api)
        return;
      NSString *newJSON = KKGradientJSONFromStops(newStops);
      if (!newJSON)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        if (isStroke)
          p.strokeGradientJSON = newJSON;
        else
          p.fillGradientJSON = newJSON;
      });
      id<FxCustomParameterActionAPI_v4> actAPI =
          [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:api];
      id<FxParameterSettingAPI_v5> setAPI =
          [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      KKWriteCustomParamString(setAPI, newJSON,
                               isStroke ? kParamStrokeGradientData
                                        : kParamFillGradientData);
      // Mirror write — keeps OSC-scope reads (KKReadGradientParamsToPath
      // via finalizeRect / handleCursorMouseDownX) in sync.
      [setAPI setStringParameterValue:newJSON
                          toParameter:isStroke ? kParamStrokeGradientDataMirror
                                               : kParamFillGradientDataMirror];
      [actAPI endAction:api];
    };

    if (lst) {
      if (isStroke)
        lst.strokeGradientControl = control;
      else
        lst.fillGradientControl = control;
    }
    return control;
  }

  return nil;
}

@end
