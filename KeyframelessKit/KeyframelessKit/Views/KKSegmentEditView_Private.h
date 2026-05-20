/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKSegmentEditView.h>

@class KKCurvePillView;

NS_ASSUME_NONNULL_BEGIN

@interface KKSegmentEditView (Internal)

/// Internal accessor for the +Guide category — returns the pills view so
/// guide code can resolve a pill's screen rect without exposing it on the
/// public header.
- (nullable KKCurvePillView *)_guidePillsView;

@end

NS_ASSUME_NONNULL_END
