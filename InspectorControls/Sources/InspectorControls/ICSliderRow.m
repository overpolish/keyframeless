/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "ICSliderRow.h"
#import "InspectorTokens.h"

@interface ICSliderRow ()
@property(nonatomic) BOOL sliderInteracting;
@end

@implementation ICSliderRow
- (instancetype)initWithLabel:(NSString *)label identifier:(NSInteger)identifier
               fractionDigits:(NSUInteger)fractionDigits {
  return [self initWithLabel:label identifier:identifier suffix:@"%" fractionDigits:fractionDigits];
}
- (instancetype)initWithLabel:(NSString *)label identifier:(NSInteger)identifier suffix:(NSString *)suffix fractionDigits:(NSUInteger)fractionDigits {
  ICInspectorComponent *component = [[ICInspectorComponent alloc]
      initWithIdentifier:identifier label:@"" suffix:suffix fractionDigits:fractionDigits];
  if ((self = [super initWithLabel:label components:@[ component] showsLink:NO])) {
    _sliderView = [ICSliderView styledSlider];
    _sliderView.minValue = 0; _sliderView.maxValue = 100;
    _sliderView.doubleValue = 100;
    [self addSubview:_sliderView];
    __weak typeof(self) weakSelf = self;
    _sliderView.target = self;
    _sliderView.action = @selector(sliderChanged:);
    _sliderView.onDragBegin = ^{ ICSliderRow *row=weakSelf; if (!row) return; row.sliderInteracting=YES; if(row.onScrubBegin) row.onScrubBegin(); };
    _sliderView.onDragEnd = ^{ ICSliderRow *row=weakSelf; if (!row) return; row.sliderInteracting=NO; if(row.onScrubEnd) row.onScrubEnd(); };
    self.onValueCommit = nil;
  }
  return self;
}
- (BOOL)interacting { return self.sliderInteracting || [super interacting]; }
- (void)sliderChanged:(ICSliderView *)sender {
  ICValueTextField *field=self.fields.firstObject;
  field.doubleValue=sender.doubleValue;
  if (self.onValueCommit) self.onValueCommit(field);
}
- (void)commitField:(ICValueTextField *)field {
  self.sliderView.doubleValue=field.doubleValue;
  field.doubleValue=self.sliderView.doubleValue;
  if (self.onValueCommit) self.onValueCommit(field);
}
- (void)layout {
  [super layout];
  CGFloat width=NSWidth(self.bounds), contentWidth=MAX(0,width-ICInspectorHostGutter);
  CGFloat labelWidth=ICInspectorLabelColumnWidth(width,100);
  self.titleLabel.frame=NSMakeRect(ICInspectorLabelInset,ICInspectorLabelY,MAX(0,labelWidth-27),ICInspectorTextHeight);
  CGFloat valueX=MAX(labelWidth,contentWidth-ICInspectorSliderValueSlotWidth);
  ICInspectorValueLayout valueLayout=ICInspectorLayoutValue(valueX,contentWidth);
  self.sliderView.frame=NSMakeRect(labelWidth,ICInspectorLabelY,MAX(0,valueX-labelWidth-ICInspectorSliderValueGap),ICInspectorTextHeight);
  self.axisLabels.firstObject.hidden=YES;
  self.fields.firstObject.frame=valueLayout.value;
  self.unitLabels.firstObject.frame=valueLayout.suffix;
}
@end
