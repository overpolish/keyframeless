/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The non-draw half of CanvasOSC's CanvasPenSurface conformance, split out of
// CanvasOSC+Pen.m: coordinate/grid-snap conversion, the layer-blob + selection
// reads, and the action-scoped live/preview/commit layer writes that back the
// shared pen + path-edit controllers. The draw-primitive half of the protocol
// stays in CanvasOSC+Pen.m alongside the glyph helpers.

#import "CanvasLayerTimeline.h" // blob + UIState snapshots
#import "CanvasOSC_Private.h"
#import "CanvasPenController.h"
#import "Constants.h" // kParamLayerData / kParamUIState
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// The primary @implementation CanvasOSC (Pen) declares CanvasPenSurface
// conformance + holds the draw primitives; this category supplies the remaining
// protocol methods, so silence the per-method "implemented outside the declaring
// category" warning (same pattern as the controller category splits).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (PenSurface)

- (CGPoint)penSurfacePointFromObj:(CGPoint)objYUp {
  return [self _penCanvasFromObj:objYUp];
}

- (CGPoint)penObjFromSurfaceX:(double)x y:(double)y {
  simd_float2 fcp = [self objectPointFromCanvasPoint:CGPointMake(x, y)];
  return CGPointMake(fcp.x, 1.0f - fcp.y);
}

- (CGPoint)penSnappedObjFromSurfaceX:(double)x y:(double)y {
  CGPoint cp = [self _snapCanvasPointToGrid:CGPointMake(x, y)];
  return [self penObjFromSurfaceX:cp.x y:cp.y];
}

- (BOOL)penGridSnapping {
  return [self _gridEnabled] && [self _gridSnap];
}

- (double)penCanvasAspect {
  return [self _canvasAspect];
}

- (BOOL)penToolActive {
  return [self _penToolActive];
}

- (KKBezierPath *)penLayerWithID:(NSString *)layerID {
  for (KKBezierPath *p in [self _snapshotPaths])
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

- (NSString *)penSelectedLayerID {
  return [self _resolvedSelectedLayerID];
}

- (NSArray<NSString *> *)penSelectedLayerIDs {
  return [self _selectedLayerIDs];
}

- (NSString *)penSurfaceTag {
  return @"osc";
}

- (NSString *)penInstanceUUID {
  return KKInstanceUUIDForAPI(self.apiManager);
}

// The viewer has no popover scope, so every layer is selectable.
- (NSSet<NSString *> *)penNonSelectableLayerIDs {
  return nil;
}

- (NSArray<KKBezierPath *> *)penAllLayers {
  return [self _snapshotPaths];
}

- (double)penEditFraction {
  return [self fractionAtTime:self.penDrawTime];
}

// CanvasPenSurface: clear the whole selection (a plain click on empty canvas).
- (void)penDeselectAll {
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = @"";
    state[@"selectedLayerIDs"] = @[];
  }];
}

// CanvasPenSurface: commit a marquee layer selection. Plain replaces the set
// with the enclosed layers (primary = topmost), Shift unions them into the
// current selection. Routes through the same UIState write as a pick click.
- (void)penSelectLayerIDs:(NSArray<NSString *> *)layerIDs
                 additive:(BOOL)additive {
  if (!layerIDs.count)
    return;
  NSMutableArray<NSString *> *sel;
  NSString *primary;
  if (additive) {
    sel = [[self _selectedLayerIDs] mutableCopy] ?: [NSMutableArray array];
    for (NSString *lid in layerIDs)
      if (![sel containsObject:lid])
        [sel addObject:lid];
    primary = sel.firstObject ?: @"";
  } else {
    sel = [layerIDs mutableCopy];
    primary = layerIDs.firstObject;
  }
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = primary ?: @"";
    state[@"selectedLayerIDs"] = sel;
  }];
}

