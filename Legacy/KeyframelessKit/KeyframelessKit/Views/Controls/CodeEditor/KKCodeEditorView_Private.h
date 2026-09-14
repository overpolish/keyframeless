/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared internals for KKCodeEditorView and its category splits
// (+Highlighting / +Autocomplete / +Sections / +SaveBar / +Validation). The
// ivars are @package so the categories - which cannot see the primary class's
// synthesized backing store - can reach the same state the main .m builds.

#import "KKCodeEditorView.h"

@class _KKExprCompletionView;
@class _KKSparklineView;
@class KKCodeGutterView;
@class _KKDropdownTrigger;
@class KKChoiceChecklistView;
@class CAGradientLayer;

@interface KKCodeEditorView () <NSTextViewDelegate, NSTextStorageDelegate,
                                NSTextFieldDelegate, NSPopoverDelegate> {
@package
  NSTextView *_textView;
  NSTimer *_debounce;
  // Inline autocomplete (Expression syntax only): the overlay list, its current
  // matches, the highlighted row, and the partial-word range being completed.
  _KKExprCompletionView *_completion;
  NSArray<NSDictionary<NSString *, NSString *> *> *_completionItems;
  NSInteger _completionIndex;
  NSRange _completionWord;
  BOOL _completionEditInFlight; // a selection change from a typed/programmatic
                                // edit, so it should refresh, not dismiss, the
                                // list
  NSSet<NSString *>
      *_glslDeclaredUniforms; // this shader's uniform names, so a
                              // `@osc` body reference paints orange
                              // too (recomputed each highlight)
  BOOL _highlightScheduled;
  BOOL _validatorScheduled;
  KKCodeGutterView *_lineGutter;
  NSView *_errorBar;             // red strip container (height toggled 0/on)
  NSScrollView *_errorScroll;    // horizontal scroll so long messages fit
  NSTextField *_errorLabel;      // the message (document view of _errorScroll)
  NSButton *_errorCopyButton;    // floats on the right, copies the message
  CAGradientLayer *_errLeftGrad; // overflow edge fades (opacity = scroll pos)
  CAGradientLayer *_errRightGrad;
  NSLayoutConstraint
      *_errorScrollHeight; // = label line height, centered in strip
  NSLayoutConstraint *_errorBarHeight;
  NSInteger _errorLine; // 1-based line to flag, 0 = none
  // Optional read-only result strip (height toggled 0/on), under the error bar:
  // a host pushes the live computed result of an expression here for clarity.
  NSView *_resultBar;
  NSTextField *_resultLabel;
  _KKSparklineView *_sparkline; // trailing curve preview in the result strip
  NSButton *_resultCopyButton;  // trailing copy button, shown only on error
  NSLayoutConstraint *_resultBarHeight;
  NSString *_resultValueText;   // host's "-> value" readout (shown when valid)
  NSString *_resultWarningText; // amber note (valid, but worth flagging)
  NSString
      *_exprErrorText; // parser error (shown red in the strip when invalid)
  NSView *_saveBar;    // optional name + Save strip (height toggled 0/on)
  NSTextField *_saveNameField;
  NSButton *_saveButton;
  BOOL _saveBlocked; // saveValidator vetoed the current code
  NSLayoutConstraint *_saveBarHeight;
  id _nameOutsideClickMon; // blur the name field on an outside click
  // Optional category picker between the name field and Save. Width collapses
  // to 0 when a host offers no labels, so the name field takes the whole strip.
  _KKDropdownTrigger *_saveCategoryField;
  NSLayoutConstraint *_saveCategoryWidth;
  NSLayoutConstraint *_saveCategoryGap; // name field -> picker
  NSPopover *_saveCategoryPopover;
  KKChoiceChecklistView *_saveCategoryList;
  NSArray<NSString *> *_saveCategoryLabels;
  NSInteger _saveCategoryIndex;
  // Tabbed sections: parallel names/codes, the active one shown in _textView.
  // A single (default) section behaves exactly like the plain editor - the tab
  // strip stays collapsed.
  NSMutableArray<NSString *> *_sectionNames;
  NSMutableArray<NSString *> *_sectionCodes;
  NSInteger _activeTab;
  NSStackView *_tabBar;
  NSLayoutConstraint *_tabBarHeight;
  // Copy Schema: the live Option retitle ("+ Code"), and the 1s "Copied" flash
  // that outranks it while it shows.
  NSButton *_schemaButton;
  NSTimer *_optPollTimer;
  BOOL _optHeld;
  BOOL _schemaFlashing;
}
@end

// Private methods shared across the category splits (called from the main .m or
// another category, so they need a visible declaration).
@interface KKCodeEditorView (Private)
// +Highlighting
- (void)_applyHighlighting;
// Core (main .m) - used by +Highlighting to flag the error line.
- (NSRange)_rangeOfLine:(NSInteger)line in:(NSString *)s;
// +Autocomplete - driven from the core text-delegate + escape handler.
- (void)_updateCompletions;
- (void)_hideCompletion;
// +Sections - the tab strip is rebuilt from the core init + external applies.
- (void)_rebuildTabBar;
// +Sections - the Copy Schema button's live Option retitle. Driven from the
// core's window hooks so the poll only runs while the editor is on screen.
- (void)_startOptionModifierPolling;
- (void)_stopOptionModifierPolling;
// +Sections - the `// #tab` multi-tab paste, offered from the text view's
// paste hook. YES = consumed (the blob was split across the tabs).
- (BOOL)_applyTabbedPaste:(NSString *)text;
// Core (main .m) - is there local uncommitted typing (guards a tab swap).
- (BOOL)_hasUncommittedTyping;
// +Validation - re-run on a section swap / external apply.
- (void)_runValidator;
// +Validation - the same run, coalesced onto the next runloop turn. For the
// paths that set text while the editor is being BUILT (a popover row): a host
// validator can be a full transpile, and running it inline blocks the popover
// from appearing until it finishes.
- (void)_scheduleValidator;
// +Validation - button/scroll targets wired from the core-built error strip.
- (void)_copyError:(id)sender;
- (void)_copyExprError:(id)sender;
- (void)_errorScrolled;
- (void)_formatClicked:(id)sender;
// +SaveBar - the category dropdown is toggled from the core-built save strip.
- (void)_toggleSaveCategoryList;
// +SaveBar - Save button target wired from the core-built save strip.
- (void)_saveClicked:(id)sender;
// +SaveBar - Save = name present AND no saveValidator veto (+Validation sets
// _saveBlocked and calls this).
- (void)_refreshSaveButtonEnabled;
@end
