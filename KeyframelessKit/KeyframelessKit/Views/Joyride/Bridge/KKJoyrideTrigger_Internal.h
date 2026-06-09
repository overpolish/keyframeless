/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKJoyrideTrigger.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKJoyrideTriggerType) {
  KKJoyrideTriggerTypeManagePopoverWillOpen,
  KKJoyrideTriggerTypeManagePopoverClosed,
  KKJoyrideTriggerTypeLaneOptedIn,
  KKJoyrideTriggerTypeStaticValuesPopoverWillOpen,
  KKJoyrideTriggerTypeStaticValuesPopoverClosed,
  KKJoyrideTriggerTypeStaticValueDragEnded,
  KKJoyrideTriggerTypeConstantFieldEdited,
  KKJoyrideTriggerTypeGapPopoverWillOpen,
  KKJoyrideTriggerTypeGapPopoverCurveChanged,
  KKJoyrideTriggerTypePhaseToggled,
  KKJoyrideTriggerTypeDiamondTapped,
  KKJoyrideTriggerTypeGapTapped,
  KKJoyrideTriggerTypeMiniViewerViewTransformChanged,
  KKJoyrideTriggerTypeMiniViewerViewReset,
  KKJoyrideTriggerTypeMiniViewerDoubleClickHandled,
  KKJoyrideTriggerTypeRenderModeChanged,
  KKJoyrideTriggerTypeFilmstripCellActivated,
  KKJoyrideTriggerTypeMiniViewerOptHide,
  KKJoyrideTriggerTypePlayToggleEdge,
  KKJoyrideTriggerTypeDynamicToggled,
};

@interface KKJoyrideTrigger ()
@property(nonatomic, readonly) KKJoyrideTriggerType type;
/// Label / component / target filters (interpretation depends on `type`).
@property(nonatomic, copy, readonly, nullable) NSString *label;
@property(nonatomic, readonly)
    NSInteger intArg; // phase, idx, section, comp, curveType
@property(nonatomic, readonly)
    NSInteger intArg2; // phase "on" (0/1), playing (0/1)
@property(nonatomic, readonly) double doubleArg;  // constant-field target
@property(nonatomic, readonly) double doubleArg2; // constant-field tolerance
/// thenWaitFor: chain - when set, this trigger arms on its own match, then
/// the binder switches to listening for `next` before firing advance.
@property(nonatomic, strong, readonly, nullable) KKJoyrideTrigger *next;
@end

NS_ASSUME_NONNULL_END
