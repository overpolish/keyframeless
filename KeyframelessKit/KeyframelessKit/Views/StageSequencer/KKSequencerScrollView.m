/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSequencerScrollView.h"

@implementation KKSequencerScrollView

// AppKit calls this private method to find the ancestor scroll view that wants
// forwarded at-boundary scroll events. Returning nil makes the search fail, so
// FCP's OZViewCtrlRootScrollView never receives our overscroll and the
// inspector stays put.
- (NSResponder *)_recursiveResponderThatWantsForwardedScrollEventsForAxis:
                     (NSEventGestureAxis)axis
                                                         intendedForSwipe:
                                                             (BOOL)forSwipe {
  return nil;
}

@end
