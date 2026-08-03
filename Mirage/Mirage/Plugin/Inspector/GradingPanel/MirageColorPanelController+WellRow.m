/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageColorPanelController.h"

#import <KeyframelessKit/KKTokens.h>

#import "MirageColorPanelController_Internal.h"
#import "MirageLocalized.h"

/// The strip of buttons that act on ONE ring - the slot pair and the
/// click-to-pick eyedropper - sitting inside the well directly above the circle
/// they answer to. In the header they were three glyphs among five, a strip
/// away from the wheel a click in the preview would move a handle on; here the
/// thing they act on is the next thing down.
static const CGFloat kWellRowHeight = 24.0;
static const CGFloat kWellButtonSide = 18.0;

@implementation MirageColorPanelController (WellRow)

// The three buttons that act on ONE HANDLE, inside the well and above the
// ring they answer to rather than up in the header. Every one of them is a
// sentence about the handle currently selected on that circle - aim THIS one,
// add another, take this one away - and from the header strip there was
// nothing saying which of two rings, or which of five glyphs, that was about.
//
// Added to the well before the circles, so a stray click in the row's band
// reaches the button rather than the circle underneath it.
- (void)_buildWellRowInWell:(NSView *)well {
  NSString *fromClip =
      RLoc(@"Set from clip", @"Color panel button: arms a click in the preview "
                             @"that aims the selected handle's controls at the "
                             @"color clicked in the original footage.");
  NSButton *pickSource =
      [self _iconButtonNamed:@"eyedropper.halffull"
                       label:fromClip
                      action:@selector(_togglePickFromClip:)];
  pickSource.toolTip = RLoc(
      @"Click a color in the preview to aim the selected handle at it. The "
      @"color is read from the original clip, not from the graded result.",
      @"Tooltip for the Color panel's click-to-pick button, explaining that "
      @"the sampled color comes from the untouched footage.");
  pickSource.hidden = YES;
  pickSource.autoresizingMask = NSViewNotSizable;
  [well addSubview:pickSource];
  _pickSourceButton = pickSource;

  // Adding and removing an instance of a `#slots` group. Leading the picker, in
  // the order the gesture runs: "+" then a click in the preview is ONE gesture
  // - the new colour is added, selected and armed - so the button that starts
  // it belongs next to the button that would otherwise have to be pressed
  // after.
  //
  // Both are hidden unless the shader declares a repeatable group with a handle
  // on this ring, which no shader written before `#slots` does.
  NSButton *addSlot =
      [self _iconButtonNamed:@"plus"
                       label:RLoc(@"Add", @"Color panel button that adds "
                                          @"another instance of the shader's "
                                          @"repeatable group of controls.")
                      action:@selector(_addSlotInstance:)];
  addSlot.hidden = YES;
  addSlot.autoresizingMask = NSViewNotSizable;
  [well addSubview:addSlot];
  _addSlotButton = addSlot;

  NSButton *removeSlot =
      [self _iconButtonNamed:@"minus"
                       label:RLoc(@"Remove", @"Color panel button that removes "
                                             @"the selected instance of the "
                                             @"shader's repeatable group of "
                                             @"controls.")
                      action:@selector(_removeSlotInstance:)];
  removeSlot.hidden = YES;
  removeSlot.autoresizingMask = NSViewNotSizable;
  [well addSubview:removeSlot];
  _removeSlotButton = removeSlot;
}

/// How tall the in-well button row is: zero unless it has something to show.
///
/// Zero is the case every shader written before `#slots` is in, and it has to
/// leave the panel exactly as it was - the circle's diameter is a function of
/// the panel's height, so a row that reserved space unconditionally would take
/// it out of every wheel in the process.
- (CGFloat)_wellRowHeight {
  BOOL any = (_addSlotButton && !_addSlotButton.hidden) ||
             (_removeSlotButton && !_removeSlotButton.hidden) ||
             (_pickSourceButton && !_pickSourceButton.hidden);
  return any ? kWellRowHeight : 0.0;
}

/// Place whichever of the three are showing, centred over the ring below them.
///
/// Centred rather than pinned to an edge: the row has no title and no other
/// content, so its own centre is what says which circle it belongs to. The
/// order is the order the gesture runs - add, then remove, then aim - and it
/// does not shuffle when one of them goes away, so the button under the pointer
/// stays the button under the pointer.
- (void)_layoutWellRowInRect:(NSRect)row {
  NSMutableArray<NSButton *> *shown = [NSMutableArray array];
  for (NSButton *button in
       @[ _addSlotButton, _removeSlotButton, _pickSourceButton ])
    if (button && !button.hidden)
      [shown addObject:button];
  if (!shown.count)
    return;
  CGFloat total = (CGFloat)shown.count * kWellButtonSide +
                  (CGFloat)(shown.count - 1) * KKPaddingXS;
  CGFloat x = round(NSMidX(row) - total * 0.5);
  CGFloat y = round(NSMinY(row) + (NSHeight(row) - kWellButtonSide) * 0.5);
  for (NSButton *button in shown) {
    button.frame = NSMakeRect(x, y, kWellButtonSide, kWellButtonSide);
    x += kWellButtonSide + KKPaddingXS;
  }
}

@end
