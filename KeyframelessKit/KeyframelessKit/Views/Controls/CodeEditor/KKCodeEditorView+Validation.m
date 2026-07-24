/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Validation + the error / result strips: run the host validator over the
// active section, flag the error line + message, drive the read-only result
// strip (host `-> value` readout, its sparkline, expression-error state), and
// the Format action. Split out of KKCodeEditorView.m; reaches editor state via
// the @package ivars in KKCodeEditorView_Private.h.

#import "KKCodeEditorSubviews.h" // _KKSparklineView
#import "KKCodeEditorView_Private.h"
#import "KKCodeGutterView.h" // _lineGutter.errorLine
#import "KKGLSLSyntax.h"
#import "KKLinkExpr.h" // built-in expression validator
#import "KKLocalized.h"
#import "KKTokens.h"
#import <QuartzCore/QuartzCore.h> // CATransaction / CAGradientLayer

@interface KKCodeEditorView (ValidationPrivate)
- (void)_refreshResultStrip;
@end

@implementation KKCodeEditorView (Validation)

- (void)_formatClicked:(id)sender {
  // formatUsing: lives in +Sections.m (declared in the public (Sections)
  // category, so it's callable here).
  [self formatUsing:self.codeFormatter];
}

- (void)_runValidator {
  // A host may pre-compose the active section with others (e.g. a shader
  // prepending a shared section) before validation; `prependLines` maps a
  // reported error line back to the active section, and an error landing in the
  // prepended region is suppressed here (it surfaces on that section's own
  // tab). With no composer the active section is validated as-is.
  NSString *code = _textView.string;
  NSInteger prependLines = 0;
  NSString *activeName = (_activeTab < (NSInteger)_sectionNames.count)
                             ? _sectionNames[_activeTab]
                             : @"";
  if (self.validationSourceComposer) {
    NSInteger pl = 0;
    NSString *composed =
        self.validationSourceComposer(activeName, code, [self sections], &pl);
    if (composed) {
      code = composed;
      prependLines = pl;
    }
  }
  NSInteger line = 0;
  NSString *err = self.codeValidator ? self.codeValidator(code, &line) : nil;
  // line 0 = "no line info" (e.g. the transpiler's own WRAPPER failed, whose
  // lines map to nothing in any tab) - such an error must still surface, just
  // without a highlighted line. Only a REAL line inside the prepended region
  // belongs to the prepended section and is suppressed (it's flagged on that
  // section's own tab).
  if (err.length && prependLines > 0 && line > 0) {
    line -= prependLines;
    if (line < 1) { // error lives in Common; it's flagged on the Common tab
      err = nil;
      line = 0;
    }
  }
  // Expression editors have a BUILT-IN validator (KKLinkExpr) rather than a
  // host block, so they get the same error treatment (red line + gutter +
  // message + copy) for free.
  if (!self.codeValidator && self.syntax == KKCodeSyntaxExpression) {
    NSString *msg = nil;
    NSString *exprSrc = _textView.string;
    NSRange bad = [KKLinkExpr errorCharRangeForSource:exprSrc message:&msg];
    if (bad.location != NSNotFound && msg.length) {
      // Sentence-case the parser message.
      err = [[[msg substringToIndex:1] uppercaseString]
          stringByAppendingString:[msg substringFromIndex:1]];
      line = 1; // the line the error sits on (expressions are single-line)
      for (NSUInteger i = 0; i < bad.location && i < exprSrc.length; i++)
        if ([exprSrc characterAtIndex:i] == '\n')
          line++;
    }
  }
  _errorLine = err.length ? line : 0;

  // GLSL uses the tall (20px) error bar; the compact expression editor has no
  // room for it, so it surfaces the message in the result strip (with its own
  // copy button) instead. Both share the red line + red gutter highlight.
  BOOL exprMode = (self.syntax == KKCodeSyntaxExpression);
  BOOL useBar = err.length && !exprMode;
  if (useBar) {
    _errorLabel.stringValue = err;
    [_errorLabel sizeToFit];
    // Document view = the text's own size so the scroll can pan a wide message
    // and the single line stays vertically centered (clip height == line
    // height).
    NSSize fit = _errorLabel.fittingSize;
    CGFloat lineH = ceil(fit.height);
    _errorLabel.frame = NSMakeRect(0, 0, ceil(fit.width) + 4.0, lineH);
    _errorScrollHeight.constant = lineH;
    [_errorScroll.contentView scrollToPoint:NSZeroPoint]; // reset to start
    _errorBarHeight.constant = 20.0;
  } else {
    _errorLabel.stringValue = @"";
    _errorBarHeight.constant = 0.0;
  }
  _errorCopyButton.hidden = !useBar;
  _exprErrorText = (err.length && exprMode) ? err : nil;
  [self _errorScrolled]; // refresh overflow fades for the new message width
  _lineGutter.errorLine = _errorLine;
  [self _applyHighlighting];  // repaint the flagged-line background
  [self _refreshResultStrip]; // expression message / value + copy button
  [_lineGutter setNeedsDisplay:YES];
}

