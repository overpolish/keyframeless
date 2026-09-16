/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "OSCViewerControl_Private.h"

// The anchor square: the handle on the render's pivot, hidden by default and
// dragged to move that pivot. Split out because it owns its own glyph and hit
// test, none of which the box outline and scale handles share.
@interface OSCViewerControl (Anchor)
// Appends the square's two triangles for this tick, or NO when it is hidden.
// `surface` is the destination surface, whose size lays out canvas space;
// `activePart` is the host's, so a dragged square keeps its highlight.
- (BOOL)appendAnchorSquare:(NSMutableData *)vertices pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
                   surface:(CGSize)surface activePart:(NSInteger)activePart atTime:(CMTime)time;
// Whether the pointer is on the square. A hidden square is not hit at all.
- (BOOL)anchorAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize atTime:(CMTime)time;
@end
