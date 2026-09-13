/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import <AppKit/AppKit.h>
#import <assert.h>
#import <math.h>
#import "InspectorControls.h"

@interface ICValueTextField (InspectorControlsTests)
- (void)styleFieldEditor;
- (void)scrubBy:(double)delta;
@end

@interface ICTestEditorField : ICValueTextField
@property(nonatomic, strong) NSTextView *testEditor;
@end

@implementation ICTestEditorField
- (NSText *)currentEditor { return self.testEditor; }
@end

@interface ICBoundedField : ICValueTextField
@property(nonatomic) NSUInteger commits;
@end
@implementation ICBoundedField
- (BOOL)sendAction:(SEL)action to:(id)target {
  (void)action; (void)target;
  self.commits++; return YES;
}
@end

@interface ICTrackingInspectorRow : ICInspectorRow
@property(nonatomic) BOOL dirtied;
@end

@implementation ICTrackingInspectorRow
- (void)setNeedsDisplay:(BOOL)needsDisplay {
  if (needsDisplay) self.dirtied = YES;
  [super setNeedsDisplay:needsDisplay];
}
@end

static void testScrubBounds(void) {
  ICBoundedField *field=[ICBoundedField valueField];
  NSNumberFormatter *format=[NSNumberFormatter new];
  format.minimum=@0; format.maximum=@60; field.formatter=format;
  field.doubleValue=0.02;
  [field scrubBy:-0.1]; assert(field.doubleValue==0 && field.commits==1);
  for(int i=0;i<20;i++) [field scrubBy:-10];
  assert(field.doubleValue==0 && field.commits==1);
  // Reversing direction immediately leaves the limit; no accumulated overshoot.
  [field scrubBy:0.01]; assert(fabs(field.doubleValue-0.01)<1e-9 && field.commits==2);
  [field scrubBy:100]; assert(field.doubleValue==60 && field.commits==3);
  [field scrubBy:100]; assert(field.doubleValue==60 && field.commits==3);
  [field scrubBy:-0.01]; assert(fabs(field.doubleValue-59.99)<1e-9);
  format.minimum=@(-200); format.maximum=@200;
  field.doubleValue=0; [field scrubBy:-1]; assert(field.doubleValue==-1);
}

static void assertRGB(NSColor *color, CGFloat red, CGFloat green, CGFloat blue,
                      CGFloat alpha, CGFloat tolerance) {
  NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  assert(rgb != nil);
  assert(fabs(rgb.redComponent - red) < tolerance);
  assert(fabs(rgb.greenComponent - green) < tolerance);
  assert(fabs(rgb.blueComponent - blue) < tolerance);
  assert(fabs(rgb.alphaComponent - alpha) < tolerance);
}

static void assertLayout(ICInspectorRow *row, CGFloat width,
                         CGFloat *previousFieldWidth) {
  row.frame = NSMakeRect(0, 0, width, ICInspectorRowHeight);
  [row setNeedsLayout:YES];
  [row layoutSubtreeIfNeeded];
  assert(row.frame.size.height == ICInspectorRowHeight);
  for (NSUInteger i = 0; i < row.fields.count; ++i) {
    NSRect field = row.fields[i].frame;
    NSRect axis = row.axisLabels[i].frame;
    NSRect unit = row.unitLabels[i].frame;
    assert(NSWidth(field) > 0);
    assert(NSMinX(field) >= NSMaxX(axis));
    assert(NSMaxX(field) <= NSMinX(unit));
    assert(NSMaxX(unit) <= width - ICInspectorHostGutter);
    if (i > 0) assert(NSMinX(axis) > NSMaxX(row.unitLabels[i - 1].frame));
    if (previousFieldWidth && i == 0) {
      assert(NSWidth(field) > *previousFieldWidth);
      *previousFieldWidth = NSWidth(field);
    }
  }
  assert(NSMaxX(row.titleLabel.frame) < NSMinX(row.axisLabels.firstObject.frame));
}

