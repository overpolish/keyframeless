/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h" // CanvasOutputSize (zoom-invariant stroke tol)
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
  // Stroke pick tolerance is px relative to the render OUTPUT, so use the true
  // output height (zoom-INVARIANT), not the on-screen canvas px the OSC sees
  // (which scales with viewer zoom and made the tolerance balloon when zoomed
  // out). Matches the mini, which passes its renderHeight. 1080 fallback before
  // the first render publishes a size.
  float ow = 0.0f, oh = 0.0f;
  float refH = CanvasOutputSize(&ow, &oh) ? oh : 1080.0f;
  return CanvasHitTestLayerID(paths, [self fractionAtTime:time],
                              (float)[self _canvasAspect], (float)ox, (float)oy,
                              /*alphaAware=*/YES, /*excluded=*/nil,
                              /*requireEditableAtFrac=*/YES,
                              [CanvasPlugin availableLanes], refH);
}

// The canvas point in render OBJECT space (normalized, Y-UP) - the same space as
// KKBezierPath points + the layer transforms, so a drag delta computed from two
// of these maps straight onto path points / the Position lane.
- (CGPoint)_objYUpAtCanvasX:(double)x y:(double)y {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointMake(0.5, 0.5);
  double ox = 0, oy = 0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&ox
                            toY:&oy];
  return CGPointMake(ox, 1.0 - oy); // FCP OBJECT is Y-down; flip to render Y-up
}

// Merge the picked layer id into the current UIState (snapshot base, since the
// OSC can't read the custom param) and write it back inside an action scope. The
// write fires the effect's parameterChanged, which re-selects the layer in the
// inspector + drives the per-layer OSC/mini state. Mirrors the kit's OSC opt-hide
// write (kkToggleOSCElementHidden).
//
// Shift / Cmd makes the click ADDITIVE (standard object-selection): toggle the
// picked layer in the multi-selection set, keeping the picked layer (or the
// first remaining) as the primary edit target. A plain click replaces the set
// with just the picked layer. Both write selectedLayerID (primary) and
// selectedLayerIDs (the full set) in one action so the path-op buttons + the
// viewer multi-highlight follow.
- (void)_commitPickSelectionWithModifiers:(NSUInteger)modifiers {
  NSString *layerID = self.pendingPickLayerID;
  if (!layerID.length)
    return;
  BOOL additive =
      (modifiers & (kFxModifierKey_SHIFT | kFxModifierKey_COMMAND)) != 0;
  NSMutableArray<NSString *> *sel = [[self _selectedLayerIDs] mutableCopy];
  NSString *primary;
  if (additive) {
    if ([sel containsObject:layerID]) {
      [sel removeObject:layerID];
      primary = sel.count ? sel.firstObject : @"";
    } else {
      [sel addObject:layerID];
      primary = layerID;
    }
  } else {
    sel = [@[ layerID ] mutableCopy];
    primary = layerID;
  }
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = primary;
    state[@"selectedLayerIDs"] = sel;
  }];
}

@end
