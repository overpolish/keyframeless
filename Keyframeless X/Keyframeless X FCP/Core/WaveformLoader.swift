/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Accelerate
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
		let buckets = max(200, Int(clip.sourceDuration * 200))
		let raw = try await load(clip: clip, buckets: buckets)
		let samples = smoothed(raw)
		cache[key] = samples
		return samples
	}

	private func load(clip: FCPXMLParser.AudioClip, buckets: Int) async throws -> [Float] {
		// Try direct file access first (avoids reading entire file into Data + temp file)
		if let samples = try? loadDirect(clip: clip, buckets: buckets) {
			return samples
		}

		// Fallback: data → temp file
		let data = try clip.data()
		let ext = clip.url?.pathExtension ?? ""
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
		try data.write(to: tmpURL)
		defer { try? FileManager.default.removeItem(at: tmpURL) }

		if let samples = try? loadFromAudioFile(url: tmpURL, clip: clip, buckets: buckets) {
			return samples
		}

		return try await loadViaAssetReader(url: tmpURL, clip: clip, buckets: buckets)
	}

	private func loadDirect(
		clip: FCPXMLParser.AudioClip, buckets: Int
	) throws -> [Float] {
		if let bookmark = clip.bookmark {
			var isStale = false
			let scopedURL = try URL(
				resolvingBookmarkData: bookmark,
				options: .withSecurityScope,
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			)
			let accessing = scopedURL.startAccessingSecurityScopedResource()
			defer { if accessing { scopedURL.stopAccessingSecurityScopedResource() } }
			return try loadFromAudioFile(url: scopedURL, clip: clip, buckets: buckets)
		}
		guard let url = clip.url else { throw CocoaError(.fileNoSuchFile) }
		return try loadFromAudioFile(url: url, clip: clip, buckets: buckets)
	}

	private func loadFromAudioFile(
		url: URL, clip: FCPXMLParser.AudioClip, buckets: Int
	) throws -> [Float] {
		let audioFile = try AVAudioFile(forReading: url)
		let sampleRate = audioFile.processingFormat.sampleRate
		let startFrame = AVAudioFramePosition(clip.sourceStart * sampleRate)
		let totalFrames = AVAudioFrameCount(max(1, clip.sourceDuration * sampleRate))
		audioFile.framePosition = max(0, min(startFrame, audioFile.length - 1))

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

	private func loadViaAssetReader(
		url: URL, clip: FCPXMLParser.AudioClip, buckets: Int
	) async throws -> [Float] {
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderTrackOutput(
			track: track,
			outputSettings: [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVLinearPCMBitDepthKey: 32,
				AVLinearPCMIsFloatKey: true,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsNonInterleaved: false,
				AVNumberOfChannelsKey: 1,
				AVSampleRateKey: 48000,
			])
		reader.add(output)
		reader.timeRange = CMTimeRange(
			start: CMTime(seconds: clip.sourceStart, preferredTimescale: 48000),
			duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 48000)
		)
		reader.startReading()

		// Stream-downsample: compute bucket peaks as we read, no giant array needed
		var result = [Float](repeating: 0, count: buckets)
		var samplesProcessed = 0
		// Estimate total samples for bucket sizing (refine as we read)
		let estimatedTotal = max(1, Int(clip.sourceDuration * 48000))
		let bucketSize = max(1, estimatedTotal / buckets)

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
			ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
				let chunkStart = samplesProcessed
				let chunkEnd = samplesProcessed + floatCount
				let firstBucket = min(chunkStart / bucketSize, buckets - 1)
				let lastBucket = min((chunkEnd - 1) / bucketSize, buckets - 1)

				guard firstBucket <= lastBucket else {
					samplesProcessed += floatCount
					return
				}
				for b in firstBucket...lastBucket {
					let bStart = max(b * bucketSize, chunkStart) - chunkStart
					let bEnd = min((b + 1) * bucketSize, chunkEnd) - chunkStart
					let len = bEnd - bStart
					guard len > 0 else { continue }

					var maxMag: Float = 0
					vDSP_maxmgv(floatPtr + bStart, 1, &maxMag, vDSP_Length(len))
					result[b] = max(result[b], maxMag)
				}
				samplesProcessed += floatCount
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
