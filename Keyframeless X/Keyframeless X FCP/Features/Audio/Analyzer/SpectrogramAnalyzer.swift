/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Accelerate
import Foundation

/// Turns a set of timeline `AudioClip`s into a timeline-indexed spectrogram:
/// for each clip we reconstruct the *processed* audio (effects + volume +
/// fades, via `ProcessedAudioRenderer`), run an STFT, and place the resulting
/// band-over-time frames at the clip's timeline position (`clip.start`).
/// Overlapping clips are averaged.
///
/// The analyzer is deliberately decoupled from how the clips were obtained
/// (dialogue-only vs all-audio parse) and from any consumer (Shader et al) —
/// it just produces a `Spectrogram`. Phase 1 also dumps a PNG so the result
/// can be eyeballed against the audio before wiring the shared cache/reader.
enum SpectrogramAnalyzer {

	struct Config {
		var fftSize: Int = 2048
		var hopSeconds: Double = 1.0 / 60.0
		var numBands: Int = 128
		var minHz: Double = 30
		var maxHz: Double = 16_000
		/// Everything is downmixed to mono and resampled to this rate first.
		var analysisSampleRate: Double = 48_000
		/// dB window mapped onto 0...1, with 0 dB being a full-scale sine.
		/// At/below `floorDB` reads black, at/above `ceilingDB` reads full
		/// brightness. Music rarely peaks near 0 dB in any single band once the
		/// energy is spread across the spectrum, hence the negative ceiling -
		/// widen the window if the picture looks flat, tighten it if it blooms.
		var floorDB: Float = -85
		var ceilingDB: Float = -15
	}

	/// A finished analysis, plus the clips that couldn't be read.
	///
	/// Unreadable clips are reported rather than thrown, because media going
	/// missing is an ordinary state for an FCP project - a file moved after the
	/// edit, a drive unplugged - and it shouldn't cost you the other 34 clips'
	/// worth of spectrogram.
	struct Analysis {
		let spectrogram: Spectrogram
		let skipped: [String]
	}

	enum AnalysisError: LocalizedError {
		case allClipsUnreadable([String])

		var errorDescription: String? {
			switch self {
			case .allClipsUnreadable(let names):
				let list = names.prefix(3).joined(separator: ", ")
				let more = names.count > 3 ? " +\(names.count - 3) more" : ""
				return String(
					localized:
						"Couldn't read any selected audio - the media may have moved (\(list)\(more))"
				)
			}
		}
	}

