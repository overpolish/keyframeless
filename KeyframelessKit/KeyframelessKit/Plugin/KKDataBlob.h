/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

// Forward-declare FxPlug protocols rather than #importing FxPlugSDK.h.
// FxPlug's headers aren't a module, so importing them inside a public
// framework header would trigger
//   "Include of non-modular header inside framework module".
// Other public headers in this framework (KKPlugin.h, KKPluginInstanceState.h)
// follow the same pattern.
@protocol FxCustomParameterInterpolation_v2;
@protocol FxParameterRetrievalAPI_v6;
@protocol FxParameterSettingAPI_v5;

NS_ASSUME_NONNULL_BEGIN

/// Generic NSData wrapper for use as an FxPlug *custom* parameter value.
///
/// Custom parameters are required to make blob writes undoable in FCP —
/// `setStringParameterValue:` has no `atTime:` variant and FCP filters
/// non-time-keyed writes off its undo stack. `setCustomParameterValue:
/// toParameter:atTime:` routes through the same keyframe pipeline that
/// scalar animatable params already use, which IS undoable.
///
/// FxPlug requires custom value classes to conform to NSSecureCoding,
/// NSCopying, and FxCustomParameterInterpolation_v2. Blob params (path
/// geometry, timing-lane JSON) are logically a single value — we always
/// write at `kCMTimeZero` and never produce in-between keyframes — so
/// `interpolateBetween:withWeight:` snap-steps to one side or the other.
// Conformance to FxCustomParameterInterpolation_v2 is declared in the .m
// (private class extension that imports FxPlugSDK.h). Forward-declaring a
// protocol lets us reference it as a type but not declare conformance, and
// importing FxPlug here would break the framework module.
@interface KKDataBlob : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic, copy, readonly) NSData *data;

+ (instancetype)blobWithData:(nullable NSData *)data;
+ (instancetype)blobWithString:(nullable NSString *)string;

/// UTF-8 decode of `data`. Returns @"" when data is empty.
- (NSString *)stringValue;

@end

/// Read a string-typed custom parameter (KKDataBlob value) at kCMTimeZero
/// and return the UTF-8 decoded string. Returns nil when unset.
NSString *_Nullable KKReadCustomParamString(
    id<FxParameterRetrievalAPI_v6> getAPI, UInt32 parameterID);

/// Write `string` (UTF-8) to a string-typed custom parameter at
/// kCMTimeZero. Caller must already be inside an
/// FxCustomParameterActionAPI_v4 action scope — that's what registers the
/// write on FCP's undo stack.
void KKWriteCustomParamString(id<FxParameterSettingAPI_v5> setAPI,
                              NSString *_Nullable string, UInt32 parameterID);

/// Convenience: read a bool-encoded KKDataBlob param ("1"/"0"). Used for
/// custom group-header expand state — replaces the legacy hidden toggle
/// param so saved expand state lives in the same undoable custom-param
/// pipeline as other plugin state. Returns NO when unset.
BOOL KKReadCustomParamBool(id<FxParameterRetrievalAPI_v6> getAPI,
                           UInt32 parameterID);

/// Counterpart to `KKReadCustomParamBool`. Caller must already be inside
/// an FxCustomParameterActionAPI_v4 action scope.
void KKWriteCustomParamBool(id<FxParameterSettingAPI_v5> setAPI, BOOL value,
                            UInt32 parameterID);

/// Read an int-valued custom parameter (NSNumber-typed). Returns 0 when
/// unset or wrong type. For params registered via
/// `addCustomParameterWithName:…defaultValue:@(N)…`.
int KKReadCustomParamInt(id<FxParameterRetrievalAPI_v6> getAPI,
                         UInt32 parameterID);

/// Counterpart to `KKReadCustomParamInt`. Writes via
/// setCustomParameterValue:atTime: so the change registers an undo entry.
/// Caller must already be inside an FxCustomParameterActionAPI_v4 scope.
void KKWriteCustomParamInt(id<FxParameterSettingAPI_v5> setAPI, int value,
                           UInt32 parameterID);

NS_ASSUME_NONNULL_END
