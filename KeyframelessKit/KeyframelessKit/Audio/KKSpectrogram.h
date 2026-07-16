/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A timeline-indexed audio spectrogram, published by Sonar and read by any
/// visual plugin that wants audio to drive its render.
///
/// Deliberately NOT Shader-specific: Sonar produces a general audio feed, and
/// Shader is only consumer #1. The only Shader-coupled part lives in Shader
/// (binding a source to a `sampler2D`).
///
/// The file is the contract, so the byte layout is defined once, here, and both
/// the writer and reader below use it. A Swift copy of the layout in the
/// extension would drift the moment either side changed.
///
/// Layout (little-endian):
///   char[4]  magic       "KKSG"
///   uint32   version     current = KKSpectrogramFormatVersion
///   uint32   numFrames
///   uint32   numBands
///   float64  hopSeconds
///   float64  timelineStart
///   float32  data[numFrames * numBands]   row-major [frame][band], 0...1
///
/// Frame f is timeline second `timelineStart + f * hopSeconds`.
///
/// TIMELINE seconds, including the project's start timecode, which a plugin
/// must convert to before sampling. An FxPlug render time in FCP is NOT it:
/// renderTime, `startTimeForEffect:` and `startTimeOfInputToFilter:` all speak
/// the input's own native media clock, and `inPointTimeOfTimelineForEffect:`
/// gives the project's 0..duration range rather than its origin.
/// `timelineTime:fromInputTime:` is the only API that answers in this clock.
/// Sampling at renderTime directly happens to work when a clip starts at the
/// project's start and its media starts at zero, and renders static the moment
/// either isn't true.

extern const uint32_t KKSpectrogramFormatVersion;

/// An open, memory-mapped spectrogram. Opaque: the mapping and header live
/// inside.
typedef struct KKSpectrogram *KKSpectrogramRef;

/// Opens (memory-maps) a `.kksg` file. Returns NULL if the path is unreadable,
/// the magic is wrong, the version is newer than this build understands, or the
/// file is truncated. NOT for the render path - open once, keep the ref.
KKSpectrogramRef _Nullable KKSpectrogramOpen(NSURL *url);

void KKSpectrogramClose(KKSpectrogramRef _Nullable spectrogram);

uint32_t KKSpectrogramNumFrames(KKSpectrogramRef spectrogram);
uint32_t KKSpectrogramNumBands(KKSpectrogramRef spectrogram);
double KKSpectrogramHopSeconds(KKSpectrogramRef spectrogram);
double KKSpectrogramTimelineStart(KKSpectrogramRef spectrogram);
/// Seconds of timeline covered.
double KKSpectrogramDuration(KKSpectrogramRef spectrogram);

/// Samples the spectrum at a timeline time into `outBands`.
///
/// Render-path safe: no allocation, no locking, no Objective-C messaging - it
/// reads straight from the mapping. Interpolates between the two neighbouring
/// frames, so a 60fps hop doesn't stair-step at other frame rates.
///
/// Writes `min(maxBands, numBands)` values in 0...1, low frequency first. Times
/// outside the spectrogram fill with zeroes and return NO, so a plugin can tell
/// silence from "no audio published here".
BOOL KKSpectrogramSampleAtTime(KKSpectrogramRef spectrogram,
                               double timelineSeconds, float *outBands,
                               size_t maxBands);

/// Writes the format. `data` is row-major [frame][band], values 0...1.
/// Returns NO and sets `error` on a bad write.
BOOL KKSpectrogramWrite(NSURL *url, const float *data, uint32_t numFrames,
                        uint32_t numBands, double hopSeconds,
                        double timelineStart, NSError **error);

/// The shared app-group directory Sonar publishes into, or nil without the
/// `group.co.overpolish.keyframeless` entitlement. A workflow extension's own
/// container is private to it, so this directory is the only place the writer
/// and a plugin's sandbox can both reach.
NSURL *_Nullable KKSpectrogramSourcesDirectory(void);

/// The published sources, newest first, straight from the manifest: each entry
/// has `id`, `name`, `roles`, `clipCount`, `duration`, `projectName`,
/// `publishedAt`, `contentHash`. Reading the manifest means a plugin can offer
/// a menu without opening and parsing every float grid.
NSArray<NSDictionary<NSString *, id> *> *KKSpectrogramPublishedSources(void);

/// Resolves a source `id` (from the manifest) to its file.
NSURL *_Nullable KKSpectrogramURLForSourceID(NSString *sourceID);

NS_ASSUME_NONNULL_END
