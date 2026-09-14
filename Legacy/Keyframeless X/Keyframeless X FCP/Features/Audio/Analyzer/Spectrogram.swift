/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Timeline-indexed spectrogram: `data` is row-major `[frame][band]` in 0...1,
/// frame `f` corresponds to timeline second `timelineStart + f*hopSeconds`.
struct Spectrogram: Sendable {
	/// Identifies this particular analysis, so views can tell a new spectrogram
	/// from the old one without diffing the whole float grid.
	let id = UUID()
	let numFrames: Int
	let numBands: Int
	let hopSeconds: Double
	let timelineStart: Double
	var data: [Float]
	/// The dB window `data` is normalized against (0 = floor, 1 = ceiling).
	///
	/// Carried with the grid, not looked up from `Config`, because it's the only
	/// thing anchoring a band value to a real loudness - a plugin wanting a dB
	/// threshold needs the window that produced these numbers, not whatever the
	/// analyzer's defaults happen to be today.
	var floorDB: Double = -85
	var ceilingDB: Double = -15
	/// Continuous processed mono audio for time-domain consumers. Kept at a
	/// compact analysis rate; this is for scopes and waveform displays, not
	/// playback.
	var waveformSampleRate: Double = 0
	var waveform: [Float] = []

	/// Seconds of timeline this spectrogram covers.
	var duration: Double { Double(numFrames) * hopSeconds }

	func value(frame: Int, band: Int) -> Float {
		data[frame * numBands + band]
	}

	/// Serialises for visual plugins. Frame `f` is timeline second
	/// `timelineStart + f*hopSeconds`, which is the key a plugin looks up with its
	/// own render time.
	///
	/// The format lives in `KKSpectrogramWrite` (KeyframelessKit), NOT here: the
	/// plugins' reader is defined against the same header, and a second copy of
	/// the byte layout in Swift would drift the moment either side changed.
	///
	/// `timecodeStart` shifts the published origin into FCP's clock: the grid is
	/// project-relative in-app, but a plugin looks rows up by
	/// `timelineTime:fromInputTime:`, which counts from the project's start
	/// timecode (7206.05 for 6.05s into a project starting at 02:00:00:00).
	///
	/// `SonarSourceStore` owns where this lands - the shared app-group container,
	/// the only directory both the extension and a plugin's sandbox can reach.
	func write(to url: URL, timecodeStart: Double) throws {
		try data.withUnsafeBufferPointer { spectrumBuffer in
			guard let spectrum = spectrumBuffer.baseAddress
			else { throw SonarSourceError.emptySpectrogram }
			try waveform.withUnsafeBufferPointer { waveformBuffer in
				var error: NSError?
				let ok = KKSpectrogramWriteWithWaveform(
					url, spectrum, UInt32(numFrames), UInt32(numBands), hopSeconds,
					timelineStart + timecodeStart, floorDB, ceilingDB,
					waveformBuffer.baseAddress, UInt64(waveform.count),
					waveformSampleRate, &error)
				if !ok {
					throw error ?? SonarSourceError.emptySpectrogram
				}
			}
		}
	}
}