// Exercise the real row drawing, not a substitute suffix renderer. Only suffixes
// are drawn by drawRect; subviews are intentionally not rendered in this probe.
static void assertSuffixDrawing(ICInspectorRow *row) {
  for(NSTextField *unit in row.unitLabels) {
    assert(unit.superview==nil && unit.trackingAreas.count==0);
    assert([row hitTest:NSMakePoint(NSMidX(unit.frame),NSMidY(unit.frame))]==row);
  }
  NSInteger width=(NSInteger)NSWidth(row.bounds), height=(NSInteger)NSHeight(row.bounds);
  NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
      pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4
      hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  memset(bitmap.bitmapData,0,bitmap.bytesPerRow*height);
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
  [row drawRect:row.bounds];
  [NSGraphicsContext restoreGraphicsState];
  NSUInteger counts[2]={0,0};
  for(NSInteger x=0;x<width;x++) for(NSInteger y=0;y<height;y++) {
    if([bitmap colorAtX:x y:y].alphaComponent<=0.01) continue;
    BOOL inSuffix=NO;
    for(NSUInteger i=0;i<row.unitLabels.count;i++) {
      NSRect frame=row.unitLabels[i].frame;
      if(x>=NSMinX(frame) && x<NSMaxX(frame)) { counts[i]++; inSuffix=YES; }
    }
    assert(inSuffix); // In particular, no suffix pixels enter the host gutter.
  }
  assert(counts[0]>0 && counts[1]>0); // Both px and % remain visible after detaching.
}

static void testKeyposeLinkedPresentation(ICInspectorRow *row) {
  ICTrackingInspectorRow *tracked = [[ICTrackingInspectorRow alloc]
      initWithLabel:row.titleLabel.stringValue components:@[
        [[ICInspectorComponent alloc] initWithIdentifier:1 label:@"X"
            suffix:@"px" fractionDigits:1],
        [[ICInspectorComponent alloc] initWithIdentifier:2 label:@"Y"
            suffix:@"px" fractionDigits:1]] showsLink:YES];
  tracked.frame = NSMakeRect(0, 0, 403, ICInspectorRowHeight);
  [tracked setNeedsLayout:YES]; [tracked layoutSubtreeIfNeeded];
  tracked.dirtied = NO;
  NSRect titleFrame = tracked.titleLabel.frame;
  NSArray<NSValue *> *fieldFrames = [tracked.fields valueForKey:@"frame"];
  NSArray<NSValue *> *axisFrames = [tracked.axisLabels valueForKey:@"frame"];
  NSArray<NSValue *> *unitFrames = [tracked.unitLabels valueForKey:@"frame"];
  NSView *titleHit = [tracked hitTest:NSMakePoint(NSMidX(titleFrame), NSMidY(titleFrame))];
  tracked.keyposeLinked = YES;
  assert(tracked.isKeyposeLinked && tracked.dirtied);
  NSColor *titleColor=tracked.titleLabel.textColor;
  NSArray *components=tracked.componentColors;
  tracked.dirtied=NO;
  tracked.keyposeLinkColor=NSColor.systemOrangeColor;
  assert(tracked.dirtied && [tracked.keyposeLinkColor isEqual:NSColor.systemOrangeColor]);
  tracked.dirtied=NO;
  tracked.keyposeLinkColor=NSColor.systemOrangeColor;
  assert(!tracked.dirtied);
  assert([titleColor isEqual:tracked.titleLabel.textColor] && components==tracked.componentColors);
  assert(NSEqualRects(tracked.titleLabel.frame, titleFrame));
  assert([[tracked.fields valueForKey:@"frame"] isEqualToArray:fieldFrames]);
  assert([[tracked.axisLabels valueForKey:@"frame"] isEqualToArray:axisFrames]);
  assert([[tracked.unitLabels valueForKey:@"frame"] isEqualToArray:unitFrames]);
  assert([tracked hitTest:NSMakePoint(NSMidX(titleFrame), NSMidY(titleFrame))] == titleHit);
  assert([tracked hitTest:NSMakePoint(4, NSMidY(tracked.bounds))] == tracked);
  tracked.dirtied = NO;
  tracked.keyposeLinked = NO;
  assert(!tracked.keyposeLinked && tracked.dirtied);
}

static BOOL rowDisposesWithoutCallbackCycle(void) {
  __weak ICInspectorRow *weakRow = nil;
  @autoreleasepool {
    ICInspectorComponent *component = [[ICInspectorComponent alloc]
        initWithIdentifier:1 label:@"X" suffix:@"px" fractionDigits:1];
    ICInspectorRow *row = [[ICInspectorRow alloc] initWithLabel:@"Temporary"
        components:@[component] showsLink:NO];
    weakRow = row;
    row.onValueCommit = ^(ICValueTextField *field) {
      (void)weakRow;
      (void)field;
    };
  }
  return weakRow == nil;
}

