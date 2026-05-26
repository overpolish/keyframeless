/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
		var paddingDuration: Double = 0
	}

	struct ProcessingSegment {
		let sourceURL: URL?
		let bookmark: Data?
		let sourceName: String
		let range: SourceRange
		let clipMappings: [ClipMapping]
		let sourceChannels: [Int]?
	}

	struct ClipMapping {
		let clipIndex: Int
		let offsetInSegment: Double
		let clipSourceStart: Double
		let clipSourceDuration: Double
		let volumeCurve: [FCPXMLParser.VolumePoint]?
		let fadeIn: FCPXMLParser.FadeSpec?
		let fadeOut: FCPXMLParser.FadeSpec?
	}

	static let mergeThreshold: Double = 5.0
	static let minimumSegmentDuration: Double = 3.0

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
			let channelKey =
				clip.sourceChannels?.map(String.init).joined(separator: ",") ?? "default"
			return (clip.url?.absoluteString ?? clip.name) + "#" + channelKey
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
						clipSourceDuration: clip.sourceDuration,
						volumeCurve: clip.volumeCurve,
						fadeIn: clip.fadeIn,
						fadeOut: clip.fadeOut
					)
				}
				segments.append(
					ProcessingSegment(
						sourceURL: representative.url,
						bookmark: representative.bookmark,
						sourceName: representative.name,
						range: mergedRange,
						clipMappings: mappings,
						sourceChannels: representative.sourceChannels
					)
				)
			}
		}

		return segments
	}

	static func extractAudio(for segments: [ProcessingSegment]) async throws -> [PreparedSegment] {
		print("[AudioPreparer] BEGIN extractAudio - \(segments.count) segments")
		var sourceFileCache: [String: URL] = [:]
		var audioURLCache: [String: URL] = [:]
		var prepared: [PreparedSegment] = []

		for segment in segments {
			let sourceKey = segment.sourceURL?.absoluteString ?? segment.sourceName
			let channelKey =
				segment.sourceChannels?.map(String.init).joined(separator: ",") ?? "default"
			let extractKey = sourceKey + "#" + channelKey

			print(
				"[AudioPreparer] segment: bookmark=\(segment.bookmark != nil), url=\(segment.sourceURL?.lastPathComponent ?? "nil") channels=\(channelKey)"
			)
			let sourceFileURL: URL
			if let cached = sourceFileCache[sourceKey] {
				sourceFileURL = cached
			} else if let bookmark = segment.bookmark,
				let scopedURL = {
					var isStale = false
					return try? URL(
						resolvingBookmarkData: bookmark,
						options: .withSecurityScope,
						relativeTo: nil,
						bookmarkDataIsStale: &isStale)
				}()
			{
				_ = scopedURL.startAccessingSecurityScopedResource()
				sourceFileCache[sourceKey] = scopedURL
				sourceFileURL = scopedURL
			} else if let url = segment.sourceURL {
				sourceFileCache[sourceKey] = url
				sourceFileURL = url
			} else {
				throw CocoaError(.fileNoSuchFile)
			}

			let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "avi"]
			let isVideo = videoExtensions.contains(
				sourceFileURL.pathExtension.lowercased())
			let needsChannelExtract = (segment.sourceChannels?.count ?? 0) > 0

			let audioURL: URL
			if let cached = audioURLCache[extractKey] {
				audioURL = cached
			} else if !isVideo, !needsChannelExtract,
				(try? AVAudioFile(
					forReading: sourceFileURL, commonFormat: .pcmFormatFloat32, interleaved: false
				)) != nil
			{
				audioURL = sourceFileURL
			} else {
				print("[AudioPreparer] extracting audio from \(sourceFileURL.lastPathComponent)")
				let wavURL = try await extractAudioTrack(
					from: sourceFileURL, sourceChannels: segment.sourceChannels)
				let size =
					(try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int)
					?? 0
				print("[AudioPreparer] extracted WAV: \(size) bytes at \(wavURL.lastPathComponent)")
				audioURLCache[extractKey] = wavURL
				audioURL = wavURL
			}

			print("[AudioPreparer] opening audioURL: \(audioURL.lastPathComponent)")
			let audioFile = try AVAudioFile(
				forReading: audioURL,
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
					"[AudioPreparer] skipping segment \(segment.sourceName) - buffer alloc failed (frameCount: \(frameCount))"
				)
				continue
			}
			try audioFile.read(into: buffer, frameCount: frameCount)

			applyVolumeCurves(
				buffer: buffer,
				segmentStart: segment.range.start,
				sampleRate: sampleRate,
				mappings: segment.clipMappings
			)

			let whisperBuffer = try resampleToWhisperFormat(buffer: buffer)

			var paddingDuration: Double = 0
			let segmentDuration = segment.range.duration
			let outURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("kk_segment_\(UUID().uuidString).wav")
			let outFile = try AVAudioFile(
				forWriting: outURL,
				settings: whisperBuffer.format.settings
			)

			if segmentDuration < minimumSegmentDuration {
				paddingDuration = minimumSegmentDuration - segmentDuration
				let padFrames = AVAudioFrameCount(paddingDuration * whisperBuffer.format.sampleRate)
				if let silenceBuffer = AVAudioPCMBuffer(
					pcmFormat: whisperBuffer.format, frameCapacity: padFrames
				) {
					silenceBuffer.frameLength = padFrames
					try outFile.write(from: silenceBuffer)
				}
			}

			try outFile.write(from: whisperBuffer)

			prepared.append(
				PreparedSegment(
					tempFileURL: outURL,
					sourceName: segment.sourceName,
					range: segment.range,
					clipMappings: segment.clipMappings,
					paddingDuration: paddingDuration
				)
			)
		}

		for url in sourceFileCache.values {
			url.stopAccessingSecurityScopedResource()
		}
		for url in audioURLCache.values {
			try? FileManager.default.removeItem(at: url)
		}

		return prepared
	}

	static func extractAudioTrack(
		from url: URL, sourceChannels: [Int]? = nil,
		timeRange: (start: Double, duration: Double)? = nil
	) async throws -> URL {
		try await AssetAudioExtractor.extract(
			from: url, sourceChannels: sourceChannels, timeRange: timeRange)
	}

	static func cleanUp(segments: [PreparedSegment]) {
		for segment in segments {
			try? FileManager.default.removeItem(at: segment.tempFileURL)
		}
	}

	static func applyVolumeCurves(
		buffer: AVAudioPCMBuffer, segmentStart: Double, sampleRate: Double,
		mappings: [ClipMapping]
	) {
		AudioBufferProcessing.applyVolumeCurves(
			buffer: buffer, segmentStart: segmentStart, sampleRate: sampleRate,
			mappings: mappings)
	}

	static func fadeMultiplier(
		clipLocal tc: Double, duration: Double,
		fadeIn: FCPXMLParser.FadeSpec?, fadeOut: FCPXMLParser.FadeSpec?
	) -> Float {
		AudioBufferProcessing.fadeMultiplier(
			clipLocal: tc, duration: duration, fadeIn: fadeIn, fadeOut: fadeOut)
	}

	private static func resampleToWhisperFormat(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer
	{
		try AssetAudioExtractor.resampleToWhisperFormat(buffer: buffer)
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
