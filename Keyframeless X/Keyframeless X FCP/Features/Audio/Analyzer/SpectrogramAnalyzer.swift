/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Accelerate
import AppKit
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
		var numBands: Int = 64
		var minHz: Double = 30
		var maxHz: Double = 16_000
		/// Everything is downmixed to mono and resampled to this rate first.
		var analysisSampleRate: Double = 48_000
	}

	static func analyze(
		clips: [FCPXMLParser.AudioClip], config: Config = Config()
	) async throws -> Spectrogram {
		let timelineStart = 0.0
		let timelineEnd = clips.map(\.end).max() ?? 0
		let hop = config.hopSeconds
		let numFrames = max(1, Int(ceil((timelineEnd - timelineStart) / hop)))
		let numBands = config.numBands

		var grid = [Float](repeating: 0, count: numFrames * numBands)
		var counts = [Float](repeating: 0, count: numFrames)

		let sr = config.analysisSampleRate
		let bandEdges = logBandEdges(config: config, sampleRate: sr)

		for clip in clips {
			let url = try await ProcessedAudioRenderer.shared.renderedURL(for: clip)
			guard let mono = try readMono(url: url, targetSampleRate: sr), !mono.isEmpty
			else { continue }

			let clipFrames = stft(
				samples: mono, config: config, bandEdges: bandEdges, sampleRate: sr)

			let startFrame = Int(((clip.start - timelineStart) / hop).rounded())
			for (i, bands) in clipFrames.enumerated() {
				let f = startFrame + i
				guard f >= 0, f < numFrames else { continue }
				let base = f * numBands
				for b in 0..<numBands { grid[base + b] += bands[b] }
				counts[f] += 1
			}
		}

		// Average frames that several clips wrote into.
		for f in 0..<numFrames where counts[f] > 1 {
			let inv = 1.0 / counts[f]
			let base = f * numBands
			for b in 0..<numBands { grid[base + b] *= inv }
		}

		return Spectrogram(
			numFrames: numFrames, numBands: numBands, hopSeconds: hop,
			timelineStart: timelineStart, data: grid)
	}

	/// Convenience for Phase-1 verification: parse an exported .fcpxml, analyze
	/// every audio clip it contains, and write a PNG dump. Returns the
	/// `Spectrogram` so a caller can inspect it too.
	@discardableResult
	static func analyzeAndDump(
		fcpxmlURL: URL, outPNG: URL, config: Config = Config()
	) async throws -> Spectrogram {
		let doc = try XMLDocument(contentsOf: fcpxmlURL, options: [.nodePreserveWhitespace])
		let clips = FCPXMLParser.audioClips(in: doc, dialogueOnly: false)
		let spec = try await analyze(clips: clips, config: config)
		try spec.writePNG(to: outPNG)
		return spec
	}

	// MARK: - Audio read (mono, resampled)

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

	// MARK: - STFT

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
				var sum: Float = 0
				for k in lo..<hi { sum += mag[k] }
				let avg = sum / Float(hi - lo)
				let db = 20 * log10f(max(avg, 1e-9))
				bands[b] = max(0, min(1, (db + 80) / 80))  // -80..0 dB -> 0..1
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

/// Timeline-indexed spectrogram: `data` is row-major `[frame][band]` in 0...1,
/// frame `f` corresponds to timeline second `timelineStart + f*hopSeconds`.
struct Spectrogram {
	let numFrames: Int
	let numBands: Int
	let hopSeconds: Double
	let timelineStart: Double
	var data: [Float]

	func value(frame: Int, band: Int) -> Float {
		data[frame * numBands + band]
	}

	/// Writes a grayscale PNG (x = time, y = frequency band, low freq at the
	/// bottom) so the result can be checked by eye.
	func writePNG(to url: URL) throws {
		let w = max(1, numFrames)
		let h = max(1, numBands)
		guard
			let rep = NSBitmapImageRep(
				bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
				bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
				colorSpaceName: .deviceWhite, bytesPerRow: w, bitsPerPixel: 8),
			let pixels = rep.bitmapData
		else { throw CocoaError(.fileWriteUnknown) }

		for f in 0..<numFrames {
			for b in 0..<numBands {
				let y = numBands - 1 - b  // low frequencies at the bottom
				pixels[y * w + f] = UInt8(max(0, min(255, value(frame: f, band: b) * 255)))
			}
		}

		guard let png = rep.representation(using: .png, properties: [:]) else {
			throw CocoaError(.fileWriteUnknown)
		}
		try png.write(to: url)
	}
}
