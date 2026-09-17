/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFTimingEditor.h"
#import "KFTimingEditorModel.h"

// Editing the displayed gap: the context menus that read and write creation
// defaults, and the single host write path every control funnels through with
// its action and undo group.
@interface KFTimingEditor (Editing)
- (NSMenu *)motionContextMenu:(BOOL)controls;
- (NSMenu *)defaultContextMenu:(KFInspectorSetting)setting;
- (void)randomizeMotionSeed:(id)sender;
- (void)menuChanged:(NSPopUpButton *)menu;
- (void)availableChanged:(NSButton *)button;
// One undo group for a whole scrub, so a drag is a single history entry.
- (void)beginScrub;
- (void)endScrub;
- (void)writeSetting:(KFInspectorSetting)setting value:(double)value;
- (void)writeSetting:(KFInspectorSetting)setting value:(double)value parameter:(UInt32)parameter
                time:(CMTime)time refreshHost:(BOOL)refreshHost;
@end
