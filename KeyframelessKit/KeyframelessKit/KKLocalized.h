/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The KeyframelessKit framework bundle, which carries KKLocalizable.xcstrings.
/// Look strings up against this bundle - never +[NSBundle mainBundle] - because
/// KKKit runs inside FCP's XPC render and shared ViewBridge processes, where
/// the main bundle is not the framework.
FOUNDATION_EXPORT NSBundle *KKLocalizationBundle(void);

/// Localized DISPLAY name for a property/parameter whose English string is the
/// stable identity key (e.g. a KKLane label like @"Radius"/@"Crop"). Returns
/// the translation from the KKParamNames table, falling back to the English
/// name when untranslated. Use ONLY at render sites - never where the name is
/// compared, persisted, used as a dictionary key, or matched by joyride. The
/// English identity must stay untouched so saved projects and cross-language
/// sharing keep working.
FOUNDATION_EXPORT NSString *KKLocalizedParamName(NSString *englishName);

/// The raw plain lane label of a (possibly owner-tagged) label: the substring
/// before the U+001F separator a merged multi-owner timeline appends (e.g.
/// "Scale\x1f<layerID>" -> "Scale"), or the label unchanged when untagged.
/// Unlike KKLocalizedParamName this does NOT localize - use it for matching a
/// plain label against tagged lanes (e.g. routing a mini-viewer handle commit
/// to the active owner's lane).
FOUNDATION_EXPORT NSString *KKPlainLaneLabel(NSString *label);

/// Clamp a user-typed layer name to 15 characters, appending an ellipsis when
/// it overflows, so layer pills/labels (filter bar, Animated dropdown) stay
/// compact. Names at or under the limit are returned unchanged. Display only -
/// never use the result as identity.
FOUNDATION_EXPORT NSString *KKTruncatedLayerName(NSString *name);

NS_ASSUME_NONNULL_END

/// Localize a KeyframelessKit-owned, user-visible string (e.g. joyride chrome)
/// from the KKLocalizable table, resolved against the framework bundle. Never
/// wrap log messages, dictionary keys, or numeric formats.
#define KKLoc(key, comment)                                                    \
  NSLocalizedStringFromTableInBundle((key), @"KKLocalizable",                  \
                                     KKLocalizationBundle(), (comment))
