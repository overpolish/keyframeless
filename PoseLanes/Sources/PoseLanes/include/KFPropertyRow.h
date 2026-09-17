/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
@import InspectorControls;
#import "KFPropertyLane.h"
#import "KFEffect.h"
// The keyboard shortcut a row offers while it is the active view. The plugin
// registers what it does; the rows only route the keypress.
void KFSetRowShortcutAction(BOOL (^action)(id<PROAPIAccessing> manager, NSView *view));

// A vector row builds its own component fields from the lane's labels, unit
// and precision, so a new property needs no new view code.
@interface KFScalarRow : ICSliderRow
- (instancetype)initWithEffect:(KFEffect *)effect lane:(KFPropertyLane *)lane;
@end

@interface KFVectorRow : ICInspectorRow
- (instancetype)initWithEffect:(KFEffect *)effect lane:(KFPropertyLane *)lane;
@end
