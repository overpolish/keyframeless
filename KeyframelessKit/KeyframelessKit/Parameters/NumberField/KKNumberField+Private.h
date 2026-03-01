//
//  KKNumberField+Private.h
//  KeyframelessKit
//
//  Internal interface for KKNumberField, exposed to tightly-coupled subcomponents
//  (e.g. KKNumberFieldTextView) that need to call back into the field without
//  making these methods part of the public API.
//

#import "KKNumberField.h"

@interface KKNumberField ()

@property (nonatomic, readwrite) BOOL isFocused;

/// Shared focus entry point — called by both the field and its embedded text view.
- (void)beginEditing;
/// Returns the current value formatted for editing — full precision for non-integers.
- (NSString *)displayStringForEditing;

@end
