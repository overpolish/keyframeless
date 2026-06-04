/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOnScreenControl.h"
#import "KKOSCShaderTypes.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKPluginInstanceState.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@interface KKOnScreenControl () <FxOnScreenControl_v4>
- (void)kkToggleOSCElementHidden:(NSString *)key;
@end

@implementation KKOnScreenControl {
  BOOL _isHovered;
  BOOL _isDragging;
  // Per-interaction opt-hide arming (see
  // -kkArmOptHideForActivePart:modifiers:).
  BOOL _kkInteractionArmed;
  BOOL _kkInteractionIsOptHide;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _isHovered = NO;
    _isDragging = NO;
    _clearsOnDraw = YES;
  }
  return self;
}

- (FxDrawingCoordinates)drawingCoordinates {
  return kFxDrawingCoordinates_CANVAS;
}

- (NSString *)pipelinePluginID {
  NSAssert(NO, @"%@ must override pipelinePluginID",
           NSStringFromClass([self class]));
  return nil;
}

- (NSString *)fragmentFunctionName {
  NSAssert(NO, @"%@ must override fragmentFunctionName",
           NSStringFromClass([self class]));
  return nil;
}

- (float)hitRadius {
  NSAssert(NO, @"%@ must override hitRadius", NSStringFromClass([self class]));
  return 0.0f;
}

- (float)oscSize {
  NSAssert(NO, @"%@ must override oscSize", NSStringFromClass([self class]));
  return 0.0f;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  NSAssert(NO, @"KKOnScreenControl subclass must override oscPositionAtTime:");
  return CGPointZero;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  CGPoint pos = [self oscPositionAtTime:time];
  double dx = positionX - pos.x;
  double dy = positionY - pos.y;
  return sqrt(dx * dx + dy * dy) < self.hitRadius;
}

- (void)drawAtCanvasPosition:(CGPoint)position
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  NSAssert(NO,
           @"KKOnScreenControl subclass must override "
           @"drawAtCanvasPosition:isHovered:isActive:destinationImage:atTime:");
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  CGPoint position = [self oscPositionAtTime:time];
  [self drawAtCanvasPosition:position
                   isHovered:_isHovered
                    isActive:_isDragging
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  _isHovered = NO;
  *activePart = 0;

  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    _isHovered = YES;
    *activePart = 1;
  }
}

- (void)mouseEnteredAtPositionX:(double)positionX
                      positionY:(double)positionY
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
}

- (void)mouseExitedAtPositionX:(double)positionX
                     positionY:(double)positionY
                     modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time {
  _isHovered = NO;
  *forceUpdate = YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  _isDragging = (activePart != 0);
  *forceUpdate = YES;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  _isDragging = NO;
  *forceUpdate = YES;
}

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}

- (void)keyUpAtPositionX:(double)positionX
               positionY:(double)positionY
              keyPressed:(unsigned short)asciiKey
               modifiers:(FxModifierKeys)modifiers
             forceUpdate:(BOOL *)forceUpdate
               didHandle:(BOOL *)didHandle
                  atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}

// Default hooks make the feature inert; plugin OSCs override the first two.
- (NSArray<NSString *> *)oscElementKeys {
  return @[];
}
- (NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  return nil;
}
- (UInt32)oscVisibilityParamID {
  return 201; // the established kParamUIState id, shared across plugins
}

- (BOOL)kkOSCElementVisible:(NSString *)label {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  if (!st)
    return YES; // no per-instance state yet => visible (pre-toggle default)
  if (!st.oscMasterVisible)
    return NO;
  return !(st.hiddenOSCElements && [st.hiddenOSCElements containsObject:label]);
}

- (BOOL)kkOSCMasterOff {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  return st && !st.oscMasterVisible;
}

- (float)kkRevealGhostAlpha {
  return [self kkOSCMasterOff] ? 1.0f : 0.3f;
}

