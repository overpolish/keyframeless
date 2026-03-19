/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Foundation

actor WaveformLoader {
	static let shared = WaveformLoader()

	private struct CacheKey: Hashable {
		let urlString: String
		let sourceStart: Double
		let sourceDuration: Double
	}

	private var cache: [CacheKey: [Float]] = [:]

	func waveform(for clip: FCPXMLParser.AudioClip, buckets: Int = 300) async throws -> [Float] {
		let key = CacheKey(
			urlString: clip.url?.absoluteString ?? "",
			sourceStart: clip.sourceStart,
			sourceDuration: clip.sourceDuration
		)
		if let cached = cache[key] { return cached }
		let samples = try load(clip: clip, buckets: buckets)
		cache[key] = samples
		return samples
	}

	private func load(clip: FCPXMLParser.AudioClip, buckets: Int) throws -> [Float] {
		let data = try clip.data()

		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try data.write(to: tmpURL)
		defer { try? FileManager.default.removeItem(at: tmpURL) }

		let audioFile = try AVAudioFile(forReading: tmpURL)
		let sampleRate = audioFile.processingFormat.sampleRate

		let startFrame = AVAudioFramePosition(clip.sourceStart * sampleRate)
		let frameCount = AVAudioFrameCount(max(1, clip.sourceDuration * sampleRate))
		audioFile.framePosition = max(0, min(startFrame, audioFile.length - 1))

		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)
		else { return [] }
		try audioFile.read(into: buffer, frameCount: frameCount)

		guard let channelData = buffer.floatChannelData?[0] else { return [] }
		let total = Int(buffer.frameLength)
		guard total > 0 else { return [] }

		let bucketSize = max(1, total / buckets)
		return (0..<buckets).map { b in
			let start = b * bucketSize
			let end = min(start + bucketSize, total)
			return (start..<end).reduce(0 as Float) { max($0, abs(channelData[$1])) }
		}
	}
}
