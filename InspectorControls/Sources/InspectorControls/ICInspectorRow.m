/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "ICInspectorRow.h"
#import "InspectorTokens.h"

@implementation ICInspectorComponent
- (instancetype)initWithIdentifier:(NSInteger)identifier label:(NSString *)label
                            suffix:(NSString *)suffix fractionDigits:(NSUInteger)digits {
  if ((self=[super init])) {
    _identifier=identifier; _label=[label copy]; _suffix=[suffix copy]; _fractionDigits=digits;
  }
  return self;
}
@end

@implementation ICInspectorRow
- (instancetype)initWithLabel:(NSString *)label components:(NSArray<ICInspectorComponent *> *)components
                   showsLink:(BOOL)showsLink {
  NSParameterAssert(components.count > 0);
  self=[super initWithFrame:NSMakeRect(0,0,320,ICInspectorRowHeight)];
  if (!self) return nil;
  self.autoresizingMask=NSViewWidthSizable;
  _titleLabel=[NSTextField labelWithString:label];
  _titleLabel.font=ICInspectorTokens.labelFont;
  _titleLabel.textColor=ICInspectorTokens.labelColor;
  [self addSubview:_titleLabel];
  NSMutableArray *fields=[NSMutableArray array], *labels=[NSMutableArray array], *units=[NSMutableArray array];
  __weak ICInspectorRow *weakSelf=self;
  for (ICInspectorComponent *component in components) {
    NSTextField *axis=[NSTextField labelWithString:component.label];
    axis.font=ICInspectorTokens.decorationFont; axis.textColor=ICInspectorTokens.decorationColor;
    NSTextField *unit=[NSTextField labelWithString:component.suffix];
    unit.font=axis.font; unit.textColor=axis.textColor;
    ICValueTextField *field=[ICValueTextField valueField];
    field.tag=component.identifier;
    field.objectValue=nil; field.enabled=NO;
    field.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",label,component.label];
    field.delegate=self; field.target=self; field.action=@selector(commitField:);
    field.onScrubBegin=^{ ICInspectorRow *row=weakSelf; if(row.onScrubBegin) row.onScrubBegin(); };
    field.onScrubEnd=^{ ICInspectorRow *row=weakSelf; if(row.onScrubEnd) row.onScrubEnd(); };
    NSNumberFormatter *formatter=[NSNumberFormatter new];
    formatter.numberStyle=NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator=NO;
    formatter.minimumFractionDigits=component.fractionDigits;
    formatter.maximumFractionDigits=component.fractionDigits;
    field.formatter=formatter;
    [self addSubview:axis]; [self addSubview:unit]; [self addSubview:field];
    [fields addObject:field]; [labels addObject:axis]; [units addObject:unit];
  }
  _fields=[fields copy]; _axisLabels=[labels copy]; _unitLabels=[units copy];
  for (NSUInteger i=1;i<_fields.count;i++) _fields[i-1].nextKeyView=_fields[i];
  if(showsLink) {
    NSImage *image=[NSImage imageWithSystemSymbolName:@"link" accessibilityDescription:nil];
    _linkButton=[NSButton buttonWithImage:image ?: [NSImage new] target:self action:@selector(linkTapped:)];
    _linkButton.bordered=NO; _linkButton.bezelStyle=NSBezelStyleShadowlessSquare;
    _linkButton.imageScaling=NSImageScaleProportionallyDown;
    _linkButton.enabled=NO;
    [self addSubview:_linkButton];
  }
  return self;
}
- (BOOL)interacting {
  for (ICValueTextField *field in self.fields)
    if(field.icEditing || field.icScrubbing || field.currentEditor) return YES;
  return NO;
}
- (void)commitField:(ICValueTextField *)field { if(self.onValueCommit) self.onValueCommit(field); }
- (void)linkTapped:(NSButton *)button { if(self.onLinkToggle) self.onLinkToggle(button); }
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
  return ICValueFieldHandleReturnCommand(self.window,selector) ||
      ICValueFieldHandleTabCommand((NSTextField *)control,selector);
}
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, ICInspectorRowHeight); }
- (void)layout {
  [super layout];
  CGFloat width = NSWidth(self.bounds);
  // Adapted from KKParameterRowView / KKLabelView: leave the host-control
  // gutter clear and inset our own label. Relax column minima in narrow hosts
  // rather than letting the old required constraints overflow the row.
  CGFloat contentWidth = MAX(0, width-ICInspectorHostGutter);
  CGFloat labelWidth = round((width < 475 ? width*0.3670886076-11.860759
      : width*0.3176696611+10.848616)*2)/2;
  labelWidth = MIN(labelWidth, MAX(0,contentWidth - 70*self.fields.count));
  // Add 12 pt to the existing 6 px visible gap between the component groups.
  const CGFloat groupSpacing = ICInspectorGroupSpacing;
  CGFloat pairWidth = MAX(0,contentWidth-labelWidth-groupSpacing*(self.fields.count-1))/self.fields.count;
  self.titleLabel.frame = NSMakeRect(ICInspectorLabelInset, ICInspectorLabelY, MAX(0,labelWidth-(self.linkButton != nil ? 47 : 27)), ICInspectorTextHeight);
  // Center the symbol on the label's capital letters, not the lowered values
  // or the empty padding in the text field's frame (row coordinates are y-up).
  CGFloat labelBaseline = NSMaxY(self.titleLabel.frame)-self.titleLabel.firstBaselineOffsetFromTop;
  CGFloat labelTextCenter = labelBaseline+self.titleLabel.font.capHeight/2;
  CGFloat iconY = round((labelTextCenter-ICInspectorLinkSize/2)*2)/2;
  self.linkButton.frame = NSMakeRect(labelWidth-22, iconY, ICInspectorLinkSize, ICInspectorLinkSize);
  for (NSUInteger i=0; i<self.fields.count; ++i) {
    CGFloat x = labelWidth+i*(pairWidth+groupSpacing);
    self.axisLabels[i].frame = NSMakeRect(x, ICInspectorLabelY, 12, ICInspectorTextHeight);
    self.fields[i].frame = NSMakeRect(x+12, ICInspectorLabelY-ICInspectorValueDrop, MAX(0,pairWidth-32), ICInspectorTextHeight);
    self.unitLabels[i].frame = NSMakeRect(x+pairWidth-18, ICInspectorLabelY, 16, ICInspectorTextHeight);
  }
}

@end
