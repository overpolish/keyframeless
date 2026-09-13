/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "ICInspectorRow.h"
#import "ICSliderView.h"

NS_ASSUME_NONNULL_BEGIN

/// Inspector row containing a linear slider and one editable numeric value.
/// The component identifier and host value remain owned by the consumer.
@interface ICSliderRow : ICInspectorRow
@property(nonatomic, strong, readonly) ICSliderView *sliderView;
@property(nonatomic, readonly) BOOL interacting;
- (instancetype)initWithLabel:(NSString *)label
                    identifier:(NSInteger)identifier
               fractionDigits:(NSUInteger)fractionDigits;
- (instancetype)initWithLabel:(NSString *)label identifier:(NSInteger)identifier
                       suffix:(NSString *)suffix fractionDigits:(NSUInteger)fractionDigits;
@end

NS_ASSUME_NONNULL_END
