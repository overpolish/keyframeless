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
	}

	struct ClipMapping {
		let clipIndex: Int
		let offsetInSegment: Double
		let clipSourceStart: Double
		let clipSourceDuration: Double
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

	static func extractAudio(for segments: [ProcessingSegment]) async throws -> [PreparedSegment] {
		print("[AudioPreparer] BEGIN extractAudio — \(segments.count) segments")
		var sourceFileCache: [String: URL] = [:]
		var audioURLCache: [String: URL] = [:]
		var prepared: [PreparedSegment] = []

		for segment in segments {
			let cacheKey = segment.sourceURL?.absoluteString ?? segment.sourceName

			print(
				"[AudioPreparer] segment: bookmark=\(segment.bookmark != nil), url=\(segment.sourceURL?.lastPathComponent ?? "nil")"
			)
			let sourceFileURL: URL
			if let cached = sourceFileCache[cacheKey] {
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
				sourceFileCache[cacheKey] = scopedURL
				sourceFileURL = scopedURL
			} else if let url = segment.sourceURL {
				sourceFileCache[cacheKey] = url
				sourceFileURL = url
			} else {
				throw CocoaError(.fileNoSuchFile)
			}

			let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "avi"]
			let isVideo = videoExtensions.contains(
				sourceFileURL.pathExtension.lowercased())

			let audioURL: URL
			if let cached = audioURLCache[cacheKey] {
				audioURL = cached
			} else if !isVideo,
				(try? AVAudioFile(
					forReading: sourceFileURL, commonFormat: .pcmFormatFloat32, interleaved: false
				)) != nil
			{
				audioURL = sourceFileURL
			} else {
				print("[AudioPreparer] extracting audio from \(sourceFileURL.lastPathComponent)")
				let wavURL = try await extractAudioTrack(from: sourceFileURL)
				let size =
					(try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int)
					?? 0
				print("[AudioPreparer] extracted WAV: \(size) bytes at \(wavURL.lastPathComponent)")
				audioURLCache[cacheKey] = wavURL
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
					"[AudioPreparer] skipping segment \(segment.sourceName) — buffer alloc failed (frameCount: \(frameCount))"
				)
				continue
			}
			try audioFile.read(into: buffer, frameCount: frameCount)

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

	private static func extractAudioTrack(from url: URL) async throws -> URL {
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
			throw NSError(domain: "AudioPreparer", code: 10)
		}

		let reader = try AVAssetReader(asset: asset)
		let readerOutput = AVAssetReaderTrackOutput(
			track: track,
			outputSettings: [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVLinearPCMBitDepthKey: 32,
				AVLinearPCMIsFloatKey: true,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsNonInterleaved: false,
				AVNumberOfChannelsKey: 1,
			])
		reader.add(readerOutput)

		let wavURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("kk_extracted_\(UUID().uuidString).wav")
		let writer = try AVAssetWriter(outputURL: wavURL, fileType: .wav)
		let writerInput = AVAssetWriterInput(
			mediaType: .audio,
			outputSettings: [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVLinearPCMBitDepthKey: 16,
				AVLinearPCMIsFloatKey: false,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsNonInterleaved: false,
				AVNumberOfChannelsKey: 1,
				AVSampleRateKey: 48000,
			])
		writer.add(writerInput)

		reader.startReading()
		writer.startWriting()
		writer.startSession(atSourceTime: .zero)

		while reader.status == .reading {
			if let buffer = readerOutput.copyNextSampleBuffer() {
				while !writerInput.isReadyForMoreMediaData {
					try await Task.sleep(nanoseconds: 10_000_000)
				}
				writerInput.append(buffer)
			} else {
				break
			}
		}

		writerInput.markAsFinished()
		await writer.finishWriting()

		guard writer.status == .completed else {
			throw writer.error ?? NSError(domain: "AudioPreparer", code: 12)
		}

		return wavURL
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
