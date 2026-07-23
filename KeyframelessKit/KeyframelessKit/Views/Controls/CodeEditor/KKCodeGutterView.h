/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Line-number gutter for KKCodeEditorView: a plain flipped strip beside the
/// text, drawing the 1-based number of each visible line (wrapping is off, so
/// one fragment per line). No NSRulerView - we don't want its measurement
/// machinery. The owner redraws it on edit and on scroll.
@interface KKCodeGutterView : NSView
@property(nonatomic, weak) NSTextView *textView;
@property(nonatomic) NSInteger errorLine; // 1-based line to flag red, 0 = none
@end

NS_ASSUME_NONNULL_END
