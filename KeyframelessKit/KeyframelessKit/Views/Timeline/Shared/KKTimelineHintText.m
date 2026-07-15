/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineHintText.h"

#import "KKTokens.h"
#import "NSColor+KKColors.h"

void KKTimelineDrawCenteredHint(NSString *text, NSRect rect) {
  if (!text.length)
    return;
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.4],
  };
  NSSize sz = [text sizeWithAttributes:attrs];
  [text drawAtPoint:NSMakePoint(NSMidX(rect) - sz.width / 2.0,
                                NSMidY(rect) - sz.height / 2.0)
      withAttributes:attrs];
}
