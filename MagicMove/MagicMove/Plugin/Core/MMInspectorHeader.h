/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
@import InspectorControls;
#import <FxPlug/FxPlugSDK.h>
extern NSNotificationName const MMHeaderSettingsChanged;
@interface MMInspectorHeader : ICInspectorHeader
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager;
- (void)refreshSettings;
- (NSMenu *)settingsMenu;
- (NSMenu *)motionBlurMenu;
@end
