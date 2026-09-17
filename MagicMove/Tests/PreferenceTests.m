/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MMDefaults.h"
#import <assert.h>
#import <stdio.h>

// The plugin owns the factory values, the validation and the on-screen control
// visibility keys; PoseLanes only reads and writes through the adapter.
static void testFactoryValuesAndValidation(void) {
  for (NSString *key in @[ KFDurationDefaultKey, KFEasingDefaultKey, @"motion.1", @"motion.2", @"motion.3" ])
    assert(KFRestoreFactoryDefault(key));
  assert([KFReadDefault(KFDurationDefaultKey)[@"value"] doubleValue] == 1.2);
  assert([KFReadDefault(KFEasingDefaultKey)[@"value"] integerValue] == MTEasingSmooth);
  assert([KFReadDefault(@"motion.1")[@"amount"] doubleValue] == 1);
  assert([KFReadDefault(@"motion.1")[@"speed"] doubleValue] == 1);

  assert(KFSaveDefault(KFDurationDefaultKey, @{@"value" : @2.5}));
  assert(KFSaveDefault(KFEasingDefaultKey, @{@"value" : @(MTEasingLinear)}));
  // Out-of-range, mistyped and unknown values are refused rather than stored,
  // so a corrupted preference cannot reach a new keyframe.
  assert(!KFSaveDefault(KFDurationDefaultKey, @{@"value" : @(-1)}));
  assert(!KFSaveDefault(KFDurationDefaultKey, @{@"value" : @61}));
  assert(!KFSaveDefault(KFDurationDefaultKey, @{@"value" : @2, @"available" : @YES}));
  assert(!KFSaveDefault(KFEasingDefaultKey, @{@"value" : @1.5}));
  assert(!KFSaveDefault(KFEasingDefaultKey, @{@"value" : @9}));
  assert(!KFSaveDefault(@"motion.1", @{@"amount" : @1, @"speed" : @0}));
  assert(!KFSaveDefault(@"motion.9", @{@"amount" : @1, @"speed" : @1}));
  assert([KFReadDefault(KFDurationDefaultKey)[@"value"] doubleValue] == 2.5);
  for (NSString *key in @[ KFDurationDefaultKey, KFEasingDefaultKey ])
    assert(KFRestoreFactoryDefault(key));
}

// Visibility preferences are per element: the transform controls ship visible
// and the anchor square hidden, because the pivot only matters while it moves.
static void testOSCVisibilityDefaults(void) {
  assert(MMReadOSCVisibilityDefault(MMShowPositionOSC));
  assert(MMReadOSCVisibilityDefault(MMShowScaleOSC));
  assert(MMReadOSCVisibilityDefault(MMShowRotationOSC));
  assert(!MMReadOSCVisibilityDefault(MMShowAnchorOSC));
  assert(MMIsOSCVisibilityParameter(MMShowAnchorOSC));
  assert(!MMIsOSCVisibilityParameter(MMExplicitCreation));
  // A toggle is the default for the next effect, and only for its own element.
  assert(MMSaveOSCVisibilityDefault(MMShowAnchorOSC, YES));
  assert(MMReadOSCVisibilityDefault(MMShowAnchorOSC));
  assert(MMReadOSCVisibilityDefault(MMShowRotationOSC));
  assert(MMSaveOSCVisibilityDefault(MMShowAnchorOSC, NO));
  assert(!MMReadOSCVisibilityDefault(MMShowAnchorOSC));
}

int main(void) {
  @autoreleasepool {
    testFactoryValuesAndValidation();
    testOSCVisibilityDefaults();
    puts("Preferences: factory values, validation and on-screen control visibility defaults passed");
  }
  return 0;
}
