/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFTimingEditor.h"

// What the keypose map asks the editor for. The map owns its geometry and
// proposes times from it; every host time decision, write and menu lives here.
@interface KFTimingEditor (Keyposes)
// Moves the host playhead to an ordinal fraction of the whole lane, the
// inverse of the fraction the map draws its marker at.
- (void)scrubMapToFraction:(double)fraction;
// The timecode of the time a proposed retime would really write, so the drag
// previews the frame it will land on. nil when the keypose cannot move there.
- (NSString *)retimeLabelForIndex:(NSInteger)index proposed:(CMTime)proposed;
- (void)commitRetimeIndex:(NSInteger)index proposed:(CMTime)proposed;
// The map's context menu: the keypose under the pointer, or -1 with the time
// that pointer position falls on, which is where a keypose is added.
- (NSMenu *)keyposeMenuForIndex:(NSInteger)index time:(CMTime)time;
@end