	/// PROJECT-relative, like `clip.start` and like Sonar's own timeline: frame 0
	/// is the project's first frame. The project's start timecode is added at
	/// PUBLISH time (`SonarSourceStore`), because that's where the data crosses
	/// into FCP's clock - keying the in-app model to 7200 would draw the preview
	/// two hours off the right of the canvas.
	static func analyze(
		clips: [FCPXMLParser.AudioClip], config: Config = Config()
	) async throws -> Analysis {
		let timelineStart = 0.0
		let timelineEnd = clips.map(\.end).max() ?? 0
		let hop = config.hopSeconds
		let numFrames = max(1, Int(ceil((timelineEnd - timelineStart) / hop)))
		let numBands = config.numBands

		var grid = [Float](repeating: 0, count: numFrames * numBands)
		var counts = [Float](repeating: 0, count: numFrames)

		let sr = config.analysisSampleRate
		let bandEdges = logBandEdges(config: config, sampleRate: sr)

		var skipped: [String] = []
		// Decode first, assemble after. Holding an unsafe pointer into `grid`
		// across an `await` isn't allowed, so the placement pass runs on its own
		// once every clip's frames are in hand.
		var decoded: [(startFrame: Int, frames: [[Float]])] = []
		for clip in clips {
			// Lets a superseded run stop mid-analysis instead of finishing work
			// whose result is already stale.
			try Task.checkCancellation()
			// Per-clip failures are contained here. A clip whose media has moved
			// throws out of `renderedURL`; letting that escape the loop would sink
			// the whole analysis for one dead path.
			let clipFrames: [[Float]]?
			do {
				clipFrames = try await frames(for: clip, config: config, bandEdges: bandEdges)
			} catch {
				skipped.append(clip.name)
				continue
			}
			guard let clipFrames else {
				skipped.append(clip.name)
				continue
			}
			decoded.append(
				(Int(((clip.start - timelineStart) / hop).rounded()), clipFrames))
		}

		grid.withUnsafeMutableBufferPointer { g in
			counts.withUnsafeMutableBufferPointer { c in
				guard let gBase = g.baseAddress else { return }
				let n = vDSP_Length(numBands)
				for (startFrame, frames) in decoded {
					for (i, bands) in frames.enumerated() {
						let f = startFrame + i
						guard f >= 0, f < numFrames else { continue }
						let base = f * numBands
						bands.withUnsafeBufferPointer { b in
							guard let bBase = b.baseAddress else { return }
							vDSP_vadd(gBase + base, 1, bBase, 1, gBase + base, 1, n)
						}
						c[f] += 1
					}
				}
			}
		}
		// Every clip failing is a real failure, not a partial one - publishing an
		// empty grid would look like silent audio rather than a broken project.
		if skipped.count == clips.count, !clips.isEmpty {
			throw AnalysisError.allClipsUnreadable(skipped)
		}

		// Average frames that several clips wrote into.
		for f in 0..<numFrames where counts[f] > 1 {
			let inv = 1.0 / counts[f]
			let base = f * numBands
			for b in 0..<numBands { grid[base + b] *= inv }
		}

		return Analysis(
			spectrogram: Spectrogram(
				numFrames: numFrames, numBands: numBands, hopSeconds: hop,
				timelineStart: timelineStart, data: grid),
			skipped: skipped)
	}

	/// Per-clip STFT frames, cached. Reconstructing a clip's processed audio is
	/// the expensive half (`ProcessedAudioRenderer` caches that too); caching the
	/// FFT output as well means re-assembling the timeline for a *different
	/// selection* is just array copying - cheap enough to regenerate the preview
	/// live rather than making the user press a button again.
	private static func frames(
		for clip: FCPXMLParser.AudioClip, config: Config, bandEdges: [Int]
	) async throws -> [[Float]]? {
		let key = [
			AudioClipFingerprint.of(clip), "\(config.fftSize)", "\(config.hopSeconds)",
			"\(config.numBands)", "\(config.analysisSampleRate)",
		].joined(separator: "|")
		if let cached = await SpectrogramFrameCache.shared.frames(key) { return cached }

		let url = try await ProcessedAudioRenderer.shared.renderedURL(for: clip)
		guard
			let mono = try readMono(url: url, targetSampleRate: config.analysisSampleRate),
			!mono.isEmpty
		else { return nil }
		let computed = stft(
			samples: mono, config: config, bandEdges: bandEdges,
			sampleRate: config.analysisSampleRate)
		await SpectrogramFrameCache.shared.store(computed, for: key)
		return computed
	}

