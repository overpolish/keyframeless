/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <AppKit/AppKit.h>
#import <assert.h>
#import <math.h>
#import "ICInspectorHeader.h"

static void near(CGFloat a, CGFloat b) { assert(fabs(a - b) < 0.01); }

int main(void) {
  @autoreleasepool {
    NSImage *logo = [[NSImage alloc] initWithSize:NSMakeSize(28, 28)];
    NSButton *accessory = [NSButton buttonWithImage:[NSImage new] target:nil action:nil];
    accessory.accessibilityLabel = @"Accessory";
    __block NSUInteger menuCalls = 0;
    ICInspectorHeader *header = [[ICInspectorHeader alloc]
        initWithLogo:logo accessoryButtons:@[ accessory ] menuProvider:^NSMenu *{
          menuCalls++;
          return nil;
        }];
    assert(header.settingsButton != nil);
    assert(header.accessoryButtons.count == 1);
    assert(header.intrinsicContentSize.height == 48);
    header.frame = NSMakeRect(0, 0, 240, 48);
    [header layoutSubtreeIfNeeded];
    NSImageView *logoView = nil;
    for (NSView *view in header.subviews)
      if ([view isKindOfClass:[NSImageView class]]) logoView = (NSImageView *)view;
    assert(logoView != nil);
    near(NSMinX(logoView.frame), 21);
    near(NSWidth(logoView.frame), 28);
    NSRect settingsFrame = [header convertRect:header.settingsButton.bounds fromView:header.settingsButton];
    near(NSMaxX(settingsFrame),219);
    near(NSWidth(settingsFrame),18); near(NSHeight(settingsFrame),18);
    NSColor *tint=NSColor.redColor; accessory.contentTintColor=tint;
    NSUInteger constraints=accessory.constraints.count;
    header.accessoryButtons=@[accessory];
    header.accessoryButtons=@[accessory];
    [header layoutSubtreeIfNeeded];
    assert(accessory.constraints.count==constraints);
    assert([accessory.contentTintColor isEqual:tint]);
    near(NSWidth(accessory.frame),18);
    near(NSMinX(header.settingsButton.frame)-NSMaxX(accessory.frame),8);
    header.frame=NSMakeRect(0,0,550,48); [header layoutSubtreeIfNeeded];
    near(NSMaxX(header.settingsButton.frame),529);
    NSButton *replacement=[NSButton buttonWithTitle:@"New" target:nil action:nil];
    header.accessoryButtons=@[replacement]; [header layoutSubtreeIfNeeded];
    assert(accessory.superview==nil);
    near(NSWidth(replacement.frame),18);
    [header.settingsButton performClick:nil];
    assert(menuCalls == 1);
    header.accessoryButtons = nil;
    assert(header.accessoryButtons.count == 0);
    puts("InspectorControls header: logo geometry, controls and menu provider passed");
  }
}
