/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `// #audio` directives: bind a Sonar-published spectrogram to a uniform.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageDirectiveCommon.h"
#import "MirageTypes.h"

// --- Audio properties (`// #audio`) --------------------------------------
// Binds a Sonar-published spectrogram to the shader:
//     // #audio label="Music"          uniform vec4 uMusic[16];
// The uniform is a vec4 array because the pool is vec4s and std140 pads a
// float array to a 16-byte stride - packing 4 bands per vec4 costs a quarter
// of the pool. Bands = 4 * N, so `[16]` is 64 bands. The transpiler emits
// `<name>Band(i)` and `<name>Bands` so the shader never indexes that packing
// by hand.
//
// The directive names NO source: which analysis fills it is a dropdown on the
// lane, populated from the manifest. So a shared shader can't reference a
// source the recipient doesn't have.
#define KK_SHADER_MAX_AUDIO_PROPS 2
#define KK_SHADER_MAX_AUDIO_VECS 24
#define KK_SHADER_MAX_AUDIO_WAVE_SAMPLES 128

/// Audio lanes get their own inspector group: they aren't a look the way the
/// other directive lanes are, and a source + its gate + its smoothing only make
/// sense read together.
static NSString *const kMirageAudioCategory = @"Audio";
static NSString *const kMirageAudioCategorySymbol = @"waveform";

/// The gate lane's floor, in dB. Below any analysis window, so the bottom of
/// the slider means "gate off" without a magic value.
static const double kMirageAudioGateOffDB = -90.0;
/// The smoothness lane's cap, in seconds. Past this the spectrum is averaged so
/// far that nothing reads as reacting to the audio any more.
static const double kMirageAudioSmoothMaxSec = 0.5;
/// The release lane's cap, in seconds. Also bounds how far back a render looks
/// to find when a band last cleared the gate.
static const double kMirageAudioReleaseMaxSec = 2.0;
static const double kMirageAudioWaveformWindowMinSec = 0.005;
static const double kMirageAudioWaveformWindowMaxSec = 0.25;

/// The lanes each `#audio` uniform owns, suffixed off the uniform name. A dot
/// can't occur in a GLSL identifier, so these can never collide with one the
/// author declared. Built by the catalog, read back by the pool - hence here,
/// where both can see them, rather than as a literal in each.
static inline NSString *MirageAudioGateLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".gate"];
}
static inline NSString *MirageAudioSmoothLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".smooth"];
}
static inline NSString *MirageAudioReleaseLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".release"];
}
static inline NSString *
MirageAudioWaveformWindowLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".wavewindow"];
}
typedef struct MirageAudioProp {
  char name[64];  // GLSL uniform name
  char label[80]; // display label
  int vecCount;   // vec4s (declared array size)
  int bands;      // 4 * vecCount
  int poolOffset; // first vec4 index in the pool
  /// `smooth=` seconds: the spectrum is averaged over a window this wide,
  /// centred on the render time. Raw 60Hz bands are extremely twitchy - speech
  /// and drums are transients - so a shader mapping them straight to geometry
  /// jitters. Averaged rather than smoothed with a running filter because
  /// renders are random-access (scrub, motion-blur sub-frames, out-of-order
  /// pre-render): a stateful filter would give a different answer depending on
  /// how you got to a frame, so the same frame would look different on scrub
  /// than on playback. 0 = raw.
  double smoothSeconds;
  /// `gate=` dB: bands quieter than this read as silence. A room is never
  /// actually silent - air, hiss, a preamp - so an ungated visual never quite
  /// settles between beats, and the noise is what a shader mapping the low end
  /// to a radius shows as a permanent tremble. NAN = no gate (the default).
  ///
  /// In dB rather than a 0...1 band value because that's the unit the level
  /// exists in: -60 means the same thing whatever window the analysis used, and
  /// the file carries that window so the conversion is exact.
  double gateDB;
  /// `release=` seconds: how long a band takes to fall to zero once it drops
  /// below the gate. Without it the gate is a switch - a bar is at its height
  /// one frame and gone the next - which reads as a glitch rather than as a
  /// sound stopping. Attack stays instant: signal returning should snap back.
  double releaseSeconds;
  /// `flow` present: also expose `<name>Flow`, a monotonic cumulative energy
  /// clock (`KKSpectrogramFlowAtTime`). A beat advances it and it never
  /// retreats, so a shader can push geometry outward per beat without the
  /// pull-back a live band value forces. Costs one extra pool vec4 (scalar in
  /// `.x`).
  int wantsFlow;
  /// The extra pool vec4 holding the flow scalar (valid only when `wantsFlow`),
  /// appended right after this prop's band vecs so later props keep their
  /// offsets.
  int flowPoolOffset;
  /// The SHADER-band range the flow accumulates over (inclusive), folded to
  /// analysis bands at fill time. Defaults to the lowest 4 (0..3) - the kick.
  int flowLoBand;
  int flowHiBand;
  /// `flowgate=` dB: the flow's own fixed threshold (NOT the animatable bar
  /// gate). Kept fixed and separate so the accumulation is stable - an animated
  /// accumulation floor would make the clock's history depend on the curve. A
  /// quiet noise floor under it never advances the clock.
  double flowGateDB;
  /// `waveform=N`: expose N time-domain samples as `<name>Wave(i)`. This is
  /// opt-in because it consumes ceil(N/4) additional pool vec4s.
  int wantsWaveform;
  int waveformSamples;
  int waveformVecCount;
  int waveformPoolOffset;
  /// `wavewindow=` seconds: the centred span resampled into those N values.
  double waveformWindowSeconds;
} MirageAudioProp;