static void testSliderRow(void) {
  ICSliderRow *pixels=[[ICSliderRow alloc] initWithLabel:@"Blur" identifier:45 suffix:@"px" fractionDigits:0];
  assert([pixels.unitLabels.firstObject.stringValue isEqual:@"px"]);
  assert([[(NSNumberFormatter *)pixels.fields.firstObject.formatter stringFromNumber:@12.3] isEqual:@"12"]);

  ICSliderRow *row = [[ICSliderRow alloc] initWithLabel:@"Opacity"
      identifier:44 fractionDigits:1];
  assert(row.fields.count == 1 && row.sliderView != nil);
  assert(row.sliderView.minValue == 0 && row.sliderView.maxValue == 100);
  row.sliderView.enabled = NO;
  assert(!row.sliderView.slider.enabled);
  row.sliderView.enabled = YES;
  assert(row.sliderView.slider.enabled);
  row.fields.firstObject.enabled = YES;
  row.sliderView.doubleValue = 150;
  assert(row.sliderView.doubleValue == 100);
  row.sliderView.doubleValue = -10;
  assert(row.sliderView.doubleValue == 0);

  __block NSUInteger commits = 0, begins = 0, ends = 0;
  row.onValueCommit = ^(ICValueTextField *field) {
    assert(field == row.fields.firstObject); commits++;
  };
  row.onScrubBegin = ^{ begins++; };
  row.onScrubEnd = ^{ ends++; };
  row.fields.firstObject.doubleValue = 150;
  [row.fields.firstObject sendAction:row.fields.firstObject.action
                                  to:row.fields.firstObject.target];
  assert(row.fields.firstObject.doubleValue == 100 && row.sliderView.doubleValue == 100);
  row.fields.firstObject.doubleValue = 37.5;
  [row.fields.firstObject sendAction:row.fields.firstObject.action
                                  to:row.fields.firstObject.target];
  assert(row.sliderView.doubleValue == 37.5 && commits == 2);
  row.sliderView.doubleValue = 62.5;
  IMP action = [row.sliderView.slider.target methodForSelector:row.sliderView.slider.action];
  ((void (*)(id, SEL, id))action)(row.sliderView.slider.target,
                                  row.sliderView.slider.action,
                                  row.sliderView.slider);
  assert(row.fields.firstObject.doubleValue == 62.5 && commits == 3);
  row.sliderView.onDragBegin(); row.sliderView.onDragEnd();
  assert(begins == 1 && ends == 1 && row.interacting == NO);

  row.frame = NSMakeRect(0, 0, 403, ICInspectorRowHeight);
  [row setNeedsLayout:YES]; [row layoutSubtreeIfNeeded];
  assert(NSWidth(row.sliderView.frame) > 0);
  assert(NSMaxX(row.fields.firstObject.frame) <= NSMinX(row.unitLabels.firstObject.frame));
  assert(NSMaxX(row.unitLabels.firstObject.frame) <= 403 - ICInspectorHostGutter);
}

static NSEvent *contextEvent(NSEventType type, NSEventModifierFlags flags) {
  return [NSEvent mouseEventWithType:type location:NSMakePoint(4, 4)
      modifierFlags:flags timestamp:0 windowNumber:0 context:nil eventNumber:0
      clickCount:1 pressure:1];
}