- (BOOL)kkOSCElementIndividuallyHidden:(NSString *)label {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  NSSet<NSString *> *hidden = st.hiddenOSCElements;
  if (!hidden || !label)
    return NO;
  if ([hidden containsObject:label])
    return YES;
  // An ancestor being hidden hides its children too, via the dot hierarchy
  // ("Rotation" hides "Rotation.X"). Mirrors the inspector compound pills.
  NSRange dot = [label rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location != NSNotFound &&
         [hidden containsObject:[label substringToIndex:dot.location]];
}

- (BOOL)kkOSCRevealEligible:(NSString *)label {
  BOOL hidden = [self kkOSCElementIndividuallyHidden:label];
  // master on  -> Opt-hold reveals the elements you HID (dim re-show ghosts).
  // master off -> Opt-hold "peek" reveals the elements left ENABLED; the ones
  //               you turned off stay off (peek = a transient flip to
  //               master-on).
  return [self kkOSCMasterOff] ? !hidden : hidden;
}

- (void)kkUpdateOptRevealWithModifiers:(NSUInteger)modifiers
                           forceUpdate:(BOOL *)forceUpdate {
  // Hover is the gap between interactions: reset the per-press arming so the
  // next press is judged fresh, and track the opt-reveal state for ghosts.
  _kkInteractionArmed = NO;
  BOOL reveal = (modifiers & kFxModifierKey_OPTION) != 0;
  if (reveal != self.optRevealActive) {
    self.optRevealActive = reveal;
    if (forceUpdate)
      *forceUpdate = YES;
  }
}

- (void)kkResetOptHideArming {
  _kkInteractionArmed = NO;
}

// FCP doesn't hand the viewer a reliable mouseDown, but it drives the press /
// drag cycle (the same one carrying Shift / Cmd). We latch the interaction's
// nature on its FIRST event: opt held over a hideable part => hide-click; opt
// absent => normal drag. The armed flag makes the decision stick for the rest
// of the interaction so it stays a no-op rather than half-dragging.
- (BOOL)kkArmOptHideForActivePart:(NSInteger)activePart
                        modifiers:(NSUInteger)modifiers {
  if (_kkInteractionArmed)
    return _kkInteractionIsOptHide;
  _kkInteractionArmed = YES;
  _kkInteractionIsOptHide = NO;
  // When the master is off, Opt is the transient "peek and use" modifier, not
  // the hide toggle: leave the interaction un-armed so the normal drag proceeds
  // and manipulates the revealed control. (Toggling an element's own hidden bit
  // under the master gate would have no visible effect anyway.)
  if ((modifiers & kFxModifierKey_OPTION) && activePart != 0 &&
      ![self kkOSCMasterOff]) {
    NSString *key = [self oscElementKeyForActivePart:activePart];
    if (key) {
      [self kkToggleOSCElementHidden:key];
      _kkInteractionIsOptHide = YES;
    }
  }
  return _kkInteractionIsOptHide;
}

// Flip one element's hidden state in this instance's KKPluginInstanceState
// (immediate viewer redraw) and persist it into the UI-state blob's
// `oscElements` map (stored as VISIBLE bools, matching the inspector pills).
// The write echoes through the effect's parameterChanged, syncing the inspector
// + mini-canvas. Rebuild the FULL map from the authoritative in-memory hidden
// set and base it on the cached lastUIState (the OSC's own scope read lags its
// writes - a stale base drops a sibling hidden a tick earlier, or a stale
// activeTab/loopEnabled).
- (void)kkToggleOSCElementHidden:(NSString *)key {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  NSMutableSet<NSString *> *hidden =
      [(st.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if ([hidden containsObject:key])
    [hidden removeObject:key];
  else
    [hidden addObject:key];
  st.hiddenOSCElements = hidden;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  UInt32 paramID = [self oscVisibilityParamID];
  NSMutableDictionary *state = [st.lastUIState mutableCopy];
  if (!state) {
    NSString *existing = KKReadCustomParamString(getAPI, paramID);
    state = [(existing.length
                  ? [NSJSONSerialization
                        JSONObjectWithData:
                            [existing dataUsingEncoding:NSUTF8StringEncoding]
                                   options:0
                                     error:nil]
                  : nil) ?: @{} mutableCopy];
  }
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionary];
  for (NSString *k in [self oscElementKeys])
    els[k] = @(![hidden containsObject:k]);
  state[@"oscElements"] = els;
  st.lastUIState = state;
  NSString *json = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  KKWriteCustomParamString(setAPI, json, paramID);
  [actionAPI endAction:self];
}

@end
