/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

/// NSScrollView subclass that refuses to forward at-boundary scroll events
/// to an ancestor. AppKit walks up the responder chain via a private
/// selector and would otherwise hand our overscroll to FCP's inspector
/// root scroll view. Returning nil stops the walk here.
@interface KKSequencerScrollView : NSScrollView
@end
