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
		try data.withUnsafeBufferPointer { buf in
			guard let base = buf.baseAddress else { throw SonarSourceError.emptySpectrogram }
			var error: NSError?
			let ok = KKSpectrogramWrite(
				url, base, UInt32(numFrames), UInt32(numBands), hopSeconds,
				timelineStart + timecodeStart, &error)
			if !ok {
				throw error ?? SonarSourceError.emptySpectrogram
			}
		}
	}
}
