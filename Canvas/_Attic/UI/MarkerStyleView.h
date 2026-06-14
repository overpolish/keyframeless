/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKPillStyleView.h"

NS_ASSUME_NONNULL_BEGIN

/// Radio-style pill selector for stroke markers (none, arrow, circle, square,
/// arrowhead, line). Each pill renders a mini preview of the marker shape.
@interface KKMarkerStyleView : KKPillStyleView

@property(nonatomic) BOOL isStart; // YES = start marker (arrow points left)

@end

NS_ASSUME_NONNULL_END
