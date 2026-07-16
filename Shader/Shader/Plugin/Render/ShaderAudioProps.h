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

#import "ShaderDirectiveCommon.h"
#import "ShaderTypes.h"

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

/// Audio lanes get their own inspector group: they aren't a look the way the
/// other directive lanes are, and a source + its gate + its smoothing only make
/// sense read together.
static NSString *const kShaderAudioCategory = @"Audio";
static NSString *const kShaderAudioCategorySymbol = @"waveform";

/// The gate lane's floor, in dB. Below any analysis window, so the bottom of
/// the slider means "gate off" without a magic value.
static const double kShaderAudioGateOffDB = -90.0;
/// The smoothness lane's cap, in seconds. Past this the spectrum is averaged so
/// far that nothing reads as reacting to the audio any more.
static const double kShaderAudioSmoothMaxSec = 0.5;
/// The release lane's cap, in seconds. Also bounds how far back a render looks
/// to find when a band last cleared the gate.
static const double kShaderAudioReleaseMaxSec = 2.0;

/// The lanes each `#audio` uniform owns, suffixed off the uniform name. A dot
/// can't occur in a GLSL identifier, so these can never collide with one the
/// author declared. Built by the catalog, read back by the pool - hence here,
/// where both can see them, rather than as a literal in each.
static inline NSString *ShaderAudioGateLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".gate"];
}
static inline NSString *ShaderAudioSmoothLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".smooth"];
}
static inline NSString *ShaderAudioReleaseLaneLabel(NSString *uniformName) {
  return [uniformName stringByAppendingString:@".release"];
}
typedef struct ShaderAudioProp {
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
} ShaderAudioProp;

/// A stable numeric id for a published source, from its manifest `contentHash`
/// (falling back to `id`). The `#audio` lane stores THIS, not the dropdown
/// index, so deleting a source in Sonar doesn't silently repoint every shader
/// that pointed past it.
///
/// 24 bits, and never 0: lane values travel as floats, whose mantissa holds
/// integers exactly only to 2^24, and 0 is reserved for "None". Collisions are
/// a non-issue across the handful of sources one project publishes.
static inline double ShaderAudioSourceKey(NSString *contentHash) {
  if (contentHash.length == 0)
    return 0;
  uint32_t hash = 5381;
  for (NSUInteger i = 0; i < contentHash.length; i++)
    hash = (hash * 33u) + (uint32_t)[contentHash characterAtIndex:i];
  hash &= 0xFFFFFFu;
  return (double)(hash == 0 ? 1u : hash);
}

/// Parse every `// #audio [label=]` directive + its `uniform vec4 <name>[N];`.
/// `startOffset` is the first free pool vec4 (audio is appended after the
/// colour and scalar props, so neither path shifts).
static inline int ShaderParseAudioProps(NSString *source,
                                        ShaderAudioProp *props, int maxProps,
                                        int startOffset, int *outUsed) {
  int n = 0, pool = startOffset;
  if (outUsed)
    *outUsed = 0;
  if (!source.length || maxProps <= 0)
    return 0;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#audio\\b([^\\n]*)$"
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
    if (pool + N > KK_SHADER_COLOR_POOL)
      break; // pool full - drop the rest

    ShaderAudioProp p;
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
            : ShaderPrettifyUniformName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    p.vecCount = N;
    p.bands = N * 4;
    p.smoothSeconds =
        ShaderAttrDouble(attrs, @"\\bsmooth\\s*=\\s*([0-9.]+)", 0.08);
    // NAN = absent, so a gate at 0 dB (everything below full scale is silent -
    // daft, but the author's call) still reads as a gate.
    p.gateDB = ShaderAttrDouble(attrs, @"\\bgate\\s*=\\s*(-?[0-9.]+)", NAN);
    p.releaseSeconds =
        ShaderAttrDouble(attrs, @"\\brelease\\s*=\\s*([0-9.]+)", 0.15);
    p.poolOffset = pool;
    pool += N;
    props[n++] = p;
  }
  if (outUsed)
    *outUsed = pool - startOffset;
  return n;
}

#endif // __METAL_VERSION__
