/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "ICDefaultMenu.h"
void ICAppendDefaultMenuItems(NSMenu *menu, id target, SEL action, id context,
                              BOOL canSet) {
  if (menu.numberOfItems)
    [menu addItem:NSMenuItem.separatorItem];
  for (NSUInteger i = 0; i < 2; i++) {
    if (i)
      [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:i ? @"Restore Factory Default" : @"Set Default"
               action:action
        keyEquivalent:@""];
    item.target = target;
    item.tag = i;
    item.representedObject = context;
    item.enabled = i || canSet;
    [menu addItem:item];
  }
}
