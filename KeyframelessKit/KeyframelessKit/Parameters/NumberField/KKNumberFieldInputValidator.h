//
//  KKNumberFieldInputValidator.h
//  KeyframelessKit
//
//  Stateless validator for live numeric text input in KKNumberField.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Validates proposed text changes as they are typed into a numeric field.
/// All state is passed per-call; instances can be shared and reused freely.
@interface KKNumberFieldInputValidator : NSObject

/// Returns YES if applying replacementString at affectedRange within currentString
/// produces a valid or in-progress numeric value within [minValue, maxValue].
- (BOOL)isValidReplacementString:(NSString *)replacementString
                         inRange:(NSRange)affectedRange
                        ofString:(NSString *)currentString
                        minValue:(double)minValue
                        maxValue:(double)maxValue;

@end

NS_ASSUME_NONNULL_END
