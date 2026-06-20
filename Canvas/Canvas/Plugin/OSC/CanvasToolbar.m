/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasToolbar.h"
#import "CanvasLocalized.h"
#import <KeyframelessKit/KKToolbar.h>

static const NSInteger kCanvasGridSpacingPresets[] = {10, 20, 50, 100};

static KKToolbarItem *itemForTag(KKToolbar *bar, NSInteger tag) {
  for (KKToolbarItem *it in bar.items)
    if (it.tag == tag)
      return it;
  return nil;
}

void CanvasToolbarApplyState(KKToolbar *toolbar, NSInteger tool, BOOL gridOn,
                             BOOL adaptive, BOOL snap, NSInteger spacing) {
  if (!toolbar)
    return;
  NSMutableArray<NSNumber *> *active = [NSMutableArray arrayWithObject:@(tool)];
  if (gridOn)
    [active addObject:@(CanvasToolbarGrid)];
  if (adaptive)
    [active addObject:@(CanvasToolbarGridAdaptive)];
  if (snap)
    [active addObject:@(CanvasToolbarSnap)];
  toolbar.activeTags = active;

  itemForTag(toolbar, CanvasToolbarGridAdaptive).iconName =
      adaptive ? @"squareshape.split.2x2.dotted" : @"squareshape.split.2x2";
  itemForTag(toolbar, CanvasToolbarGridSpacing).shortcutLabel =
      [NSString stringWithFormat:@"%ld", (long)(spacing > 0 ? spacing : 10)];
}

NSInteger CanvasToolbarNextGridSpacing(NSInteger current) {
  NSInteger count =
      sizeof(kCanvasGridSpacingPresets) / sizeof(kCanvasGridSpacingPresets[0]);
  for (NSInteger i = 0; i < count; i++)
    if (kCanvasGridSpacingPresets[i] == current)
      return kCanvasGridSpacingPresets[(i + 1) % count];
  return kCanvasGridSpacingPresets[0];
}

CanvasToolbarTag CanvasToolbarToolTagForLetter(unichar letter) {
  switch (letter) {
  case 'v':
    return CanvasToolbarToolCursor;
  case 'x':
    return CanvasToolbarToolPen;
  case 'b':
    return CanvasToolbarToolRect;
  case 'g':
    return CanvasToolbarToolEllipse;
  default:
    return 0;
  }
}

KKToolbar *CanvasMakeToolbar(id<PROAPIAccessing> apiManager) {
  // Drag handle on the left: a subtle full-size grip, dim tint, vertically
  // centred (no shortcut label).
  KKToolbarItem *handle = [KKToolbarItem itemWithIcon:@"line.3.horizontal"
                                                  tag:CanvasToolbarDragHandle
                                        shortcutLabel:nil];
  handle.iconColor = [NSColor colorWithWhite:1.0 alpha:0.4];
  NSArray<KKToolbarItem *> *items = @[
    handle,
    [KKToolbarItem itemWithIcon:@"cursorarrow"
                            tag:CanvasToolbarToolCursor
                  shortcutLabel:@"^V"],
    [KKToolbarItem itemWithIcon:@"pencil.and.outline"
                            tag:CanvasToolbarToolPen
                  shortcutLabel:@"^X"],
    [KKToolbarItem itemWithIcon:@"rectangle.fill"
                            tag:CanvasToolbarToolRect
                  shortcutLabel:@"^B"],
    [KKToolbarItem itemWithIcon:@"circle.fill"
                            tag:CanvasToolbarToolEllipse
                  shortcutLabel:@"^G"],
    [KKToolbarItem separator],
    // Grid toggles are icon-only (state shown by highlight + the adaptive icon
    // swap); meaning comes from the localized hover tooltips. Spacing keeps its
    // NUMBER (data, not a translatable word).
    [KKToolbarItem itemWithIcon:@"grid" tag:CanvasToolbarGrid shortcutLabel:nil],
    [KKToolbarItem itemWithIcon:@"squareshape.split.2x2.dotted"
                            tag:CanvasToolbarGridAdaptive
                  shortcutLabel:nil],
    [KKToolbarItem itemWithIcon:@"digitalcrown.arrow.clockwise.fill"
                            tag:CanvasToolbarGridSpacing
                  shortcutLabel:@"10"],
    [KKToolbarItem itemWithIcon:@"dot.squareshape.split.2x2"
                            tag:CanvasToolbarSnap
                  shortcutLabel:nil],
  ];
  KKToolbar *bar = [[KKToolbar alloc] initWithAPIManager:apiManager items:items];
  bar.activeTag = 0;

  // Localized hover tooltips carry each button's meaning (the icon-only grid
  // buttons have no inline word label). No width constraint, so any language fits.
  handle.tooltip = CLoc(@"Move toolbar", @"Toolbar drag-handle tooltip");
  itemForTag(bar, CanvasToolbarToolCursor).tooltip =
      CLoc(@"Select tool", @"Toolbar tooltip: selection tool");
  itemForTag(bar, CanvasToolbarToolPen).tooltip =
      CLoc(@"Pen tool", @"Toolbar tooltip: pen tool");
  itemForTag(bar, CanvasToolbarToolRect).tooltip =
      CLoc(@"Rectangle tool", @"Toolbar tooltip: rectangle tool");
  itemForTag(bar, CanvasToolbarToolEllipse).tooltip =
      CLoc(@"Ellipse tool", @"Toolbar tooltip: ellipse tool");
  itemForTag(bar, CanvasToolbarGrid).tooltip =
      CLoc(@"Show grid", @"Toolbar tooltip: toggle the grid overlay");
  itemForTag(bar, CanvasToolbarGridAdaptive).tooltip =
      CLoc(@"Auto grid spacing", @"Toolbar tooltip: automatic grid spacing");
  itemForTag(bar, CanvasToolbarGridSpacing).tooltip =
      CLoc(@"Grid cell size", @"Toolbar tooltip: grid cell size");
  itemForTag(bar, CanvasToolbarSnap).tooltip =
      CLoc(@"Snap to grid", @"Toolbar tooltip: snap drags to the grid");
  return bar;
}
