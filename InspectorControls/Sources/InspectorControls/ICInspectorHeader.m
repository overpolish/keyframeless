/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "ICInspectorHeader.h"
#import "InspectorTokens.h"

static const CGFloat kHeaderHeight = 48.0;
static const CGFloat kHeaderControlSize = 18.0;
static const CGFloat kHeaderSpacing = 8.0;

@interface ICInspectorHeader ()
@property(nonatomic, readwrite) NSButton *settingsButton;
@end

@implementation ICInspectorHeader {
  NSImageView *_logoView;
  NSHashTable<NSButton *> *_configuredButtons;
}

- (instancetype)initWithLogo:(NSImage *)logo {
  return [self initWithLogo:logo accessoryButtons:nil menuProvider:nil];
}

- (instancetype)initWithLogo:(NSImage *)logo
             accessoryButtons:(NSArray<NSButton *> *)buttons
                 menuProvider:(NSMenu *(^)(void))menuProvider {
  self = [super initWithFrame:NSMakeRect(0, 0, 320, kHeaderHeight)];
  if (!self) return nil;
  _configuredButtons=[NSHashTable weakObjectsHashTable];
  _menuProvider = [menuProvider copy];
  _accessoryButtons = [buttons copy] ?: @[];
  self.autoresizingMask = NSViewWidthSizable;

  _logoView = [[NSImageView alloc] init];
  _logoView.image = logo;
  _logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
  [self addSubview:_logoView];

  NSImage *settingsImage = [NSImage imageWithSystemSymbolName:@"gearshape"
                                         accessibilityDescription:@"Settings"];
  self.settingsButton = [NSButton buttonWithImage:settingsImage ?: [NSImage new]
                                            target:self
                                            action:@selector(settingsClicked:)];
  [self configureButton:self.settingsButton label:@"Settings"];

  [self addSubview:self.settingsButton];
  [self rebuildAccessories];
  return self;
}

- (void)setAccessoryButtons:(NSArray<NSButton *> *)buttons {
  for(NSButton *button in _accessoryButtons) [button removeFromSuperview];
  _accessoryButtons = [buttons copy] ?: @[];
  [self rebuildAccessories];
}

- (void)configureButton:(NSButton *)button label:(NSString *)label {
  if([_configuredButtons containsObject:button]) return;
  [_configuredButtons addObject:button];
  button.bordered = NO;
  button.controlSize = NSControlSizeSmall;
  button.focusRingType = NSFocusRingTypeNone;
  button.imageScaling = NSImageScaleProportionallyDown;
  if(!button.contentTintColor) button.contentTintColor = ICInspectorTokens.decorationColor;
  if (label.length) button.accessibilityLabel = label;
}

- (void)rebuildAccessories {
  for (NSButton *button in self.accessoryButtons) {
    [self configureButton:button label:button.accessibilityLabel];
    [self addSubview:button];
  }
  self.needsLayout=YES;
}

- (void)layout {
  [super layout];
  CGFloat center=NSMidY(self.bounds);
  _logoView.frame=NSMakeRect(ICInspectorLabelInset,center-14,28,28);
  CGFloat right=NSWidth(self.bounds)-ICInspectorLabelInset;
  self.settingsButton.frame=NSMakeRect(right-kHeaderControlSize,center-kHeaderControlSize/2,kHeaderControlSize,kHeaderControlSize);
  for(NSButton *button in self.accessoryButtons.reverseObjectEnumerator) {
    right-=kHeaderControlSize+kHeaderSpacing;
    button.frame=NSMakeRect(right-kHeaderControlSize,center-kHeaderControlSize/2,kHeaderControlSize,kHeaderControlSize);
  }
}

- (void)settingsClicked:(id)sender {
  (void)sender;
  NSMenu *menu = self.menuProvider ? self.menuProvider() : nil;
  if (!menu) return;
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:self.settingsButton];
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kHeaderHeight);
}
@end
