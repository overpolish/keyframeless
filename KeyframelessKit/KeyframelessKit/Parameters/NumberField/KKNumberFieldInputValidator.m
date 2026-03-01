//
//  KKNumberFieldInputValidator.m
//  KeyframelessKit
//

#import "KKNumberFieldInputValidator.h"

/// Returns YES for strings that are valid in-progress but not yet complete numbers
/// (e.g. "-", ".", "-.").
static BOOL KKIsPartialInput(NSString *string) {
    return [string isEqualToString:@"-"] || [string isEqualToString:@"."] || [string isEqualToString:@"-."];
}

@implementation KKNumberFieldInputValidator

- (BOOL)isValidReplacementString:(NSString *)replacementString
                         inRange:(NSRange)affectedRange
                        ofString:(NSString *)currentString
                        minValue:(double)minValue
                        maxValue:(double)maxValue {
    // Allow deletions and clearing.
    if (replacementString.length == 0)
        return YES;

    NSString *proposed = [currentString stringByReplacingCharactersInRange:affectedRange withString:replacementString];
    if (proposed.length == 0)
        return YES;

    // Only allow numeric input characters.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
    NSCharacterSet *input = [NSCharacterSet characterSetWithCharactersInString:replacementString];
    if (![allowed isSupersetOfSet:input])
        return NO;

    // At most one decimal point.
    if ([[proposed componentsSeparatedByString:@"."] count] > 2)
        return NO;

    // Minus sign must be at the start, and only one.
    NSUInteger minusCount = [[proposed componentsSeparatedByString:@"-"] count] - 1;
    if (minusCount > 1)
        return NO;
    if (minusCount == 1 && ![proposed hasPrefix:@"-"])
        return NO;

    // Allow valid intermediate states (e.g. "-", ".", "-.").
    if (KKIsPartialInput(proposed))
        return YES;

    // Must parse as a complete double.
    NSScanner *scanner = [NSScanner scannerWithString:proposed];
    double value;
    if (!([scanner scanDouble:&value] && [scanner isAtEnd]))
        return NO;

    // Enforce bounds.
    if (value < minValue || value > maxValue)
        return NO;

    return YES;
}

@end
