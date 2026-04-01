/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTiming.h"

@implementation KKTimingPhase

+ (instancetype)phaseWithEnabled:(BOOL)enabled
                        duration:(double)duration
                        progress:(double)progress
                     interpolate:(KKTimingInterpolator)interpolate {
  KKTimingPhase *phase = [[KKTimingPhase alloc] init];
  phase->_enabled = enabled;
  phase->_duration = duration;
  phase->_progress = progress;
  phase->_interpolate = [interpolate copy];
  return phase;
}

- (double)factor {
  return _interpolate(_progress);
}

@end

@implementation KKTimingResult

+ (instancetype)resultWithIn:(KKTimingPhase *)inPhase
                         mid:(KKTimingPhase *)midPhase
                         out:(KKTimingPhase *)outPhase {
  KKTimingResult *result = [[KKTimingResult alloc] init];
  result->_inPhase = inPhase;
  result->_midPhase = midPhase;
  result->_outPhase = outPhase;
  return result;
}

@end
