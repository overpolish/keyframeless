/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMShortcut.h"
#import "Constants.h"

NSString *MMMotionBlurShortcutKey(void) { return @"m"; }
NSEventModifierFlags MMMotionBlurShortcutModifiers(void) { return NSEventModifierFlagControl | NSEventModifierFlagOption; }
NSString *MMMotionBlurShortcutDisplay(void) { return @"⌃⌥M"; }

// Binding is separate from routing/capture so a settings recorder can replace it.
BOOL MMShortcutMatches(unsigned short code, NSEventModifierFlags flags) {
  NSEventModifierFlags meaningful = NSEventModifierFlagCommand | NSEventModifierFlagControl |
      NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction;
  return code == 46 && (flags & meaningful) == MMMotionBlurShortcutModifiers();
}
BOOL MMToggleMotionBlur(id<PROAPIAccessing> manager, id sender) {
  id<FxCustomParameterActionAPI_v4> action = [manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return NO;
  [action startAction:sender];
  @try {
    id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime time = [action currentTime]; BOOL enabled = NO;
    if (!get || !set || !CMTIME_IS_NUMERIC(time) ||
        ![get getBoolValue:&enabled fromParameter:MMMotionBlur atTime:time]) return NO;
    id<FxUndoAPI> undo = [manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped = [undo startUndoGroup:@"Toggle Motion Blur"];
    @try { return [set setBoolValue:!enabled toParameter:MMMotionBlur atTime:time]; }
    @finally { if (grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:sender]; }
}
