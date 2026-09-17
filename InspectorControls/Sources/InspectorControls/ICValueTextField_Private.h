/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once

#import "ICValueTextField.h"

// State and geometry shared by the value field's sources: the field editor,
// the scrub drag and keyboard navigation. Each category declares its own
// methods in its own header.
@interface ICValueTextField ()
// Focus is only granted to an explicit click or keyboard navigation, so
// AppKit's own focus attempts are refused until one of them arms this.
@property(nonatomic) BOOL userClickPending;
// Inside -mouseDown:, where ending editing must not steal first responder.
@property(nonatomic) BOOL inMouseDown;
@property(nonatomic) BOOL icScrubbing;
// Tab navigation moves focus on, so ending editing must not clear it.
@property(nonatomic) BOOL icNavigatingAway;

// The drawn value, which is narrower than the field: clicks outside it blur
// rather than edit, and the text cursor only covers the value itself.
- (NSRect)visibleValueRect;
- (BOOL)eventIsOverValue:(NSEvent *)event;
- (void)blurForOutsideClick:(NSEvent *)event;
- (void)focusForKeyboardNavigation;
@end
