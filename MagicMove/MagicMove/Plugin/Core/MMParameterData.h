/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Plugin-owned custom parameter payload. Its historical runtime name and
/// `data` archive key are retained so existing MagicMove documents still decode.
///
/// FxPlug custom values participate in host undo; these opaque timing records
/// use step interpolation, never interpolation of the stored bytes.
@interface KKDataBlob : NSObject <NSSecureCoding, NSCopying>
@property(nonatomic, copy, readonly) NSData *data;
+ (instancetype)blobWithData:(nullable NSData *)data;
+ (instancetype)blobWithString:(nullable NSString *)string;
- (NSString *)stringValue;
@end
NS_ASSUME_NONNULL_END
