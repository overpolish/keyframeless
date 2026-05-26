/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Accelerate
import Foundation

actor WaveformLoader {
	static let shared = WaveformLoader()

	private var cache: [String: [Float]] = [:]

	func waveform(for clip: FCPXMLParser.AudioClip) async throws -> [Float] {
		let key = AudioClipFingerprint.of(clip)
		if let cached = cache[key] { return cached }
		let buckets = max(200, Int(clip.sourceDuration * 200))
		let renderedURL = try await ProcessedAudioRenderer.shared.renderedURL(for: clip)
		let raw = try loadFromAudioFile(
			url: renderedURL, durationSeconds: clip.sourceDuration, buckets: buckets)
		let samples = smoothed(raw)
		cache[key] = samples
		return samples
	}

	private func loadFromAudioFile(
		url: URL, durationSeconds: Double, buckets: Int
	) throws -> [Float] {
		let audioFile = try AVAudioFile(forReading: url)
		let sampleRate = audioFile.processingFormat.sampleRate
		audioFile.framePosition = 0
		let requested = AVAudioFrameCount(max(1, durationSeconds * sampleRate))
		let totalFrames = min(requested, AVAudioFrameCount(audioFile.length))

		let chunkSize: AVAudioFrameCount = 65536
		var result = [Float](repeating: 0, count: buckets)
		let bucketSize = max(1, Int(totalFrames) / buckets)
		var framesRead: Int = 0

		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: chunkSize)
		else { return [] }

		while framesRead < Int(totalFrames) {
			let framesToRead = min(chunkSize, totalFrames - AVAudioFrameCount(framesRead))
			try audioFile.read(into: buffer, frameCount: framesToRead)
			guard let channelData = buffer.floatChannelData?[0] else { break }
			let count = Int(buffer.frameLength)
			guard count > 0 else { break }

			// Compute bucket peaks for this chunk using vDSP
			let chunkStart = framesRead
			let chunkEnd = framesRead + count
			let firstBucket = min(chunkStart / bucketSize, buckets - 1)
			let lastBucket = min((chunkEnd - 1) / bucketSize, buckets - 1)

			guard firstBucket <= lastBucket else {
				framesRead += count
				continue
			}
			for b in firstBucket...lastBucket {
				let bStart = max(b * bucketSize, chunkStart) - chunkStart
				let bEnd = min((b + 1) * bucketSize, chunkEnd) - chunkStart
				let length = bEnd - bStart
				guard length > 0 else { continue }

				var maxMag: Float = 0
				vDSP_maxmgv(channelData + bStart, 1, &maxMag, vDSP_Length(length))
				result[b] = max(result[b], maxMag)
			}

			framesRead += count
		}

		return result
	}

	private func smoothed(_ input: [Float]) -> [Float] {
		guard input.count > 2 else { return input }
		let radius = 5
		var output = [Float](repeating: 0, count: input.count)
		for i in 0..<input.count {
			let lo = max(0, i - radius)
			let hi = min(input.count - 1, i + radius)
			var sum: Float = 0
			for j in lo...hi { sum += input[j] }
			output[i] = sum / Float(hi - lo + 1)
		}
		return output
	}
}