/// Parse every `// #audio [label=]` directive + its `uniform vec4 <name>[N];`.
/// `startOffset` is the first free pool vec4 (audio is appended after the
/// colour and scalar props, so neither path shifts).
static inline int MirageParseAudioProps(NSString *source,
                                        MirageAudioProp *props, int maxProps,
                                        int startOffset, int *outUsed) {
  int n = 0, pool = startOffset;
  if (outUsed)
    *outUsed = 0;
  if (!source.length || maxProps <= 0)
    return 0;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ \\t]*#audio(?![-\\w])([^\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+vec4\\s+(\\w+)\\s*\\[\\s*(\\d+)\\s*\\]\\s*;"
                           options:0
                             error:nil];
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (int di = 0; di < (int)dirs.count && n < maxProps; di++) {
    NSTextCheckingResult *dm = dirs[di];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:1]];
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit = (di + 1 < (int)dirs.count) ? dirs[di + 1].range.location
                                                  : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um || [um rangeAtIndex:1].location == NSNotFound)
      continue; // a directive with no declaration is ignored
    NSString *nm = [source substringWithRange:[um rangeAtIndex:1]];
    int N = [source substringWithRange:[um rangeAtIndex:2]].intValue;
    if (N < 1)
      N = 1;
    if (N > KK_SHADER_MAX_AUDIO_VECS)
      N = KK_SHADER_MAX_AUDIO_VECS;
    BOOL wantsFlow = MirageAttrHasBareFlag(attrs, @"flow");
    int waveformSamples =
        (int)MirageAttrDouble(attrs, @"\\bwaveform\\s*=\\s*(\\d+)", 0);
    if (waveformSamples < 0)
      waveformSamples = 0;
    if (waveformSamples > KK_SHADER_MAX_AUDIO_WAVE_SAMPLES)
      waveformSamples = KK_SHADER_MAX_AUDIO_WAVE_SAMPLES;
    int waveformVecs = (waveformSamples + 3) / 4;
    if (pool + N + (wantsFlow ? 1 : 0) + waveformVecs > KK_SHADER_COLOR_POOL)
      break; // pool full - drop the rest

    MirageAudioProp p;
    memset(&p, 0, sizeof(p));
    strncpy(p.name, nm.UTF8String ?: "", sizeof(p.name) - 1);
    NSTextCheckingResult *lm = [[NSRegularExpression
        regularExpressionWithPattern:@"\\blabel\\s*=\\s*\"([^\"]*)\""
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    NSString *label =
        (lm && [lm rangeAtIndex:1].location != NSNotFound && lm.range.length)
            ? [attrs substringWithRange:[lm rangeAtIndex:1]]
            : MiragePrettifyUniformName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    p.vecCount = N;
    p.bands = N * 4;
    p.smoothSeconds =
        MirageAttrDouble(attrs, @"\\bsmooth\\s*=\\s*([0-9.]+)", 0.08);
    // NAN = absent, so a gate at 0 dB (everything below full scale is silent -
    // daft, but the author's call) still reads as a gate.
    p.gateDB = MirageAttrDouble(attrs, @"\\bgate\\s*=\\s*(-?[0-9.]+)", NAN);
    p.releaseSeconds =
        MirageAttrDouble(attrs, @"\\brelease\\s*=\\s*([0-9.]+)", 0.15);
    p.poolOffset = pool;
    pool += N;
    p.wantsFlow = wantsFlow ? 1 : 0;
    if (wantsFlow) {
      int lo = (int)MirageAttrDouble(attrs, @"\\bflowlo\\s*=\\s*(\\d+)", 0);
      int hi = (int)MirageAttrDouble(attrs, @"\\bflowhi\\s*=\\s*(\\d+)", 3);
      if (lo < 0)
        lo = 0;
      if (hi > p.bands - 1)
        hi = p.bands - 1;
      if (hi < lo)
        hi = lo;
      p.flowLoBand = lo;
      p.flowHiBand = hi;
      p.flowGateDB =
          MirageAttrDouble(attrs, @"\\bflowgate\\s*=\\s*(-?[0-9.]+)", -45.0);
      p.flowPoolOffset = pool;
      pool += 1;
    }
    p.wantsWaveform = waveformSamples > 0 ? 1 : 0;
    if (p.wantsWaveform) {
      p.waveformSamples = waveformSamples;
      p.waveformVecCount = waveformVecs;
      p.waveformWindowSeconds =
          MirageAttrDouble(attrs, @"\\bwavewindow\\s*=\\s*([0-9.]+)", 0.04);
      if (p.waveformWindowSeconds < kMirageAudioWaveformWindowMinSec)
        p.waveformWindowSeconds = kMirageAudioWaveformWindowMinSec;
      if (p.waveformWindowSeconds > kMirageAudioWaveformWindowMaxSec)
        p.waveformWindowSeconds = kMirageAudioWaveformWindowMaxSec;
      p.waveformPoolOffset = pool;
      pool += waveformVecs;
    }
    props[n++] = p;
  }
  if (outUsed)
    *outUsed = pool - startOffset;
  return n;
}

#endif // __METAL_VERSION__
