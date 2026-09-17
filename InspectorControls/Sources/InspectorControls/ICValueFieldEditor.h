/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once

#import "ICValueTextField.h"

// The field editor and cell the value field installs. Split out because they
// exist to keep numeric editing free of AppKit's text services and to route
// editor clicks back to the field's own hit rules.
@interface ICValueFieldEditor : NSTextView
@property(nonatomic,weak) ICValueTextField *valueField;
- (void)configureNumericInput;
@end

@interface ICValueTextFieldCell : NSTextFieldCell
@property(nonatomic,strong) ICValueFieldEditor *valueEditor;
@end

// An I-beam over the drawn value and an arrow everywhere else, so the pointer
// shows whether a click edits or scrubs.
void ICRegisterValueCursorRects(NSView *view, NSRect text, BOOL enabled);
void ICStyleFieldEditorAccent(NSText *editor);
// Edit-menu shortcuts while editing: the host's menu does not reach the
// inspector's field editor.
BOOL ICHandleEditMenuKeyEquivalent(NSText *editor, NSEvent *event);