static void testTitleMenuScope(ICInspectorRow *row) {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Title menu"];
  __block NSUInteger invocations = 0;
  row.titleMenuProvider = ^NSMenu *{ invocations++; return menu; };
  NSEvent *rightClick = contextEvent(NSEventTypeRightMouseDown, 0);
  NSEvent *controlClick = contextEvent(NSEventTypeLeftMouseDown, NSEventModifierFlagControl);
  NSEvent *leftClick = contextEvent(NSEventTypeLeftMouseDown, 0);
  assert([row.titleLabel menuForEvent:rightClick] == menu && invocations == 1);
  assert([row.titleLabel menuForEvent:controlClick] == menu && invocations == 2);
  assert([row.titleLabel menuForEvent:leftClick] == nil && invocations == 2);
  for (ICValueTextField *field in row.fields)
    assert([field menuForEvent:rightClick] == nil);
  for (NSTextField *axis in row.axisLabels)
    assert([axis menuForEvent:rightClick] == nil);
  assert([row menuForEvent:rightClick] == nil);
  assert(invocations == 2);
  row.titleMenuProvider = nil;
  assert([row.titleLabel menuForEvent:rightClick] == nil);
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];

    ICInspectorComponent *x = [[ICInspectorComponent alloc]
        initWithIdentifier:101 label:@"X" suffix:@"px" fractionDigits:2];
    ICInspectorComponent *y = [[ICInspectorComponent alloc]
        initWithIdentifier:-77 label:@"Y" suffix:@"%" fractionDigits:4];
    assert(x.identifier == 101 && [x.label isEqualToString:@"X"] &&
           [x.suffix isEqualToString:@"px"] && x.fractionDigits == 2);
    assert(y.identifier == -77 && [y.label isEqualToString:@"Y"] &&
           [y.suffix isEqualToString:@"%"] && y.fractionDigits == 4);

    ICInspectorRow *row = [[ICInspectorRow alloc] initWithLabel:@"Position"
        components:@[x, y] showsLink:YES];
    assert(row.fields.count == 2 && row.axisLabels.count == 2 &&
           row.unitLabels.count == 2 && row.linkButton != nil);
    assert(row.fields[0].tag == 101 && row.fields[1].tag == -77);
    for (ICValueTextField *field in row.fields)
      assert(!field.enabled && field.stringValue.length == 0 && field.objectValue == nil);
    assert(!row.linkButton.enabled);
    NSFont *valueFont=row.fields[0].font, *decorationFont=row.unitLabels[0].font;
    NSRect fieldFrame=row.fields[0].frame;
    row.componentColors=@[NSColor.redColor,NSColor.greenColor];
    row.selected=YES;
    row.componentColorsVisible=YES;
    assert([row.titleLabel.font isEqual:ICInspectorTokens.selectedLabelFont]);
    assert([row.titleLabel.textColor isEqual:ICInspectorTokens.accentMatchingHost]);
    assert([row.fields[0].font isEqual:valueFont] && [row.unitLabels[0].font isEqual:decorationFont]);
    assert(NSEqualRects(row.fields[0].frame,fieldFrame));
    assert([row.axisLabels[0].textColor isEqual:NSColor.redColor]);
    assert([row.axisLabels[1].textColor isEqual:NSColor.greenColor]);
    assert([row.unitLabels[0].textColor isEqual:ICInspectorTokens.decorationColor]);
    row.componentColors=@[NSColor.blueColor];
    assert([row.axisLabels[0].textColor isEqual:NSColor.blueColor]);
    assert([row.axisLabels[1].textColor isEqual:ICInspectorTokens.decorationColor]);
    row.selected=NO;
    assert([row.axisLabels[0].textColor isEqual:NSColor.blueColor]);
    assert([row.unitLabels[0].textColor isEqual:ICInspectorTokens.decorationColor]);
    row.componentColorsVisible=NO;
    assert([row.axisLabels[0].textColor isEqual:ICInspectorTokens.decorationColor]);
    assert([row.titleLabel.font isEqual:ICInspectorTokens.labelFont]);
    assert([row.titleLabel.textColor isEqual:ICInspectorTokens.labelColor]);
    testTitleMenuScope(row);
    NSMenuItem *toggleItem=[[NSMenuItem alloc] initWithTitle:@"Scale" action:nil keyEquivalent:@""];
    ICMenuToggleView *toggle=[[ICMenuToggleView alloc] initWithMenuItem:toggleItem];
    assert(toggle.focusRingType==NSFocusRingTypeNone);
    assert(!toggle.bordered);
    NSBitmapImageRep *hoverBitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:180 pixelsHigh:22 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    for (NSNumber *highlight in @[@NO,@YES]) {
      memset(hoverBitmap.bitmapData,0,hoverBitmap.bytesPerRow*22);
      [toggle highlight:highlight.boolValue];
      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:hoverBitmap];
      [toggle drawRect:toggle.bounds];
      [NSGraphicsContext restoreGraphicsState];
      assert(([hoverBitmap colorAtX:150 y:11].alphaComponent > 0.5)==highlight.boolValue);
    }

    row.fields[0].doubleValue = 12.3456;
    assert(fabs(row.fields[0].doubleValue - 12.3456) < 1e-12);
    assert([row.fields[0].stringValue isEqualToString:@"12.35"]);
    row.fields[1].doubleValue = 12.34567;
    assert(fabs(row.fields[1].doubleValue - 12.34567) < 1e-12);
    assert([row.fields[1].stringValue isEqualToString:@"12.3457"]);

    __block NSUInteger commits = 0, begins = 0, ends = 0, links = 0;
    __weak ICInspectorRow *weakRow = row;
    row.onValueCommit = ^(ICValueTextField *field) {
      assert(field == weakRow.fields[0]); commits++;
    };
    row.onScrubBegin = ^{ begins++; };
    row.onScrubEnd = ^{ ends++; };
    row.onLinkToggle = ^(NSButton *button) {
      assert(button == weakRow.linkButton); links++;
    };
    [row.fields[0] sendAction:row.fields[0].action to:row.fields[0].target];
    assert(commits == 1);
    row.fields[0].onScrubBegin(); row.fields[0].onScrubEnd();
    assert(begins == 1 && ends == 1);
    [row performSelector:@selector(linkTapped:) withObject:row.linkButton];
    assert(links == 1);

    CGFloat previous = 0;
    for (NSNumber *width in @[@320, @403, @500]) {
      assertLayout(row, width.doubleValue, &previous);
      assertSuffixDrawing(row);
    }
    CGFloat glyphCenter = NSMaxY(row.titleLabel.frame) -
        row.titleLabel.firstBaselineOffsetFromTop + row.titleLabel.font.capHeight / 2;
    assert(fabs(NSMidY(row.linkButton.frame) - glyphCenter) <= 0.25);
    testKeyposeLinkedPresentation(row);

    row.selected=YES;
    row.componentColors=ICInspectorTokens.curveColors;
    row.componentColorsVisible=YES;
    row.enabled=NO;
    assertRGB(row.titleLabel.textColor,82.0/255,82.0/255,82.0/255,1,1e-6);
    for (NSTextField *field in row.fields) {
      assert(!field.enabled);
      assertRGB(field.textColor,82.0/255,82.0/255,82.0/255,1,1e-6);
    }
    for (NSTextField *decoration in [row.axisLabels arrayByAddingObjectsFromArray:row.unitLabels])
      assertRGB(decoration.textColor,82.0/255,82.0/255,82.0/255,1,1e-6);
    row.selected=NO; row.selected=YES;
    assert([row.titleLabel.textColor isEqual:ICInspectorTokens.disabledTextColor]);
    row.enabled=YES;
    assert([row.titleLabel.textColor isEqual:ICInspectorTokens.accentMatchingHost]);
    assert([row.axisLabels[0].textColor isEqual:ICInspectorTokens.curveColors[0]]);
    assert([row.unitLabels[0].textColor isEqual:ICInspectorTokens.decorationColor]);
    assert([row.fields[0].textColor isEqual:ICInspectorTokens.valueColor]);


    ICTestEditorField *styled = [ICTestEditorField valueField];
    styled.testEditor = [NSTextView new];
    [styled styleFieldEditor];
    assertRGB(styled.testEditor.insertionPointColor, 0x5B/255.0, 0x5C/255.0,
              0xE9/255.0, 1, 1e-6);
    assertRGB(styled.testEditor.selectedTextAttributes[NSBackgroundColorAttributeName],
              0x5B/255.0, 0x5C/255.0, 0xE9/255.0, 0.3, 1e-6);

    [row removeFromSuperview];
    row = nil;
    assert(rowDisposesWithoutCallbackCycle());
    ICPopUpButton *popup=[[ICPopUpButton alloc] initWithFrame:NSMakeRect(0,0,140,18) pullsDown:NO];
    [popup addItemsWithTitles:@[@"None",@"Wave",@"Handheld"]];
    [popup selectItemAtIndex:2];
    assert(popup.indexOfSelectedItem==2 && [popup.title isEqualToString:@"Handheld"]);
    assert(!popup.bordered && popup.alignment==NSTextAlignmentRight);
    assert(popup.controlSize==NSControlSizeRegular);
    assert([popup.font isEqual:[NSFont menuFontOfSize:0]]);
    assert([popup.menu.font isEqual:[NSFont menuFontOfSize:0]]);
    assert(((NSPopUpButtonCell *)popup.cell).arrowPosition==NSPopUpNoArrow);
    popup.selectedItem.image=[NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:nil];
    assert(popup.selectedItem.image);
    popup.enabled=NO;
    NSImage *popupImage=[[NSImage alloc] initWithSize:popup.frame.size];
    [popupImage lockFocus];
    [popup.cell drawWithFrame:popup.bounds inView:popup];
    [popupImage unlockFocus];
    assert(!popup.enabled && popup.indexOfSelectedItem==2);
    popup.enabled=YES;
    // A stale native mark must not survive programmatic or cell-level selection.
    popup.itemArray[0].state=NSControlStateValueOn;
    [popup selectItemAtIndex:1];
    for (NSMenuItem *item in popup.itemArray)
      assert(item.state==(item==popup.selectedItem ? NSControlStateValueOn : NSControlStateValueOff));
    [(NSPopUpButtonCell *)popup.cell selectItem:popup.itemArray[2]];
    for (NSMenuItem *item in popup.itemArray)
      assert(item.state==(item==popup.selectedItem ? NSControlStateValueOn : NSControlStateValueOff));
    [popup selectItemAtIndex:1];
    assert([popup.title isEqualToString:@"Wave"]);
    testScrubBounds();
    testSliderRow();
    puts("InspectorControls: configuration, blank state, callbacks, precision, layout, styling, and disposal passed");
  }
  return 0;
}
