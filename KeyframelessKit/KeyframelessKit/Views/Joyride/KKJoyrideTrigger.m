/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideTrigger_Internal.h"

@implementation KKJoyrideTrigger

+ (instancetype)_t:(KKJoyrideTriggerType)type {
  KKJoyrideTrigger *t = [[self alloc] init];
  t->_type = type;
  return t;
}

+ (instancetype)managePopoverWillOpen {
  return [self _t:KKJoyrideTriggerTypeManagePopoverWillOpen];
}

+ (instancetype)managePopoverClosed {
  return [self _t:KKJoyrideTriggerTypeManagePopoverClosed];
}

+ (instancetype)laneOptedIn:(NSString *)label {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypeLaneOptedIn];
  t->_label = [label copy];
  return t;
}

+ (instancetype)staticValuesPopoverWillOpen {
  return [self _t:KKJoyrideTriggerTypeStaticValuesPopoverWillOpen];
}

+ (instancetype)staticValuesPopoverClosed {
  return [self _t:KKJoyrideTriggerTypeStaticValuesPopoverClosed];
}

+ (instancetype)staticValueDragEndedForLabel:(NSString *)label {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypeStaticValueDragEnded];
  t->_label = [label copy];
  return t;
}

+ (instancetype)constantFieldEditedLabel:(NSString *)label
                               component:(NSInteger)component
                                  equals:(double)target
                               tolerance:(double)tolerance {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypeConstantFieldEdited];
  t->_label = [label copy];
  t->_intArg = component;
  t->_doubleArg = target;
  t->_doubleArg2 = tolerance;
  return t;
}

+ (instancetype)gapPopoverWillOpen {
  return [self _t:KKJoyrideTriggerTypeGapPopoverWillOpen];
}

+ (instancetype)gapPopoverCurveChanged:(NSInteger)curveType {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypeGapPopoverCurveChanged];
  t->_intArg = curveType;
  return t;
}

+ (instancetype)phaseToggled:(NSInteger)phase on:(BOOL)on {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypePhaseToggled];
  t->_intArg = phase;
  t->_intArg2 = on ? 1 : 0;
  return t;
}

+ (instancetype)diamondTapped:(NSInteger)idx {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypeDiamondTapped];
  t->_intArg = idx;
  return t;
}

+ (instancetype)gapTapped:(NSInteger)section {
  KKJoyrideTrigger *t = [self _t:KKJoyrideTriggerTypeGapTapped];
  t->_intArg = section;
  return t;
}

+ (instancetype)miniCanvasViewTransformChanged {
  return [self _t:KKJoyrideTriggerTypeMiniCanvasViewTransformChanged];
}

+ (instancetype)miniCanvasViewReset {
  return [self _t:KKJoyrideTriggerTypeMiniCanvasViewReset];
}

+ (instancetype)playToggleEdge {
  return [self _t:KKJoyrideTriggerTypePlayToggleEdge];
}

- (instancetype)thenWaitFor:(KKJoyrideTrigger *)next {
  _next = next;
  return self;
}

@end