// Host-callback read-modify-write of the layer blob (the OSC can't READ the
// custom param, so it round-trips the inspector snapshot). When `selectID` is
// set, the selection is written in the SAME action so it undoes together.
- (void)penMutateBlob:(void (^)(NSMutableArray<KKBezierPath *> *paths))mutate
        selectLayerID:(NSString *)selectID {
  __block NSString *newBlob = nil;
  __block NSString *newState = nil;
  BOOL scoped = KKPerformHostCallbackParameterAccess(
      self.apiManager,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI) {
        if (!setAPI)
          return;
        NSString *b64 = CanvasLayerBlobSnapshot();
        NSMutableArray<KKBezierPath *> *paths =
            b64.length
                ? [KKBezierPath
                      pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                        options:0]]
                : [NSMutableArray array];
        mutate(paths);
        newBlob =
            [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
        KKWriteCustomParamString(setAPI, newBlob, kParamLayerData);

        if (selectID.length) {
          NSMutableDictionary *state = [[self _uiStateDict] mutableCopy];
          state[@"selectedLayerID"] = selectID;
          // Collapse the multi-set to the single result too, else a prior multi-
          // selection's now-stale IDs linger (e.g. after deleting a multi-selection
          // the deleted IDs would stay in selectedLayerIDs).
          state[@"selectedLayerIDs"] = @[ selectID ];
          newState = [[NSString alloc]
              initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                           options:0
                                                             error:nil]
                  encoding:NSUTF8StringEncoding];
          KKWriteCustomParamString(setAPI, newState, kParamUIState);
        }
  });
  if (!scoped || !newBlob)
    return;
  CanvasSetLayerBlobSnapshot(newBlob);
  if (newState)
    CanvasSetUIStateSnapshot(newState);
}

- (void)penSetLiveLayers:(NSArray<KKBezierPath *> *)paths {
  // Write the blob param inside the host's OSC callback on every drag tick,
  // like the Scale / Position OSCs (KKScaleOSC -_writeScaleValues:): FCP
  // coalesces a gesture's per-tick writes into ONE undo step, and because the
  // param itself changes the FCP viewer RE-RENDERS the actual shape live, not
  // just the OSC overlay. The process snapshot is kept in step so the OSC's
  // next draw + the next tick read the new geometry before the param round-trip
  // republishes it.
  NSString *blob =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
  KKPerformHostCallbackParameterAccess(self.apiManager,
                    ^(id<FxParameterRetrievalAPI_v6> getAPI,
                      id<FxParameterSettingAPI_v5> setAPI) {
                      if (setAPI)
                        KKWriteCustomParamString(setAPI, blob, kParamLayerData);
                    });
  CanvasSetLayerBlobSnapshot(blob);
  self.penLiveParamWritten =
      YES; // this gesture has committed via per-tick writes
}

- (void)penPreviewLayers:(NSArray<KKBezierPath *> *)paths {
  // Snapshot only - update what the OSC reads WITHOUT writing the param, so a
  // curve-preserving insert doesn't spawn its own undo step. The mouseUp commit
  // writes the one undo (penLiveParamWritten stays NO until a real drag
  // writes).
  NSString *blob =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
  CanvasSetLayerBlobSnapshot(blob);
  self.penLiveParamWritten = NO;
}

- (void)penCommitLiveLayers {
  // If per-tick drag writes already committed this gesture (penSetLiveLayers),
  // there's nothing to do - a write here would be a SECOND undo step. But if
  // the gesture only previewed (a click insert with no drag), write the
  // snapshot once now so it persists as the single undo.
  if (!self.penLiveParamWritten) {
    NSString *blob = CanvasLayerBlobSnapshot();
    if (blob.length) {
      KKPerformHostCallbackParameterAccess(
          self.apiManager,
          ^(id<FxParameterRetrievalAPI_v6> getAPI,
            id<FxParameterSettingAPI_v5> setAPI) {
            if (setAPI)
              KKWriteCustomParamString(setAPI, blob, kParamLayerData);
          });
    }
  }
  self.penLiveParamWritten = NO;
}

@end

#pragma clang diagnostic pop
