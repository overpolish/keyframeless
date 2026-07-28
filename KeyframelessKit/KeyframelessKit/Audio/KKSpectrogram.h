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
///   float64  floorDB     (v2+) the dB mapped to 0.0
///   float64  ceilingDB   (v2+) the dB mapped to 1.0
///   float32  data[numFrames * numBands]   row-major [frame][band], 0...1
///
/// v1 files have no dB window and read back as the -85/-15 they were written
/// with. The window is IN the file because band values are normalised against
/// it: without it, 0.5 is un-anchored to any real loudness, so a consumer
/// wanting a dB threshold would have to hard-code Sonar's constants and would
/// silently re-scale the day they were tuned.
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

/// The dB window the band values are normalised against: `floorDB` reads 0.0,
/// `ceilingDB` reads 1.0. Use them to turn a real loudness into a band value -
/// `KKSpectrogramNormalizedForDB` does exactly that.
double KKSpectrogramFloorDB(KKSpectrogramRef spectrogram);
double KKSpectrogramCeilingDB(KKSpectrogramRef spectrogram);

/// `db` as a 0...1 band value for this spectrogram's window, clamped. Below the
/// floor gives 0, above the ceiling gives 1.
double KKSpectrogramNormalizedForDB(KKSpectrogramRef spectrogram, double db);

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

/// Cumulative "flow": the running total of gated band energy from the start of
/// the analysis up to `timelineSeconds`. It only ever increases, so an effect
/// can advance geometry by it and a beat pushes that geometry FORWARD without
/// ever pulling it back - the accumulator a stateless render can't keep itself.
/// Read straight from the file, so it answers identically however a frame is
/// reached (scrub, motion-blur sub-frame, out-of-order pre-render), where a
/// remembered running sum would not survive an export.
///
/// `loBand`/`hiBand` select the analysis-band range (`hiBand` EXCLUSIVE; pass
/// `0` / `numBands` for the full mix). Each frame contributes
/// `max(0, peak(bands[lo..hi]) - gate01) * hopSeconds`, so the value is in
/// band-seconds and frame-rate independent, and a quiet noise floor under
/// `gate01` adds nothing (which is what keeps the flow still between beats).
/// `gate01` is a 0...1 level - convert a dB threshold with
/// `KKSpectrogramNormalizedForDB`; pass `0` for no gate.
///
/// Render-path safe: no allocation, no locking, reads the mapping directly. It
/// scans every frame up to `timelineSeconds`, so it is O(frames-so-far) - fine
/// for the clip lengths audio shaders run on; revisit with a prefix sum if that
/// ever bites. Returns `0` before the analysis starts.
double KKSpectrogramFlowAtTime(KKSpectrogramRef spectrogram,
                               double timelineSeconds, uint32_t loBand,
                               uint32_t hiBand, double gate01);

/// Writes the format. `data` is row-major [frame][band], values 0...1.
/// `floorDB` / `ceilingDB` are the window `data` was normalised against.
/// Returns NO and sets `error` on a bad write.
BOOL KKSpectrogramWrite(NSURL *url, const float *data, uint32_t numFrames,
                        uint32_t numBands, double hopSeconds,
                        double timelineStart, double floorDB, double ceilingDB,
                        NSError **error);

/// The shared app-group directory Sonar publishes into, or nil without the
/// `group.com.keyframeless` entitlement. A workflow extension's own
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