	private static func readMono(url: URL, targetSampleRate: Double) throws -> [Float]? {
		let file = try AVAudioFile(forReading: url)
		let srcFormat = file.processingFormat
		guard file.length > 0,
			let dstFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
				channels: 1, interleaved: false),
			let srcBuffer = AVAudioPCMBuffer(
				pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length))
		else { return nil }
		try file.read(into: srcBuffer)

		guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
			return nil
		}
		let ratio = targetSampleRate / srcFormat.sampleRate
		let dstCapacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
		guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity)
		else { return nil }

		var supplied = false
		var convError: NSError?
		converter.convert(to: dstBuffer, error: &convError) { _, outStatus in
			if supplied {
				outStatus.pointee = .noDataNow
				return nil
			}
			supplied = true
			outStatus.pointee = .haveData
			return srcBuffer
		}
		if let convError { throw convError }

		let n = Int(dstBuffer.frameLength)
		guard n > 0, let ptr = dstBuffer.floatChannelData?[0] else { return nil }
		return Array(UnsafeBufferPointer(start: ptr, count: n))
	}

	/// Bin-index edges (length numBands+1) for log-spaced frequency bands.
	private static func logBandEdges(config: Config, sampleRate: Double) -> [Int] {
		let half = config.fftSize / 2
		let lo = log10(max(1, config.minHz))
		let hi = log10(min(config.maxHz, sampleRate / 2))
		return (0...config.numBands).map { i in
			let frac = Double(i) / Double(config.numBands)
			let hz = pow(10, lo + (hi - lo) * frac)
			let bin = Int((hz / (sampleRate / 2)) * Double(half))
			return min(max(bin, 0), half)
		}
	}

	private static func stft(
		samples: [Float], config: Config, bandEdges: [Int], sampleRate: Double
	) -> [[Float]] {
		let n = config.fftSize
		let half = n / 2
		let log2n = vDSP_Length(log2(Double(n)))
		guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
		defer { vDSP_destroy_fftsetup(setup) }

		var window = [Float](repeating: 0, count: n)
		vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
		let hopSamples = max(1, Int(config.hopSeconds * sampleRate))

		// `vDSP_fft_zrip` is unnormalised and returns twice the DFT, so a raw bin
		// is ~N times too hot (that's what turned the picture into one bright
		// blob). Undo that, and the Hann window's 0.5 coherent gain with it, so a
		// full-scale sine lands at ~1.0 == 0 dB.
		let magScale = Float(2) / Float(n)
		let span = max(0.0001, config.ceilingDB - config.floorDB)

		var frames: [[Float]] = []
		var windowed = [Float](repeating: 0, count: n)
		var pos = 0
		while pos + n <= samples.count {
			samples.withUnsafeBufferPointer { sp in
				vDSP_vmul(sp.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(n))
			}
			let mag = fftMagnitudes(windowed: windowed, setup: setup, log2n: log2n, half: half)

			var bands = [Float](repeating: 0, count: config.numBands)
			for b in 0..<config.numBands {
				let lo = min(max(bandEdges[b], 0), half - 1)
				let hi = max(lo + 1, min(bandEdges[b + 1], half))
				// Peak, not mean: log-spaced bands get wide up top, and averaging
				// buries a pure tone among its quiet neighbours.
				var peak: Float = 0
				for k in lo..<hi { peak = max(peak, mag[k]) }
				let db = 20 * log10f(max(peak * magScale, 1e-9))
				bands[b] = max(0, min(1, (db - config.floorDB) / span))
			}
			frames.append(bands)
			pos += hopSamples
		}
		return frames
	}

	private static func fftMagnitudes(
		windowed: [Float], setup: FFTSetup, log2n: vDSP_Length, half: Int
	) -> [Float] {
		var real = [Float](repeating: 0, count: half)
		var imag = [Float](repeating: 0, count: half)
		var mag = [Float](repeating: 0, count: half)
		real.withUnsafeMutableBufferPointer { rp in
			imag.withUnsafeMutableBufferPointer { ip in
				var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
				windowed.withUnsafeBufferPointer { wp in
					wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
						vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
					}
				}
				vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
				vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
			}
		}
		return mag
	}
}

/// Caches per-clip STFT frames, keyed by the clip's fingerprint + analysis
/// settings, so changing the selection re-assembles instead of re-decoding.
actor SpectrogramFrameCache {
	static let shared = SpectrogramFrameCache()
	private var cache: [String: [[Float]]] = [:]

	func frames(_ key: String) -> [[Float]]? { cache[key] }
	func store(_ frames: [[Float]], for key: String) { cache[key] = frames }
}
