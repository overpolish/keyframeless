//
//  KKNumberField.h
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

/// A single-line numeric input field with inline editing and optional min/max clamping.
@interface KKNumberField : NSView <NSTextViewDelegate>

/// Provides access to shared application services.
@property (nonatomic, strong) id<PROAPIAccessing> apiManager;
/// Background fill color. Defaults to clear.
@property (nonatomic, strong) NSColor *backgroundColor;
/// The field's current numeric value.
@property (nonatomic) double doubleValue;
/// Lower bound enforced on commit. Defaults to -INFINITY.
@property (nonatomic) double minValue;
/// Upper bound enforced on commit. Defaults to +INFINITY.
@property (nonatomic) double maxValue;
/// Whether the field currently has keyboard focus.
@property (nonatomic, readonly) BOOL isFocused;
/// Whether an edit session is in progress.
@property (nonatomic, readonly) BOOL isEditing;

/// Designated initializer.
- (instancetype)initWithFrame:(NSRect)frame apiManager:(id<PROAPIAccessing>)apiManager;

@end

NS_ASSUME_NONNULL_END
