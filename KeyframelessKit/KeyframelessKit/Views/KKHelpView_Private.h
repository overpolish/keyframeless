/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKHelpView.h"
#import "KKHelpViewSubviews.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN const CGFloat KKHelpPagePadding;
FOUNDATION_EXTERN const CGFloat KKHelpSectionGap;
FOUNDATION_EXTERN const CGFloat KKHelpAfterTitleGap;
FOUNDATION_EXTERN const CGFloat KKHelpKeyColumnMin;

@interface KKHelpView () {
@protected
  NSArray<KKHelpGuide *> *_guides;
  NSStackView *_guidesLinksStack;
  NSMutableArray<_KKGuideRowRefs *> *_guideRowRefs;
  id _refreshObserver;
  NSTimer *_refreshTimer;
}
/// Muted section sub-label ("Shortcuts", "On this page", "Interactive
/// Guides"). Shared by the content builders and the Guides category.
- (NSView *)_subheading:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
