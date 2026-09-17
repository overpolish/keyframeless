/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMLanes.h"
#import "MMDefaults.h"
#import "MMShortcut.h"
#import "Constants.h"
@import InspectorControls;
@import PluginHost;

// Component colours are stable per property, independent of selection order or
// which curves are visible, so the inspector rows and the graph agree.
static KFPropertyLane *MMMakeLane(UInt32 parameter, NSString *name, UInt32 cacheToken,
                                  UInt32 matchToggle, UInt32 proportionalToggle,
                                  UInt32 visibilityToggle, NSArray<NSNumber *> *colorIndexes,
                                  NSArray<NSString *> *labels, NSString *suffix, NSUInteger digits,
                                  NSArray<NSNumber *> *values, double minimum, double maximum,
                                  BOOL bounds, BOOL percentOfImage) {
  NSArray<NSColor *> *palette = ICInspectorTokens.curveColors;
  NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:colorIndexes.count];
  for (NSNumber *index in colorIndexes) [colors addObject:palette[index.unsignedIntegerValue]];
  KFPose *pose = [[KFPose alloc] initWithValues:values authored:NO easing:MTEasingSmooth
                                    addedMotion:MTAddedMotionNone];
  return [[KFPropertyLane alloc] initWithParameterID:parameter displayName:name
      cacheTokenID:cacheToken matchToggleID:matchToggle proportionalToggleID:proportionalToggle
      visibilityToggleID:visibilityToggle componentColors:colors componentLabels:labels
      unitSuffix:suffix fractionDigits:digits defaultPose:pose minimum:minimum maximum:maximum
      boundsValues:bounds percentOfImage:percentOfImage];
}

// Pixel positions and anchors read as whole pixels; percentages and degrees
// need a decimal to show a scrub.
NSArray<KFPropertyLane *> *MMLanes(void) {
  static NSArray<KFPropertyLane *> *lanes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lanes = @[
      // Position values are a percentage of the image; its limits set the
      // added-motion amplitude, not how far the image may travel. The same
      // holds for Rotation's turn count and Anchor's pixel range.
      MMMakeLane(MMPositionControls, @"Position", MMPositionCacheToken, MMPositionMatchEnds, 0,
                 MMShowPositionOSC, @[@0, @1], @[@"X", @"Y"], @"px", 0, @[@0, @0], -200, 200, NO, YES),
      MMMakeLane(MMScaleControls, @"Scale", MMScaleCacheToken, MMScaleMatchEnds, MMScaleProportional,
                 MMShowScaleOSC, @[@2, @3], @[@"X", @"Y"], @"%", 1, @[@100, @100], 0, 400, YES, NO),
      MMMakeLane(MMRotationControls, @"Rotation", MMRotationCacheToken, MMRotationMatchEnds, 0,
                 MMShowRotationOSC, @[@5, @6, @7], @[@"X", @"Y", @"Z"], @"°", 1, @[@0, @0, @0],
                 -180, 180, NO, NO),
      MMMakeLane(MMOpacityControls, @"Opacity", MMOpacityCacheToken, MMOpacityMatchEnds, 0, 0,
                 @[@4], @[@"X"], @"%", 1, @[@100], 0, 100, YES, NO),
      MMMakeLane(MMBlurControls, @"Blur", MMBlurCacheToken, MMBlurMatchEnds, 0, 0,
                 @[@8], @[@"X"], @"px", 0, @[@0], 0, 100, YES, NO),
      MMMakeLane(MMAnchorControls, @"Anchor", MMAnchorCacheToken, MMAnchorMatchEnds, 0,
                 MMShowAnchorOSC, @[@9, @10], @[@"X", @"Y"], @"px", 0, @[@0, @0], -1000, 1000, NO, NO),
    ];
  });
  return lanes;
}

static KFPropertyLane *MMLaneFor(UInt32 parameter) {
  for(KFPropertyLane *lane in MMLanes()) if(lane.parameterID==parameter) return lane;
  return nil;
}
KFPropertyLane *MMPositionLane(void) { return MMLaneFor(MMPositionControls); }
KFPropertyLane *MMScaleLane(void) { return MMLaneFor(MMScaleControls); }
KFPropertyLane *MMRotationLane(void) { return MMLaneFor(MMRotationControls); }
KFPropertyLane *MMOpacityLane(void) { return MMLaneFor(MMOpacityControls); }
KFPropertyLane *MMBlurLane(void) { return MMLaneFor(MMBlurControls); }
KFPropertyLane *MMAnchorLane(void) { return MMLaneFor(MMAnchorControls); }

// The shared packages carry no plugin identifiers, so everything they need to
// reach back into Magic Move is registered here, before any host callback or
// inspector view can run.
@interface MMLaneRegistration : NSObject
@end
@implementation MMLaneRegistration
+ (void)load {
  KFRegisterLanes(MMLanes());
  KFSetHostRefreshParameter(MMHostRefreshToken);
  KFSetExplicitCreationParameter(MMExplicitCreation);
  KFSetDefaults(MMDefaults());
  KFSetShortcutMatcher(^BOOL(unsigned short code, NSEventModifierFlags flags) {
    return MMShortcutMatches(code, flags);
  });
  KFSetRowShortcutAction(^BOOL(id<PROAPIAccessing> manager, NSView *view) {
    return MMToggleMotionBlur(manager, view);
  });
  // On-screen control visibility has no explicit default setting: a new effect
  // starts from whatever was toggled last, so toggling records the preference.
  KFSetBoolSettingPreferenceWriter(^(UInt32 parameterID, BOOL value) {
    if (MMIsOSCVisibilityParameter(parameterID)) MMSaveOSCVisibilityDefault(parameterID, value);
  });
}
@end
