#import "KKNumberFormatter.h"

@implementation KKNumberFormatter

- (instancetype)init {
  self = [super init];
  if (self) {
    _minValue = -DBL_MIN;
    _maxValue = DBL_MAX;
  }
  return self;
}

- (NSString *)stringForObjectValue:(id)obj {
  if (![obj isKindOfClass:[NSNumber class]]) {
    return nil;
  }

  double value = [obj doubleValue];
  if (_editing) {
    // Full precision: up to 4dp, trailing zeros stripped
    NSString *s = [NSString stringWithFormat:@"%.4f", value];
    NSRange dot = [s rangeOfString:@"."];
    if (dot.location != NSNotFound) {
      NSUInteger end = s.length;
      while (end > dot.location + 2 && [s characterAtIndex:end - 1] == '0') {
        end--;
      }
      s = [s substringToIndex:end];
    }
    return s;
  }
  if (value == 0.0) {
    return @"0";
  }
  return [NSString stringWithFormat:@"%.1f", value];
}

- (BOOL)getObjectValue:(out id _Nullable __autoreleasing *)obj
             forString:(NSString *)string
      errorDescription:(out NSString *_Nullable __autoreleasing *)error {
  if (obj) {
    *obj = @([string doubleValue]);
  }
  return YES;
}

- (BOOL)isPartialStringValid:(NSString *)partialString
            newEditingString:(NSString *_Nullable __autoreleasing *)newString
            errorDescription:(NSString *_Nullable __autoreleasing *)error {

  // Allow clearing
  if (partialString.length == 0)
    return YES;

  // Character set validation
  NSCharacterSet *allowed =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
  if ([[partialString stringByTrimmingCharactersInSet:allowed] length] > 0) {
    return NO;
  }

  // Structural validation
  if ([[partialString componentsSeparatedByString:@"."] count] > 2) {
    return NO;
  }

  NSUInteger minusCount =
      [[partialString componentsSeparatedByString:@"-"] count] - 1;
  if (minusCount > 1 || (minusCount == 1 && ![partialString hasPrefix:@"-"])) {
    return NO;
  }

  // Intermediate states
  if ([partialString isEqualToString:@"-"] ||
      [partialString isEqualToString:@"."] ||
      [partialString isEqualToString:@"-."]) {
    return YES;
  }

  // Numeric validation (bounds are enforced on exit, not during typing)
  NSScanner *scanner = [NSScanner scannerWithString:partialString];
  double value;
  if ([scanner scanDouble:&value] && [scanner isAtEnd]) {
    return YES;
  }

  return NO;
}
@end