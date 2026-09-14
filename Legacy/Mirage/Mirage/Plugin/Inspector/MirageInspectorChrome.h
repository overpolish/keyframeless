/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKMiniViewerView;

NS_ASSUME_NONNULL_BEGIN

/// A button that answers the first click, since the windows these sit in never
/// become key: an ordinary NSButton spends that click asking for focus it
/// cannot get, so the eyedropper - or the compare row over the preview - would
/// need pressing twice.
@interface _MirageFirstMouseButton : NSButton
/// Set to make this a press-and-hold button: called YES on the press and NO on
/// the release, instead of firing an action once per click. Leave nil for the
/// ordinary click behaviour every other chrome button wants.
@property(nonatomic, copy, nullable) void (^onHoldChanged)(BOOL held);
@end

/// The backing a small row of chrome buttons sits on when it is placed ON the
/// mini viewer.
///
/// It has to claim its own hits explicitly. The mini viewer's overlay sits
/// between the Metal pass and this, and a press that fell through would start a
/// pan or grab an on-screen handle underneath the button the user was aiming
/// at.
@interface _MirageMiniChromeChip : NSView
@end

/// YES when `pointInView` - in the mini viewer's own coordinates - lands on a
/// chrome chip drawn over the preview.
///
/// Asked by the armed pickers, which otherwise treat every click inside the
/// picture as a sample: a click on a button is that button's, not a reading of
/// the pixel behind it.
FOUNDATION_EXPORT BOOL MiragePointInMiniChrome(KKMiniViewerView *_Nullable mini,
                                               NSPoint pointInView);

/// One chrome icon button in the inspector's house style. `symbol` may be nil
/// for a text button whose title the caller sets. The name is not drawn, but it
/// is what VoiceOver reads, so it stays localized rather than becoming a symbol
/// name.
FOUNDATION_EXPORT _MirageFirstMouseButton *
MirageMakeIconButton(NSString *_Nullable symbol, NSString *_Nullable label,
                     id _Nullable target, SEL _Nullable action);

/// A tooltip with the key that also works it, as " (B)".
///
/// Composed here rather than written into each localized sentence: the letter
/// is the physical key, so it is the same in every language, and folding it
/// into the translations would put seven copies of one keyboard fact in the
/// catalog for a translator to keep in step.
FOUNDATION_EXPORT NSString *_Nullable MirageWithShortcut(
    NSString *_Nullable tooltip, NSString *_Nullable key);

/// Remove an event monitor and forget it, tolerating one that was never
/// installed. The picker arms six of them together and the compare shortcuts
/// one, and a teardown that misses one leaves something eating clicks nobody
/// armed it for.
FOUNDATION_EXPORT void MirageDropMonitor(__strong id _Nullable *_Nullable slot);

/// The mini viewer inside a popover's own content view, or nil.
///
/// Found by walking the hierarchy rather than being handed over: the popover
/// notification carries the content view, and everything that wants the preview
/// - the Color panel in its own window, the compare row that lives ON the
/// preview - reaches it from there.
FOUNDATION_EXPORT KKMiniViewerView *_Nullable MirageFindMiniViewer(
    NSView *_Nullable root);

/// YES when something in this process is taking typed text.
///
/// The compare shortcuts are BARE letters, so this is the whole reason they are
/// safe: the code editor, the shader browser's search field and every inspector
/// text field are one keystroke away, and a stray "s" splitting the preview
/// instead of landing in the source would be unforgivable.
FOUNDATION_EXPORT BOOL MirageTextEditingInProgress(void);

NS_ASSUME_NONNULL_END