- (void)_copyError:(id)sender {
  NSString *msg = _errorLabel.stringValue;
  if (!msg.length)
    return;
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:msg forType:NSPasteboardTypeString];
}

- (NSString *)resultText {
  return _resultValueText;
}

- (void)setResultText:(NSString *)resultText {
  _resultValueText = [resultText copy];
  [self _refreshResultStrip];
}

// The strip shows the parser error (red, Error-Lens style: always visible, no
// hover) when the expression is invalid, otherwise the host's "-> value"
// readout (dim) with its sparkline. Error wins because an invalid expression
// has no value.
- (void)_refreshResultStrip {
  BOOL hasError = _exprErrorText.length > 0;
  NSString *text = hasError ? _exprErrorText : (_resultValueText ?: @"");
  _resultLabel.stringValue = text;
  _resultLabel.textColor =
      hasError ? KKCodeError() : [KKCodeText() colorWithAlphaComponent:0.55];
  // Match the GLSL error bar: red text on a dark-red strip when invalid, the
  // neutral panel tint otherwise.
  _resultBar.layer.backgroundColor =
      (hasError ? KKHex(0x2d1214) : KKHex(0x161b22)).CGColor;
  _resultBarHeight.constant = text.length ? 16.0 : 0.0;
  // Error and value are mutually exclusive in the strip: error shows the copy
  // button, a valid value shows the sparkline.
  _resultCopyButton.hidden = !hasError;
  _sparkline.hidden =
      hasError || text.length == 0 || _sparkline.samples.count < 2;
}

- (void)_copyExprError:(id)sender {
  if (!_exprErrorText.length)
    return;
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:_exprErrorText forType:NSPasteboardTypeString];
}

- (NSArray<NSNumber *> *)sparklineSamples {
  return _sparkline.samples;
}

- (void)setSparklineSamples:(NSArray<NSNumber *> *)sparklineSamples {
  _sparkline.samples = sparklineSamples;
  [self _refreshResultStrip];
}

- (double)sparklineMarker {
  return _sparkline.marker;
}

- (void)setSparklineMarker:(double)sparklineMarker {
  _sparkline.marker = sparklineMarker;
}

// Overflow edge-fade opacities track the horizontal scroll position of the
// error message (each gradient fades in as there's content hidden that way).
- (void)_errorScrolled {
  CGFloat docW = NSWidth(_errorLabel.frame);
  CGFloat visW = _errorScroll.contentView.bounds.size.width;
  CGFloat offX = _errorScroll.contentView.bounds.origin.x;
  CGFloat scrollable = docW - visW;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (scrollable <= 0.5) {
    _errLeftGrad.opacity = 0.0;
    _errRightGrad.opacity = 0.0;
  } else {
    _errLeftGrad.opacity = (float)MAX(0.0, MIN(1.0, offX / 16.0));
    _errRightGrad.opacity =
        (float)MAX(0.0, MIN(1.0, (scrollable - offX) / 16.0));
  }
  [CATransaction commit];
}

@end
