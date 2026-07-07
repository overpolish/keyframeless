/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One row in a help section's keyboard-shortcuts table. Both `keysMarkup`
/// and `descMarkup` are rendered through KKMarkup, so callers can embed
/// `<kbd>` badges or inline SF Symbols.
@interface KKHelpShortcut : NSObject

+ (instancetype)shortcutWithKeysMarkup:(NSString *)keysMarkup
                            descMarkup:(NSString *)descMarkup;

@property(nonatomic, readonly) NSAttributedString *keys;
@property(nonatomic, readonly) NSAttributedString *desc;

@end

/// A single section of help content. Renders as: title, optional bullet
/// list of tips, optional 2-column shortcuts table. Plugins return an
/// array of these from `-[KKPlugin helpSections]`.
@interface KKHelpSection : NSObject

+ (instancetype)sectionWithTitle:(NSString *)title
                       tipMarkup:(nullable NSArray<NSString *> *)tipMarkup
                       shortcuts:
                           (nullable NSArray<KKHelpShortcut *> *)shortcuts;

@property(nonatomic, readonly) NSString *title;
@property(nonatomic, copy) NSArray<NSAttributedString *> *tips;
@property(nonatomic, readonly) NSArray<KKHelpShortcut *> *shortcuts;

/// Optional SF Symbol or other image rendered to the left of the title.
@property(nonatomic, nullable, strong) NSImage *icon;

@end

/// A guided tutorial entry shown in the help window. Tap "Start" to launch
/// an in-inspector overlay walkthrough. The onStart block is called on the
/// main queue when the user taps the button.
@interface KKHelpGuide : NSObject

+ (instancetype)guideWithTitle:(NSString *)title
                      subtitle:(nullable NSString *)subtitle
                       onStart:(void (^)(void))onStart;

@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly, nullable) NSString *subtitle;
@property(nonatomic, readonly, copy) void (^onStart)(void);
/// Stable key for persisting completion state across launches. Defaults to
/// `title` when nil - set explicitly if the title may change.
@property(nonatomic, copy, nullable) NSString *identifier;

/// YES once the guide has been fully completed at least once (persisted
/// across launches via standard user defaults, keyed by identifier/title).
@property(nonatomic, readonly) BOOL hasBeenCompleted;
/// Records the guide as fully completed. Call only on genuine completion
/// (reached the final step), not on skip/dismiss.
- (void)markCompleted;

/// Marks the guide with `identifier` completed WITHOUT a live KKHelpGuide
/// instance - persists the same flag `-markCompleted` sets. Use when a guide
/// runs outside the help window (e.g. the first-apply intro autostart, which
/// has no help-row object to mark). `+isIdentifierCompleted:` reads it back.
+ (void)markIdentifierCompleted:(NSString *)identifier;
+ (BOOL)isIdentifierCompleted:(NSString *)identifier;
/// Block evaluated each time the row is drawn or refreshed. Return NO to show
/// the row disabled (dimmed icon, no action). Nil means always enabled.
@property(nonatomic, copy, nullable) BOOL (^enabledProvider)(void);
/// Subtitle shown instead of the normal one when enabledProvider returns NO.
@property(nonatomic, copy, nullable) NSString *disabledSubtitle;
/// When set, tapping the play button shows a loading spinner in its place
/// until this returns YES (the guide has finished warming up and is on
/// screen) or a short timeout elapses. Use for guides with an async start
/// (e.g. the OSC guide's zoom-to-fit + settle). Nil = start immediately.
@property(nonatomic, copy, nullable) BOOL (^activeProvider)(void);

@end

NS_ASSUME_NONNULL_END
