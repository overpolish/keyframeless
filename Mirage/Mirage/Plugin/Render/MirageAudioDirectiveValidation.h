/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageShaderModel.h"

typedef enum MirageAudioWaveformErrorKind {
  MirageAudioWaveformErrorValue = 0,
  MirageAudioWaveformErrorRange = 1,
  MirageAudioWaveformErrorWindowWithoutWaveform = 2,
  MirageAudioWaveformErrorWindowValue = 3,
  MirageAudioWaveformErrorWindowRange = 4,
} MirageAudioWaveformErrorKind;

/// Validate the opt-in time-domain payload:
///   #audio ... waveform=128 wavewindow=0.04
static inline NSString *
MirageFirstInvalidAudioWaveform(NSString *source,
                                MirageAudioWaveformErrorKind *outKind) {
  if (!source.length)
    return nil;
  NSRegularExpression *directives = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ \\t]*#audio(?![-\\w])([^\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *waveWord =
      [NSRegularExpression regularExpressionWithPattern:@"\\bwaveform\\b"
                                                options:0
                                                  error:nil];
  NSRegularExpression *waveValue = [NSRegularExpression
      regularExpressionWithPattern:@"\\bwaveform\\s*=\\s*([^\\s]+)"
                           options:0
                             error:nil];
  NSRegularExpression *windowWord =
      [NSRegularExpression regularExpressionWithPattern:@"\\bwavewindow\\b"
                                                options:0
                                                  error:nil];
  NSRegularExpression *windowValue = [NSRegularExpression
      regularExpressionWithPattern:@"\\bwavewindow\\s*=\\s*([^\\s]+)"
                           options:0
                             error:nil];
  for (NSTextCheckingResult *match in
       [directives matchesInString:source
                           options:0
                             range:NSMakeRange(0, source.length)]) {
    NSString *attrs = [source substringWithRange:[match rangeAtIndex:1]];
    NSRange all = NSMakeRange(0, attrs.length);
    NSTextCheckingResult *wave = [waveValue firstMatchInString:attrs
                                                       options:0
                                                         range:all];
    BOOL mentionsWaveform = [waveWord firstMatchInString:attrs
                                                 options:0
                                                   range:all] != nil;
    if (mentionsWaveform && !wave) {
      if (outKind)
        *outKind = MirageAudioWaveformErrorValue;
      return @"waveform";
    }
    if (wave) {
      NSString *raw = [attrs substringWithRange:[wave rangeAtIndex:1]];
      NSScanner *scanner = [NSScanner scannerWithString:raw];
      NSInteger samples = 0;
      if (![scanner scanInteger:&samples] || !scanner.isAtEnd) {
        if (outKind)
          *outKind = MirageAudioWaveformErrorValue;
        return raw;
      }
      if (samples < 4 || samples > KK_SHADER_MAX_AUDIO_WAVE_SAMPLES) {
        if (outKind)
          *outKind = MirageAudioWaveformErrorRange;
        return raw;
      }
    }

    NSTextCheckingResult *window = [windowValue firstMatchInString:attrs
                                                           options:0
                                                             range:all];
    BOOL mentionsWindow = [windowWord firstMatchInString:attrs
                                                 options:0
                                                   range:all] != nil;
    if (mentionsWindow && !wave) {
      if (outKind)
        *outKind = MirageAudioWaveformErrorWindowWithoutWaveform;
      return @"wavewindow";
    }
    if (mentionsWindow && !window) {
      if (outKind)
        *outKind = MirageAudioWaveformErrorWindowValue;
      return @"wavewindow";
    }
    if (window) {
      NSString *raw = [attrs substringWithRange:[window rangeAtIndex:1]];
      NSScanner *scanner = [NSScanner scannerWithString:raw];
      double seconds = 0;
      if (![scanner scanDouble:&seconds] || !scanner.isAtEnd) {
        if (outKind)
          *outKind = MirageAudioWaveformErrorWindowValue;
        return raw;
      }
      if (seconds < kMirageAudioWaveformWindowMinSec ||
          seconds > kMirageAudioWaveformWindowMaxSec) {
        if (outKind)
          *outKind = MirageAudioWaveformErrorWindowRange;
        return raw;
      }
    }
  }
  return nil;
}

#endif // __METAL_VERSION__
