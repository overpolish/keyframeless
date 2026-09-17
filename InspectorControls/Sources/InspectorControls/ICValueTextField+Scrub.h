/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once

#import "ICValueTextField.h"

// The horizontal drag that scrubs the value. Split out because the drag runs
// its own event loop with the cursor warped and hidden, which is unrelated to
// the field's text editing and focus rules.
@interface ICValueTextField (Scrub)
// Applies one step, clamped by the formatter bounds, and dispatches the action.
- (void)scrubBy:(double)delta;
// Runs until mouse up. A drag that never passes the start threshold falls back
// to click editing, so a plain click still edits.
- (void)trackScrubFromMouseDown:(NSEvent *)event;
@end
