/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMOSCShaderTypes.h"
#import "MMPropertyLane.h"
#import "MagicMoveOSC_Private.h"

@interface MagicMoveOSC ()
@property(nonatomic) BOOL showAnchor;
@property(nonatomic) BOOL hoveredAnchor;
@property(nonatomic) MMPropertyPoseCache *anchorCache;
@end

// The anchor square: the handle on the render's pivot, hidden by default and
// dragged to move that pivot. Split out because it owns its own glyph, hit test
// and write path, none of which the box outline and scale handles share.
@interface MagicMoveOSC (Anchor)
// Appends the square's two triangles for this tick, or NO when it is hidden.
// `surface` is the destination surface, whose size lays out canvas space;
// `activePart` is the host's, so a dragged square keeps its highlight.
- (BOOL)appendAnchorSquare:(NSMutableData *)vertices pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
                   surface:(CGSize)surface activePart:(NSInteger)activePart atTime:(CMTime)time;
// Whether the pointer is on the square. A hidden square is not hit at all.
- (BOOL)anchorAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize atTime:(CMTime)time;
// Captures the cache the drag writes through.
- (void)beginAnchorDragAtTime:(CMTime)time;
// One tick: the press anchor moved by `deltaPixels`, in one host write.
- (BOOL)dragAnchorFromPose:(OSCBoxPose)press byPixels:(CGPoint)deltaPixels atTime:(CMTime)time;
- (void)clearAnchorDrag;
@end
