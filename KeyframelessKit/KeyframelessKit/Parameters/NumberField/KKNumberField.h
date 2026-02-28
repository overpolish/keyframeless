//
//  KKNumberField.h
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKNumberField : NSView <NSTextViewDelegate>
@property (nonatomic, strong) id<PROAPIAccessing> apiManager;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic) double doubleValue;
@property (nonatomic, strong, readwrite) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic) BOOL isEditing;
@property (nonatomic) BOOL isFocused;
@property (nonatomic) double minValue;
@property (nonatomic) double maxValue;

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager;

- (void)updateTextAlignment;

@end

NS_ASSUME_NONNULL_END
