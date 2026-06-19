/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import "CanvasLayerRender.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

@implementation CanvasOSC (AutoSelect)

// "Auto-select layers" toggle, read from the UIState snapshot (the OSC can't
// read the custom param). Default OFF when absent.
- (BOOL)_autoSelectEnabled {
  return [[self _uiStateDict][@"autoSelect"] boolValue];
}

// Topmost image layer under the cursor (alpha-aware), or nil. Converts the
// canvas mouse point to object space and evaluates each layer's transform at the
// playhead fraction.
- (NSString *)_pickLayerIDAtX:(double)x y:(double)y atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return nil;
  double ox = 0, oy = 0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&ox
                            toY:&oy];
  // FCP's OBJECT space here is Y-DOWN (oy=0 at the top) while the render's object
  // space (the quads, via CanvasComposedModelMatrix) is Y-UP (Y=0 at the
  // bottom), so the mouse Y must be flipped to land in the same space. This made
  // off-centre layers unselectable (centred/full-frame ones are flip-invariant,
  // so they appeared to work) and X-rotation look mirrored.
  oy = 1.0 - oy;
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  if (!paths.count)
    return nil;
  return CanvasHitTestLayerID(paths, [self fractionAtTime:time],
                              (float)[self _canvasAspect], (float)ox, (float)oy,
                              /*alphaAware=*/YES, /*excluded=*/nil,
                              /*requireEditableAtFrac=*/YES,
                              [CanvasPlugin availableLanes]);
}

// Merge the picked layer id into the current UIState (snapshot base, since the
// OSC can't read the custom param) and write it back inside an action scope. The
// write fires the effect's parameterChanged, which re-selects the layer in the
// inspector + drives the per-layer OSC/mini state. Mirrors the kit's OSC opt-hide
// write (kkToggleOSCElementHidden).
- (void)_commitPickSelection {
  NSString *layerID = self.pendingPickLayerID;
  if (!layerID.length)
    return;
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = layerID;
  }];
}

@end
