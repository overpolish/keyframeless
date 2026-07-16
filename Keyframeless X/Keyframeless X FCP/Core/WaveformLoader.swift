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

	func waveform(
		for clip: FCPXMLParser.AudioClip,
		onProgress: (@Sendable ([Float]) -> Void)? = nil
	) async throws -> [Float] {
		let key = AudioClipFingerprint.of(clip)
		if let cached = cache[key] {
			onProgress?(cached)
			return cached
		}
		let buckets = max(200, Int(clip.sourceDuration * 200))
		let renderedURL = try await ProcessedAudioRenderer.shared.renderedURL(for: clip)
		let raw = try loadFromAudioFile(
			url: renderedURL, durationSeconds: clip.sourceDuration, buckets: buckets,
			onProgress: onProgress)
		let samples = smoothed(raw)
		cache[key] = samples
		onProgress?(samples)
		return samples
	}

	private func loadFromAudioFile(
		url: URL, durationSeconds: Double, buckets: Int,
		onProgress: (@Sendable ([Float]) -> Void)? = nil
	) throws -> [Float] {
		let audioFile = try AVAudioFile(forReading: url)
		let sampleRate = audioFile.processingFormat.sampleRate
		audioFile.framePosition = 0
		let requested = AVAudioFrameCount(max(1, durationSeconds * sampleRate))
		let totalFrames = min(requested, AVAudioFrameCount(audioFile.length))

		let chunkSize: AVAudioFrameCount = 65536
		var result = [Float](repeating: 0, count: buckets)
		// Fractional, NOT `totalFrames / buckets`. Integer division floored the true
		// ratio (e.g. 239.985 -> 239), and since a bucket index is frame/ratio, a
		// too-small ratio pushes every event to a higher index - the waveform
		// stretches right, drifting further the longer the clip. On a 10-minute clip
		// that 0.4% error is 2.6 seconds.
		//
		// The ratio is fractional because `totalFrames` is the rendered file's real
		// length, which AAC priming leaves a few ms short of the clip's duration -
		// enough to drag the ratio just under the integer boundary.
		let framesPerBucket = max(1.0, Double(totalFrames) / Double(buckets))
		var framesRead: Int = 0

		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: chunkSize)
		else { return [] }

		var chunksSinceProgress = 0
		let progressEveryNChunks = 4

		while framesRead < Int(totalFrames) {
			let framesToRead = min(chunkSize, totalFrames - AVAudioFrameCount(framesRead))
			try audioFile.read(into: buffer, frameCount: framesToRead)
			guard let channelData = buffer.floatChannelData?[0] else { break }
			let count = Int(buffer.frameLength)
			guard count > 0 else { break }

			// Compute bucket peaks for this chunk using vDSP
			let chunkStart = framesRead
			let chunkEnd = framesRead + count
			let firstBucket = min(Int(Double(chunkStart) / framesPerBucket), buckets - 1)
			let lastBucket = min(Int(Double(chunkEnd - 1) / framesPerBucket), buckets - 1)

			guard firstBucket <= lastBucket else {
				framesRead += count
				continue
			}
			for b in firstBucket...lastBucket {
				// A bucket straddling two chunks is filled by both - `result[b]` maxes,
				// so the halves combine rather than one overwriting the other.
				let bucketStart = Int(Double(b) * framesPerBucket)
				let bucketEnd = min(Int(Double(b + 1) * framesPerBucket), Int(totalFrames))
				let bStart = max(bucketStart, chunkStart) - chunkStart
				let bEnd = min(bucketEnd, chunkEnd) - chunkStart
				let length = bEnd - bStart
				guard length > 0 else { continue }

				var maxMag: Float = 0
				vDSP_maxmgv(channelData + bStart, 1, &maxMag, vDSP_Length(length))
				// Compressor make-up gain can push samples past 0 dBFS (|x|>1).
				// Clamp the per-bucket peak so the waveform visually saturates
				// at the lane top instead of overflowing the layout.
				result[b] = max(result[b], min(maxMag, 1.0))
			}

			framesRead += count
			chunksSinceProgress += 1
			if let onProgress, chunksSinceProgress >= progressEveryNChunks {
				onProgress(result)
				chunksSinceProgress = 0
			}
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
