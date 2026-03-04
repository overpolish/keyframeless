//
//  KKNumberFieldTextView.h
//  KeyframelessKit
//
//  Created by Dom on 01/03/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class KKNumberField;

@interface KKNumberFieldTextView : NSTextView

@property (nonatomic, weak, nullable) KKNumberField *parentField;

@end

NS_ASSUME_NONNULL_END
