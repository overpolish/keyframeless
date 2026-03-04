//
//  KKNumberField.h
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#include <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CFCGTypes.h>
#include <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class KKLog;
@protocol PROAPIAccessing;

@interface KKNumberField : NSView <NSTextFieldDelegate>
@property(nonatomic) double minValue;
@property(nonatomic) double maxValue;
@property(nonatomic) BOOL isStepperMode;
@property(nonatomic) BOOL isSelected;
@property(nonatomic) CGFloat stepValue;
@property(nonatomic) CGFloat numberValue;
@property(nonatomic, strong) KKLog *log;

@property(nonatomic, copy, nullable) NSString *prefix;
@property(nonatomic, copy, nullable) NSString *suffix;

+ (CGFloat)preferredWidth;
+ (CGFloat)preferredHeight;

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager;

@end

// /// A single-line numeric input field with inline editing and optional
// min/max clamping.
// @interface KKNumberField : NSView <NSTextFieldDelegate>

// /// Provides access to shared application services.
// @property (nonatomic, strong) id<PROAPIAccessing> apiManager;
// /// Logger. Defaults to the framework logger; set to your plugin's logger to
// route
// /// number field logs into your plugin's log file.
// @property (nonatomic, strong) KKLog *log;
// /// Background fill color. Defaults to clear.
// @property (nonatomic, strong) NSColor *backgroundColor;
// /// The field's current numeric value.
// @property (nonatomic) double doubleValue;
// /// Lower bound enforced on commit. Defaults to -INFINITY.
// @property (nonatomic) double minValue;
// /// Upper bound enforced on commit. Defaults to +INFINITY.
// @property (nonatomic) double maxValue;
// /// Whether the field currently has keyboard focus.
// @property (nonatomic, readonly) BOOL isFocused;
// /// Whether an edit session is in progress.
// @property (nonatomic, readonly) BOOL isEditing;
// /// Optional single-character prefix drawn outside the field (e.g. @"X",
// @"Y"). Space is always reserved.
// @property (nonatomic, copy, nullable) NSString *prefix;
// /// Optional 1–2 character suffix drawn outside the field (e.g. @"%", @"px").
// Space is always reserved.
// @property (nonatomic, copy, nullable) NSString *suffix;

// /// Total view width including reserved prefix and suffix zones.
// + (CGFloat)preferredWidth;

// /// Designated initializer.
// - (instancetype)initWithFrame:(NSRect)frame
// apiManager:(id<PROAPIAccessing>)apiManager;

// @end

NS_ASSUME_NONNULL_END
