/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "ICSliderRow.h"
#import "InspectorTokens.h"

@interface ICSliderRow ()
@property(nonatomic) BOOL sliderInteracting;
@end

@implementation ICSliderRow
- (instancetype)initWithLabel:(NSString *)label identifier:(NSInteger)identifier
               fractionDigits:(NSUInteger)fractionDigits {
  ICInspectorComponent *component = [[ICInspectorComponent alloc]
      initWithIdentifier:identifier label:@"" suffix:@"%" fractionDigits:fractionDigits];
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
  CGFloat labelWidth=round((width < 475 ? width*0.3670886076-11.860759 : width*0.3176696611+10.848616)*2)/2;
  labelWidth=MIN(labelWidth,MAX(0,contentWidth-100));
  self.titleLabel.frame=NSMakeRect(ICInspectorLabelInset,ICInspectorLabelY,MAX(0,labelWidth-27),ICInspectorTextHeight);
  CGFloat suffixWidth=16, valueWidth=54;
  CGFloat valueX=contentWidth-valueWidth-suffixWidth;
  self.sliderView.frame=NSMakeRect(labelWidth,ICInspectorLabelY,MAX(0,valueX-labelWidth-8),ICInspectorTextHeight);
  self.axisLabels.firstObject.hidden=YES;
  self.fields.firstObject.frame=NSMakeRect(valueX,ICInspectorLabelY-ICInspectorValueDrop,valueWidth,ICInspectorTextHeight);
  self.unitLabels.firstObject.frame=NSMakeRect(contentWidth-suffixWidth,ICInspectorLabelY,suffixWidth,ICInspectorTextHeight);
}
@end
