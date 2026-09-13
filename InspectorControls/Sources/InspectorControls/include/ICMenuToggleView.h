#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// An inline menu option whose mouse action leaves the containing menu open.
/// The owner updates the menu item's state after applying its action.
@interface ICMenuToggleView : NSButton
- (instancetype)initWithMenuItem:(NSMenuItem *)item;
@end
NS_ASSUME_NONNULL_END
