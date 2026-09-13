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
    assert([row.axisLabels[0].textColor isEqual:ICInspectorTokens.decorationColor]);
    assert([row.titleLabel.font isEqual:ICInspectorTokens.labelFont]);
    assert([row.titleLabel.textColor isEqual:ICInspectorTokens.labelColor]);

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
    testScrubBounds();
    testSliderRow();
    puts("InspectorControls: configuration, blank state, callbacks, precision, layout, styling, and disposal passed");
  }
  return 0;
}
