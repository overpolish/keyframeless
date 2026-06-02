/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCurvePillView.h"
#import "KKSegmentEditView+Guide.h"
#import "KKSegmentEditView_Private.h"

@implementation KKSegmentEditView (Guide)

- (NSRect)guideCurvePillScreenRectForCurve:(NSInteger)curveType {
  NSWindow *w = self.window;
  KKCurvePillView *pills = [self _guidePillsView];
  if (!w || !pills || curveType < 0 || curveType >= pills.pillCount)
    return NSZeroRect;
  NSRect pr = [pills pillRectForIndex:curveType];
  if (NSIsEmptyRect(pr))
    return NSZeroRect;
  NSRect inView = [pills convertRect:pr toView:nil];
  return [w convertRectToScreen:inView];
}

@end
