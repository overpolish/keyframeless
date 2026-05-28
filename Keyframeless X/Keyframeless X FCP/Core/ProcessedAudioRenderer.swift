/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

actor ProcessedAudioRenderer {
	static let shared = ProcessedAudioRenderer()

	private var cache: [String: URL] = [:]
	private var inflight: [String: Task<URL, Error>] = [:]

	private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "avi"]

	func renderedURL(for clip: FCPXMLParser.AudioClip) async throws -> URL {
		let key = Self.cacheKey(for: clip)
		if let url = cache[key], FileManager.default.fileExists(atPath: url.path) {
			return url
		}
		if let task = inflight[key] {
			return try await task.value
		}
		let task = Task<URL, Error> { try await Self.render(clip: clip) }
		inflight[key] = task
		do {
			let url = try await task.value
			cache[key] = url
			inflight[key] = nil
			return url
		} catch {
			inflight[key] = nil
			throw error
		}
	}

	private static func cacheKey(for clip: FCPXMLParser.AudioClip) -> String {
		AudioClipFingerprint.of(clip)
	}

	private static func render(clip: FCPXMLParser.AudioClip) async throws -> URL {
		let resolved = try clip.resolvedURL()
		defer { resolved.stopAccess() }

		let isVideo = videoExtensions.contains(resolved.url.pathExtension.lowercased())
		let sourceURL: URL
		let extractedTemp: URL?
		let needsChannelExtraction = (clip.sourceChannels?.count ?? 0) > 0
		let extractedTrimmedToClip: Bool
		if isVideo || needsChannelExtraction
			|| (try? AVAudioFile(
				forReading: resolved.url, commonFormat: .pcmFormatFloat32, interleaved: false))
				== nil
		{
			let extracted = try await AudioPreparer.extractAudioTrack(
				from: resolved.url, sourceChannels: clip.sourceChannels,
				timeRange: (clip.sourceStart, clip.sourceDuration))
			sourceURL = extracted
			extractedTemp = extracted
			extractedTrimmedToClip = true
		} else {
			sourceURL = resolved.url
			extractedTemp = nil
			extractedTrimmedToClip = false
		}
		defer {
			if let t = extractedTemp { try? FileManager.default.removeItem(at: t) }
		}

		let audioFile = try AVAudioFile(
			forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
		let sampleRate = audioFile.fileFormat.sampleRate
		let startFrame: AVAudioFramePosition
		let endFrame: AVAudioFramePosition
		if extractedTrimmedToClip {
			startFrame = 0
			endFrame = audioFile.length
		} else {
			startFrame = AVAudioFramePosition(clip.sourceStart * sampleRate)
			endFrame = min(
				AVAudioFramePosition((clip.sourceStart + clip.sourceDuration) * sampleRate),
				audioFile.length)
		}
		let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
		audioFile.framePosition = max(0, startFrame)

		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)
		else {
			throw NSError(domain: "ProcessedAudioRenderer", code: 1)
		}
		try audioFile.read(into: buffer, frameCount: frameCount)

		let mapping = AudioPreparer.ClipMapping(
			clipIndex: 0,
			offsetInSegment: 0,
			clipSourceStart: clip.sourceStart,
			clipSourceDuration: clip.sourceDuration,
			volumeCurve: clip.volumeCurve,
			fadeIn: clip.fadeIn,
			fadeOut: clip.fadeOut,
			outer: clip.outer
		)
		AudioPreparer.applyVolumeCurves(
			buffer: buffer,
			segmentStart: clip.sourceStart,
			sampleRate: sampleRate,
			mappings: [mapping]
		)

		var processed = buffer
		if let filters = clip.auFilters, !filters.isEmpty {
			processed = try await AudioUnitRenderer.process(
				buffer: buffer, filters: filters, baseSourceTime: clip.sourceStart)
		}

		let outURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("kk_processed_\(UUID().uuidString).wav")
		let outFile = try AVAudioFile(forWriting: outURL, settings: processed.format.settings)
		try outFile.write(from: processed)
		return outURL
	}
}
