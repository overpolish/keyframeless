/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFInspectorClock.h"
#import "KFTimingEditor.h"

// Reading host state into the controls and the graph. Split out because the
// refresh tick owns which parameter is displayed, what the graph plots and
// when it is worth replotting, while the editor itself keeps construction,
// layout and the notification of what it graphs.
@interface KFTimingEditor (Refresh) <KFInspectorRefreshable>
- (void)setEditorsEnabled:(BOOL)enabled;
// Moves the host playhead to a fraction of the plotted range.
- (void)scrubGraphToFraction:(double)fraction;
// Moves the host playhead onto a keypose the map reported.
- (void)movePlayheadToKeypose:(CMTime)time;
// Opens its own action, for callers outside the refresh clock's tick.
- (void)refresh;
@end
