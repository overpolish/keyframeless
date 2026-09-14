/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "ICContextMenu.h"
@implementation ICContextMenu
- (instancetype)initWithTitle:(NSString *)title {
  if ((self=[super initWithTitle:title])) {
    self.allowsContextMenuPlugIns=NO;
    if (@available(macOS 15.2,*)) self.automaticallyInsertsWritingToolsItems=NO;
  }
  return self;
}
@end
