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

	func waveform(for clip: FCPXMLParser.AudioClip) async throws -> [Float] {
		let key = CacheKey(
			urlString: clip.url?.absoluteString ?? "",
			sourceStart: clip.sourceStart,
			sourceDuration: clip.sourceDuration
		)
		if let cached = cache[key] { return cached }
		let buckets = min(4000, max(300, Int(clip.sourceDuration * 200)))
		let samples = try load(clip: clip, buckets: buckets)
		cache[key] = samples
		return samples
	}

	private func load(clip: FCPXMLParser.AudioClip, buckets: Int) throws -> [Float] {
		let data = try clip.data()

		let ext = clip.url?.pathExtension ?? ""
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
		try data.write(to: tmpURL)
		defer { try? FileManager.default.removeItem(at: tmpURL) }

		if let audioFile = try? AVAudioFile(forReading: tmpURL) {
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

		return try loadViaAssetReader(url: tmpURL, clip: clip, buckets: buckets)
	}

	private func loadViaAssetReader(
		url: URL, clip: FCPXMLParser.AudioClip, buckets: Int
	) throws -> [Float] {
		let asset = AVURLAsset(url: url)
		guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		])
		reader.add(output)
		reader.timeRange = CMTimeRange(
			start: CMTime(seconds: clip.sourceStart, preferredTimescale: 48000),
			duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 48000)
		)
		reader.startReading()

		var allSamples: [Float] = []
		while let sampleBuffer = output.copyNextSampleBuffer() {
			guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
			var length = 0
			var dataPointer: UnsafeMutablePointer<Int8>?
			CMBlockBufferGetDataPointer(
				blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
				totalLengthOut: &length, dataPointerOut: &dataPointer
			)
			guard let ptr = dataPointer else { continue }
			let floatCount = length / MemoryLayout<Float>.size
			ptr.withMemoryRebound(to: Float.self, capacity: floatCount) {
				allSamples.append(
					contentsOf: UnsafeBufferPointer(start: $0, count: floatCount))
			}
		}

		guard !allSamples.isEmpty else { return [] }
		let bucketSize = max(1, allSamples.count / buckets)
		return (0..<buckets).map { b in
			let start = b * bucketSize
			let end = min(start + bucketSize, allSamples.count)
			guard start < end else { return 0 as Float }
			return (start..<end).reduce(0 as Float) { max($0, abs(allSamples[$1])) }
		}
	}
}
