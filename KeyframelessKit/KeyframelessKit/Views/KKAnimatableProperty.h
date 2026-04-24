/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@protocol FxParameterRetrievalAPI_v6;
@protocol FxParameterSettingAPI_v5;

NS_ASSUME_NONNULL_BEGIN

/// How each native param in `valueParamIDs` maps to logical lane values.
/// One native control per slot; kind governs how many scalar values that
/// slot expands into and which FxPlug accessor reads/writes it.
typedef NS_ENUM(NSInteger, KKAnimatableParamKind) {
  /// Standard float slider: 1 native param → 1 scalar value.
  KKAnimatableParamKindFloat = 0,
  /// NSColor well: 1 native param → 3 scalar values [R, G, B].
  KKAnimatableParamKindColor = 1,
  /// Gradient JSON string param: 1 native param → `5 * N` scalar values,
  /// flattened as `[pos, r, g, b, mid]` per stop. `N` can differ per
  /// segment — the multi-stage interp path falls back to LUT-lerp when
  /// stop counts don't match across a transition.
  KKAnimatableParamKindGradient = 2,
};

@interface KKAnimatableProperty : NSObject

@property(nonatomic, copy, readonly) NSString *label;
@property(nonatomic, readonly) UInt32 inParamID;
@property(nonatomic, readonly) UInt32 holdParamID;
@property(nonatomic, readonly) UInt32 outParamID;
/// Native parameter IDs whose controls are the source of edit for this
/// property in multi-stage mode. Empty array = no sync. One entry per
/// native control, regardless of how many scalar values it unpacks into.
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *valueParamIDs;
/// Kinds parallel to `valueParamIDs`; each entry is a `KKAnimatableParamKind`
/// boxed as `NSNumber`. Defaults to all-Float when unspecified.
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *valueParamKinds;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                          valueID:(UInt32)valueID;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                         valueIDs:(NSArray<NSNumber *> *)valueIDs;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                          valueID:(UInt32)valueID
                             kind:(KKAnimatableParamKind)kind;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                         valueIDs:(NSArray<NSNumber *> *)valueIDs
                            kinds:(NSArray<NSNumber *> *)kinds;

/// Multi-stage-only factories. Use these when the plugin has no classic
/// ease-in/hold/ease-out params — `inParamID`, `holdParamID`, `outParamID`
/// default to 0 and the classic timing UI does not render for this
/// property. Plugins that set `kKKParamMultiStageEnabled = YES` and never
/// expose a toggle should always use these.
+ (instancetype)propertyWithLabel:(NSString *)label valueID:(UInt32)valueID;
+ (instancetype)propertyWithLabel:(NSString *)label
                          valueID:(UInt32)valueID
                             kind:(KKAnimatableParamKind)kind;
+ (instancetype)propertyWithLabel:(NSString *)label
                         valueIDs:(NSArray<NSNumber *> *)valueIDs;
+ (instancetype)propertyWithLabel:(NSString *)label
                         valueIDs:(NSArray<NSNumber *> *)valueIDs
                            kinds:(NSArray<NSNumber *> *)kinds;

- (instancetype)init NS_UNAVAILABLE;

/// Total scalar value count across all native params (sum of per-kind sizes).
@property(nonatomic, readonly) NSUInteger valueCount;

/// Reads current native-control values into a flat scalar array matching
/// segment `.values` shape. Returns nil only if the API is unavailable.
- (nullable NSArray<NSNumber *> *)readValuesWithGetAPI:
                                      (id<FxParameterRetrievalAPI_v6>)getAPI
                                                atTime:(CMTime)time;

/// Writes a flat scalar `values` array back to the native controls. Values
/// beyond the declared count are ignored; missing values are left unchanged.
- (void)writeValues:(NSArray<NSNumber *> *)values
         withSetAPI:(id<FxParameterSettingAPI_v5>)setAPI
             atTime:(CMTime)time;

@end

NS_ASSUME_NONNULL_END
