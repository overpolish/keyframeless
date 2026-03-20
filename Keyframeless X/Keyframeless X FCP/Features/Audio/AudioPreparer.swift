/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Foundation

struct AudioPreparer {

	struct SourceRange: Equatable {
		let start: Double
		let end: Double
		var duration: Double { end - start }
	}

	struct PreparedSegment {
		let tempFileURL: URL
		let sourceName: String
		let range: SourceRange
		let clipMappings: [ClipMapping]
	}

	struct ProcessingSegment {
		let sourceURL: URL?
		let bookmark: Data?
		let sourceName: String
		let range: SourceRange
		let clipMappings: [ClipMapping]
	}

	struct ClipMapping {
		let clipIndex: Int
		let offsetInSegment: Double
		let clipSourceStart: Double
		let clipSourceDuration: Double
	}

	static let mergeThreshold: Double = 5.0

	static func prepare(
		clips: [FCPXMLParser.AudioClip],
		selectedIndices: Set<Int>
	) -> [ProcessingSegment] {
		let selected = selectedIndices.sorted().compactMap {
			idx -> (Int, FCPXMLParser.AudioClip)? in
			guard clips.indices.contains(idx) else { return nil }
			return (idx, clips[idx])
		}

		let grouped = Dictionary(grouping: selected) { _, clip in
			clip.url?.absoluteString ?? clip.name
		}

		var segments: [ProcessingSegment] = []

		for (_, group) in grouped {
			let ranges: [(Int, SourceRange)] = group.map { idx, clip in
				(
					idx,
					SourceRange(
						start: clip.sourceStart, end: clip.sourceStart + clip.sourceDuration)
				)
			}

			let merged = mergeRanges(ranges, threshold: mergeThreshold)

			let representative = group.first!.1
			for (mergedRange, clipIndices) in merged {
				let mappings = clipIndices.map { idx -> ClipMapping in
					let clip = clips[idx]
					return ClipMapping(
						clipIndex: idx,
						offsetInSegment: clip.sourceStart - mergedRange.start,
						clipSourceStart: clip.sourceStart,
						clipSourceDuration: clip.sourceDuration
					)
				}
				segments.append(
					ProcessingSegment(
						sourceURL: representative.url,
						bookmark: representative.bookmark,
						sourceName: representative.name,
						range: mergedRange,
						clipMappings: mappings
					)
				)
			}
		}

		return segments
	}

	static func extractAudio(for segments: [ProcessingSegment]) throws -> [PreparedSegment] {
		var sourceFileCache: [String: URL] = [:]
		var prepared: [PreparedSegment] = []

		for segment in segments {
			let cacheKey = segment.sourceURL?.absoluteString ?? segment.sourceName

			let sourceFileURL: URL
			if let cached = sourceFileCache[cacheKey] {
				sourceFileURL = cached
			} else {
				let clip = FCPXMLParser.AudioClip(
					name: segment.sourceName,
					start: 0, end: 0,
					sourceStart: 0, sourceDuration: 0,
					url: segment.sourceURL,
					bookmark: segment.bookmark,
					isCompound: false
				)
				let data = try clip.data()
				let tmpURL = FileManager.default.temporaryDirectory
					.appendingPathComponent("kk_audio_\(UUID().uuidString)")
				try data.write(to: tmpURL)
				sourceFileCache[cacheKey] = tmpURL
				sourceFileURL = tmpURL
			}

			let audioFile = try AVAudioFile(
				forReading: sourceFileURL,
				commonFormat: .pcmFormatFloat32,
				interleaved: false
			)
			let sampleRate = audioFile.fileFormat.sampleRate
			let startFrame = AVAudioFramePosition(segment.range.start * sampleRate)
			let endFrame = min(
				AVAudioFramePosition(segment.range.end * sampleRate),
				audioFile.length
			)
			let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))

			audioFile.framePosition = max(0, startFrame)

			guard
				let buffer = AVAudioPCMBuffer(
					pcmFormat: audioFile.processingFormat,
					frameCapacity: frameCount
				)
			else {
				print(
					"[AudioPreparer] skipping segment \(segment.sourceName) — buffer alloc failed (frameCount: \(frameCount))"
				)
				continue
			}
			try audioFile.read(into: buffer, frameCount: frameCount)

			let whisperBuffer = try resampleToWhisperFormat(buffer: buffer)

			let outURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("kk_segment_\(UUID().uuidString).wav")
			let outFile = try AVAudioFile(
				forWriting: outURL,
				settings: whisperBuffer.format.settings
			)
			try outFile.write(from: whisperBuffer)

			prepared.append(
				PreparedSegment(
					tempFileURL: outURL,
					sourceName: segment.sourceName,
					range: segment.range,
					clipMappings: segment.clipMappings
				)
			)
		}

		for url in sourceFileCache.values {
			try? FileManager.default.removeItem(at: url)
		}

		return prepared
	}

	static func cleanUp(segments: [PreparedSegment]) {
		for segment in segments {
			try? FileManager.default.removeItem(at: segment.tempFileURL)
		}
	}

	private static let whisperSampleRate: Double = 16000

	private static func resampleToWhisperFormat(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer
	{
		guard
			let monoFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32,
				sampleRate: whisperSampleRate,
				channels: 1,
				interleaved: false
			)
		else { throw NSError(domain: "AudioPreparer", code: 1) }

		if buffer.format.sampleRate == whisperSampleRate && buffer.format.channelCount == 1 {
			return buffer
		}

		guard let converter = AVAudioConverter(from: buffer.format, to: monoFormat) else {
			throw NSError(domain: "AudioPreparer", code: 2)
		}

		let ratio = whisperSampleRate / buffer.format.sampleRate
		let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
		guard
			let outputBuffer = AVAudioPCMBuffer(
				pcmFormat: monoFormat,
				frameCapacity: outputFrameCount
			)
		else { throw NSError(domain: "AudioPreparer", code: 3) }

		var error: NSError?
		converter.convert(to: outputBuffer, error: &error) { _, outStatus in
			outStatus.pointee = .haveData
			return buffer
		}
		if let error { throw error }

		return outputBuffer
	}

	static func mergeRanges(
		_ ranges: [(Int, SourceRange)],
		threshold: Double
	) -> [(SourceRange, [Int])] {
		guard !ranges.isEmpty else { return [] }

		let sorted = ranges.sorted { $0.1.start < $1.1.start }

		var result: [(SourceRange, [Int])] = []
		var currentStart = sorted[0].1.start
		var currentEnd = sorted[0].1.end
		var currentIndices = [sorted[0].0]

		for i in 1..<sorted.count {
			let (idx, range) = sorted[i]
			if range.start <= currentEnd + threshold {
				currentEnd = max(currentEnd, range.end)
				currentIndices.append(idx)
			} else {
				result.append((SourceRange(start: currentStart, end: currentEnd), currentIndices))
				currentStart = range.start
				currentEnd = range.end
				currentIndices = [idx]
			}
		}

		result.append((SourceRange(start: currentStart, end: currentEnd), currentIndices))
		return result
	}

}
