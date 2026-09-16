/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCViewerControl+Anchor.h"
#import <math.h>

@implementation OSCViewerControl (Anchor)

- (BOOL)appendAnchorSquare:(NSMutableData *)vertices pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
                   surface:(CGSize)surface activePart:(NSInteger)activePart atTime:(CMTime)time {
  BOOL showAnchor = self.showAnchor;
  if (![self elementVisible:OSCViewerElementAnchor cached:&showAnchor atTime:time]) return NO;
  self.showAnchor = showAnchor;
  BOOL active = activePart == OSCBoxPartAnchor || self.hoveredAnchor;
  RSOSCSquareStyle style = {.halfExtent = (float)OSCAnchorHalfExtent + (active ? OSCViewerActiveGlyphGrowth : 0),
                            .cornerRadius = OSCAnchorCornerRadius,
                            .outlineWidth = OSCAnchorOutlineWidth,
                            .shadowOffset = OSCAnchorShadowOffset,
                            .shadowRadius = OSCAnchorShadowRadius};
  RSOSCAppendSquare(vertices, RSOSCMetalPoint([self pivotCanvasForPose:pose imageSize:imageSize], surface), style,
                    OSCViewerGlyphFill, OSCViewerGlyphStroke);
  return YES;
}

- (BOOL)anchorAtX:(double)x y:(double)y pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize atTime:(CMTime)time {
  BOOL showAnchor = self.showAnchor;
  if (![self elementVisible:OSCViewerElementAnchor cached:&showAnchor atTime:time]) return NO;
  self.showAnchor = showAnchor;
  CGPoint centre = [self pivotCanvasForPose:pose imageSize:imageSize];
  return hypot(x - centre.x, y - centre.y) <= OSCAnchorHitRadius;
}

@end
