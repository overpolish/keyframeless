/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "ICInspectorRow.h"
#import "InspectorTokens.h"

@implementation ICMenuTextField
- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  BOOL rightClick = event.type == NSEventTypeRightMouseDown;
  BOOL controlClick = event.type == NSEventTypeLeftMouseDown &&
      (flags & NSEventModifierFlagControl) != 0;
  if (!rightClick && !controlClick) return nil;
  return self.menuProvider ? self.menuProvider() : nil;
}
@end

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
  _titleLabel=[ICMenuTextField labelWithString:label];
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
    // Retain suffix layout/style without adding a text-field view. In remote
    // inspectors, percentage label views have intercepted adjacent host buttons
    // despite correct frames. All suffixes use the same direct drawing path.
    [self addSubview:axis]; [self addSubview:field];
    [fields addObject:field]; [labels addObject:axis]; [units addObject:unit];
  }
  _enabled=YES;
  _componentColors=@[];
  _fields=[fields copy]; _axisLabels=[labels copy]; _unitLabels=[units copy];
  __weak ICInspectorRow *weakRow = self;
  ((ICMenuTextField *)_titleLabel).menuProvider = ^NSMenu *{
    ICInspectorRow *row = weakRow;
    return row.titleMenuProvider ? row.titleMenuProvider() : nil;
  };
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
- (void)setSelected:(BOOL)selected {
  if(_selected==selected) return;
  _selected=selected;
  self.titleLabel.font=selected ? ICInspectorTokens.selectedLabelFont : ICInspectorTokens.labelFont;
  [self updateTextColors];
  self.needsDisplay=YES;
}
- (void)setKeyposeLinked:(BOOL)keyposeLinked {
  if (_keyposeLinked == keyposeLinked) return;
  _keyposeLinked = keyposeLinked;
  self.needsDisplay = YES;
}
- (void)setKeyposeLinkColor:(NSColor *)color {
  if (_keyposeLinkColor==color || [_keyposeLinkColor isEqual:color]) return;
  _keyposeLinkColor=color;
  self.needsDisplay=YES;
}
- (void)setComponentColors:(NSArray<NSColor *> *)componentColors {
  if([_componentColors isEqualToArray:componentColors]) return;
  _componentColors=[componentColors copy] ?: @[];
  [self updateComponentColors];
}
- (void)setComponentColorsVisible:(BOOL)visible {
  if (_componentColorsVisible==visible) return;
  _componentColorsVisible=visible;
  [self updateComponentColors];
}
- (void)setEnabled:(BOOL)enabled {
  _enabled=enabled;
  for (ICValueTextField *field in self.fields) field.enabled=enabled;
  [self updateTextColors];
}
- (void)updateTextColors {
  self.titleLabel.textColor=!self.enabled ? ICInspectorTokens.disabledTextColor :
      (self.selected ? ICInspectorTokens.accentMatchingHost : ICInspectorTokens.labelColor);
  for (NSTextField *unit in self.unitLabels)
    unit.textColor=self.enabled ? ICInspectorTokens.decorationColor : ICInspectorTokens.disabledTextColor;
  [self updateComponentColors];
  self.needsDisplay=YES;
}
- (void)updateComponentColors {
  for(NSUInteger i=0;i<self.axisLabels.count;i++)
    self.axisLabels[i].textColor=!self.enabled ? ICInspectorTokens.disabledTextColor : self.componentColorsVisible && i<self.componentColors.count
        ? self.componentColors[i] : ICInspectorTokens.decorationColor;
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
- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  if (self.keyposeLinked) {
    NSImage *image = [NSImage imageWithSystemSymbolName:@"link.circle.fill"
                                  accessibilityDescription:nil];
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:11
                                                          weight:NSFontWeightRegular
                                                           scale:NSImageSymbolScaleSmall];
    configuration = [configuration configurationByApplyingConfiguration:
        NSImageSymbolConfiguration.configurationPreferringMonochrome];
    NSImage *symbol=[image imageWithSymbolConfiguration:configuration];
    image=[NSImage imageWithSize:symbol.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [symbol drawInRect:rect];
      [(self.keyposeLinkColor ?: ICInspectorTokens.accentMatchingHost) setFill];
      NSRectFillUsingOperation(rect,NSCompositingOperationSourceIn);
      return YES;
    }];
    NSRect iconFrame = ICInspectorGutterIconFrame(self.titleLabel);
    // Fit the symbol proportionally; its intrinsic canvas need not be square.
    NSSize imageSize=image.size;
    if(imageSize.width>0 && imageSize.height>0) {
      CGFloat factor=MIN(NSWidth(iconFrame)/imageSize.width,NSHeight(iconFrame)/imageSize.height);
      NSSize fitted=NSMakeSize(imageSize.width*factor,imageSize.height*factor);
      iconFrame=NSMakeRect(NSMidX(iconFrame)-fitted.width/2,NSMidY(iconFrame)-fitted.height/2,fitted.width,fitted.height);
    }
    if (image && NSIntersectsRect(dirtyRect, iconFrame))
      [image drawInRect:iconFrame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                fraction:1.0 respectFlipped:YES hints:nil];
  }
  for(NSTextField *unit in self.unitLabels) {
    if(unit.hidden || !NSIntersectsRect(dirtyRect,unit.frame)) continue;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(unit.frame);
    [unit.cell drawWithFrame:unit.frame inView:self];
    [NSGraphicsContext restoreGraphicsState];
  }
}
- (void)layout {
  [super layout];
  CGFloat width = NSWidth(self.bounds);
  // Adapted from KKParameterRowView / KKLabelView: leave the host-control
  // gutter clear and inset our own label. Relax column minima in narrow hosts
  // rather than letting the old required constraints overflow the row.
  CGFloat contentWidth = MAX(0, width-ICInspectorHostGutter);
  // Measure component gaps from the suffix edge, independent of its inset.
  CGFloat groupSpacing = (self.fields.count>2 ? 10:ICInspectorGroupSpacing)-ICInspectorSuffixTrailingInset;
  const CGFloat axisWidth = self.fields.count>2 ? 10:12;
  // Measure a stable signed, three-digit readout at the configured precision.
  // Do not size from the current value: that would shift columns while scrubbing.
  CGFloat minimumValueWidth=24;
  if(self.fields.count>2) {
    for(ICValueTextField *field in self.fields) {
      NSString *readout=[field.formatter stringForObjectValue:@(-888.8)] ?: @"-888.8";
      CGFloat textWidth=[readout sizeWithAttributes:@{NSFontAttributeName:field.font}].width;
      minimumValueWidth=MAX(minimumValueWidth,ceil(textWidth)+2*ICInspectorFieldTextInset);
    }
  }
  CGFloat componentMinimum=axisWidth+ICInspectorSuffixWidth+ICInspectorSuffixTrailingInset+ICInspectorValueSuffixGap+minimumValueWidth;
  if(self.fields.count>2) {
    CGFloat labelMinimum=ICInspectorLabelInset+[self.titleLabel.stringValue sizeWithAttributes:@{NSFontAttributeName:ICInspectorTokens.selectedLabelFont}].width+6;
    CGFloat availableGap=(contentWidth-labelMinimum-componentMinimum*self.fields.count)/(self.fields.count-1);
    groupSpacing=MAX(3,MIN(groupSpacing,availableGap));
  }
  CGFloat minimumContent=self.fields.count>2
      ? componentMinimum*self.fields.count+groupSpacing*(self.fields.count-1)
      : 70*self.fields.count;
  CGFloat labelWidth = ICInspectorLabelColumnWidth(width,minimumContent);
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
    self.axisLabels[i].frame = NSMakeRect(x, ICInspectorLabelY, axisWidth, ICInspectorTextHeight);
    ICInspectorValueLayout valueLayout=ICInspectorLayoutValue(x+axisWidth,x+pairWidth);
    self.fields[i].frame=valueLayout.value;
    self.unitLabels[i].frame=valueLayout.suffix;
  }
  self.needsDisplay=YES;
}

@end
