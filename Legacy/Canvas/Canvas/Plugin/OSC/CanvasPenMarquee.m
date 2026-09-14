/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPenMarquee.h"

void CanvasPenMarqueeWalk(CGRect r, CGFloat dash, CGFloat gap,
                          CanvasPenMarqueeSegmentBlock segment) {
  if (!segment)
    return;
  if (!isfinite(CGRectGetMinX(r)) || !isfinite(CGRectGetMaxX(r)) ||
      !isfinite(CGRectGetMinY(r)) || !isfinite(CGRectGetMaxY(r)))
    return;
  CGFloat x0 = floor(CGRectGetMinX(r)) + 0.5;
  CGFloat x1 = floor(CGRectGetMaxX(r)) + 0.5;
  CGFloat y0 = floor(CGRectGetMinY(r)) + 0.5;
  CGFloat y1 = floor(CGRectGetMaxY(r)) + 0.5;
  CGPoint tl = {x0, y0}, tr = {x1, y0}, br = {x1, y1}, bl = {x0, y1};
  CGPoint edges[4][2] = {{tl, tr}, {tr, br}, {br, bl}, {bl, tl}};

  NSUInteger emitted = 0;
  for (int e = 0; e < 4; e++) {
    CGPoint from = edges[e][0], to = edges[e][1];
    CGFloat dx = to.x - from.x, dy = to.y - from.y;
    CGFloat len = hypot(dx, dy);
    if (len < 0.1)
      continue;
    CGFloat nx = dx / len, ny = dy / len;
    CGFloat pos = 0;
    BOOL on = YES;
    while (pos < len && emitted < kCanvasPenMarqueeMaxSegments) {
      CGFloat seg = on ? dash : gap;
      CGFloat end = MIN(pos + seg, len);
      segment(CGPointMake(from.x + nx * pos, from.y + ny * pos),
              CGPointMake(from.x + nx * end, from.y + ny * end), on);
      emitted++;
      pos = end;
      on = !on;
    }
  }
}
