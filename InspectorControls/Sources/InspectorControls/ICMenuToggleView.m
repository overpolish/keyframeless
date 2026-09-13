#import "ICMenuToggleView.h"

@interface ICMenuToggleView ()
@property(nonatomic, weak) NSMenuItem *item;
@end
@implementation ICMenuToggleView
- (instancetype)initWithMenuItem:(NSMenuItem *)item {
  CGFloat width = MAX(180, [item.title sizeWithAttributes:@{NSFontAttributeName:[NSFont menuFontOfSize:0]}].width + 44);
  if ((self = [super initWithFrame:NSMakeRect(0, 0, width, 22)])) {
    _item = item;
    self.bordered = NO;
    self.focusRingType = NSFocusRingTypeNone;
    self.buttonType = NSButtonTypeMomentaryChange;
    self.target = self;
    self.action = @selector(activate:);
    self.autoresizingMask = NSViewWidthSizable;
    self.accessibilityLabel = item.title;
    self.accessibilityRole = NSAccessibilityCheckBoxRole;
  }
  return self;
}
- (void)activate:(id)sender {
  (void)sender;
  if (self.item.enabled) [NSApp sendAction:self.item.action to:self.item.target from:self.item];
}
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSMenuItem *item = self.item;
  BOOL highlighted = self.highlighted || item.highlighted;
  // Custom menu views draw their own hover fill; suppress only the focus ring.
  if (highlighted && item.enabled) {
    [NSColor.selectedContentBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 5, 0) xRadius:4 yRadius:4] fill];
  }
  NSColor *color = !item.enabled ? NSColor.disabledControlTextColor :
      highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor;
  NSDictionary *attributes = @{NSFontAttributeName:[NSFont menuFontOfSize:0], NSForegroundColorAttributeName:color};
  CGFloat y = (NSHeight(self.bounds) - [item.title sizeWithAttributes:attributes].height) / 2;
  [item.title drawAtPoint:NSMakePoint(28, y) withAttributes:attributes];
  if (item.state == NSControlStateValueOn) [@"✓" drawAtPoint:NSMakePoint(12, y) withAttributes:attributes];
}
- (id)accessibilityValue { return @(self.item.state == NSControlStateValueOn); }
@end
