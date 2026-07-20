/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopoverBackground.h"
#import "NSColor+KKColors.h"
#import <QuartzCore/QuartzCore.h>

// macOS 26 renders popovers with a liquid-glass fill that shows the content
// behind the window straight through, leaving text and controls illegible.
// Rather than fight the private NSPopoverFrame / GlassView hierarchy (whose
// subview names vary by OS build), paint OUR content view: it always sits on
// top of the glass, so a flat inspector-matched fill here guarantees a legible
// surface. The popover frame clips our corners, so no rounding needed.
void KKApplyPopoverBackground(NSView *view) {
  if (!view)
    return;
  view.wantsLayer = YES;
  view.layer.backgroundColor =
      [[NSColor inspectorBackground] colorWithAlphaComponent:0.5].CGColor;

  // Drop the glass chrome behind us where macOS 26 exposes it, so no frosted
  // rim bleeds around the fill. Deferred: the frame isn't wired up until after
  // the popover finishes presenting.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSView *current = view;
        NSView *popoverFrame = nil;
        while (current) {
          if ([NSStringFromClass([current class])
                  hasPrefix:@"NSPopoverFrame"]) {
            popoverFrame = current;
            break;
          }
          current = current.superview;
        }
        if (!popoverFrame)
          return;
        CGColorRef fill =
            [[NSColor inspectorBackground] colorWithAlphaComponent:0.5].CGColor;
        for (NSView *sub in popoverFrame.subviews) {
          if (![NSStringFromClass([sub class]) containsString:@"GlassView"])
            continue;
          sub.wantsLayer = YES;
          sub.layer.backgroundColor = fill;
          for (NSView *glassSub in sub.subviews) {
            glassSub.wantsLayer = YES;
            NSString *name = NSStringFromClass([glassSub class]);
            if ([name containsString:@"CoreHostingView"])
              glassSub.layer.opacity = 0;
            else if ([name containsString:@"ContentHolderView"])
              glassSub.layer.backgroundColor = fill;
          }
          break;
        }
      });
}
