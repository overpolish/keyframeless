/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import <AppKit/AppKit.h>
#import <assert.h>
#import <math.h>
#import "InspectorControls.h"

@interface ICValueTextField (InspectorControlsTests)
- (void)styleFieldEditor;
@end

@interface ICTestEditorField : ICValueTextField
@property(nonatomic, strong) NSTextView *testEditor;
@end

@implementation ICTestEditorField
- (NSText *)currentEditor { return self.testEditor; }
@end

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
    for (NSNumber *width in @[@320, @403, @500])
      assertLayout(row, width.doubleValue, &previous);
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
    puts("InspectorControls: configuration, blank state, callbacks, precision, layout, styling, and disposal passed");
  }
  return 0;
}
