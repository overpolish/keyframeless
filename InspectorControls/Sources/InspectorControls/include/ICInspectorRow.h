/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once
#import <AppKit/AppKit.h>
#import "ICValueTextField.h"

NS_ASSUME_NONNULL_BEGIN
// Presentation configuration. Identifiers are opaque to the library; display
// units and host-value conversion remain the consumer's responsibility.
@interface ICInspectorComponent : NSObject
@property(nonatomic, readonly) NSInteger identifier;
@property(nonatomic, readonly, copy) NSString *label;
@property(nonatomic, readonly, copy) NSString *suffix;
@property(nonatomic, readonly) NSUInteger fractionDigits;
- (instancetype)initWithIdentifier:(NSInteger)identifier label:(NSString *)label
                            suffix:(NSString *)suffix fractionDigits:(NSUInteger)digits;
@end

@interface ICInspectorRow : NSView <NSTextFieldDelegate>
@property(nonatomic, readonly) NSTextField *titleLabel;
@property(nonatomic, readonly, copy) NSArray<ICValueTextField *> *fields;
@property(nonatomic, readonly, copy) NSArray<NSTextField *> *axisLabels;
@property(nonatomic, readonly, copy) NSArray<NSTextField *> *unitLabels;
@property(nonatomic, readonly, nullable) NSButton *linkButton;
@property(nonatomic, readonly) BOOL interacting;
@property(nonatomic, copy, nullable) void (^onValueCommit)(ICValueTextField *field);
@property(nonatomic, copy, nullable) void (^onScrubBegin)(void);
@property(nonatomic, copy, nullable) void (^onScrubEnd)(void);
@property(nonatomic, copy, nullable) void (^onLinkToggle)(NSButton *button);
- (instancetype)initWithLabel:(NSString *)label
                  components:(NSArray<ICInspectorComponent *> *)components
                   showsLink:(BOOL)showsLink;
@end
NS_ASSUME_NONNULL_END
