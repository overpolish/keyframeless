/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Foundation
import SwiftWhisper
import WhisperKit
import whisper_cpp

actor AudioTranscriber {

	struct WordResult {
		let word: String
		let start: Float
		let end: Float
	}

	struct ClipResult {
		let clipIndex: Int
		let words: [WordResult]
	}

	enum Phase: String {
		case preparingAudio = "Preparing audio"
		case loadingModel = "Loading model"
		case detectingLanguage = "Detecting language"
		case transcribing = "Transcribing"
	}

	struct Progress {
		let phase: Phase
		let completedSegments: Int
		let totalSegments: Int
		var segmentProgress: Double = 0
		var fraction: Double {
			guard totalSegments > 0 else { return 0 }
			return (Double(completedSegments) + segmentProgress) / Double(totalSegments)
		}
	}

	// WhisperKit (Silicon)
	private nonisolated(unsafe) var whisperKit: WhisperKit?
	private var loadedWhisperKitVariant: String?

	// SwiftWhisper (Intel)
	private nonisolated(unsafe) var whisperCpp: Whisper?
	private var loadedWhisperCppVariant: String?
	private var promptCString: UnsafeMutablePointer<CChar>?
	private nonisolated(unsafe) var progressDelegate: WhisperProgressDelegate?

	func transcribe(
		segments: [AudioPreparer.PreparedSegment],
		modelVariant: String,
		language: String?,
		translateToEnglish: Bool,
		hotWords: [String],
		onProgress: @escaping @Sendable (Progress) -> Void
	) async throws -> [ClipResult] {
		defer { unloadModel() }
		if WhisperModelManager.isAppleSilicon {
			return try await transcribeWithWhisperKit(
				segments: segments, modelVariant: modelVariant,
				language: language, translateToEnglish: translateToEnglish,
				hotWords: hotWords, onProgress: onProgress)
		} else {
			return try await transcribeWithWhisperCpp(
				segments: segments, modelVariant: modelVariant,
				language: language, translateToEnglish: translateToEnglish,
				hotWords: hotWords, onProgress: onProgress)
		}
	}

	func forceUnload() async {
		try? await whisperCpp?.cancel()
		unloadModel()
	}

	private func unloadModel() {
		whisperKit = nil
		loadedWhisperKitVariant = nil
		whisperCpp = nil
		loadedWhisperCppVariant = nil
		progressDelegate = nil
		promptCString?.deallocate()
		promptCString = nil
	}

	// WhisperKit engine (Silicon)

	private func transcribeWithWhisperKit(
		segments: [AudioPreparer.PreparedSegment],
		modelVariant: String,
		language: String?,
		translateToEnglish: Bool,
		hotWords: [String],
		onProgress: @escaping @Sendable (Progress) -> Void
	) async throws -> [ClipResult] {
		onProgress(
			Progress(phase: .loadingModel, completedSegments: 0, totalSegments: segments.count))

		let kit: WhisperKit
		if let existing = whisperKit, loadedWhisperKitVariant == modelVariant {
			kit = existing
		} else {
			whisperKit = nil
			loadedWhisperKitVariant = nil

			let modelFolder = FileManager.default
				.urls(for: .documentDirectory, in: .userDomainMask).first!
				.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
				.appendingPathComponent(modelVariant)
				.path
			let config = WhisperKitConfig(modelFolder: modelFolder, download: false)
			kit = try await WhisperKit(config)
			try Task.checkCancellation()
			whisperKit = kit
			loadedWhisperKitVariant = modelVariant
		}

		let promptTokens = tokenize(hotWords: hotWords, using: kit)

		let options = DecodingOptions(
			task: translateToEnglish ? .translate : .transcribe,
			language: language,
			temperatureFallbackCount: 3,
			detectLanguage: language == nil,
			skipSpecialTokens: true,
			wordTimestamps: true,
			promptTokens: promptTokens.isEmpty ? nil : promptTokens,
			suppressBlank: true,
			compressionRatioThreshold: 2.4,
			logProbThreshold: -1.0,
			noSpeechThreshold: 0.6
		)

		var allClipResults: [ClipResult] = []

		for (i, segment) in segments.enumerated() {
			try Task.checkCancellation()

			onProgress(
				Progress(phase: .transcribing, completedSegments: i, totalSegments: segments.count))

			let segmentCount = segments.count
			let segmentDuration = segment.range.duration + segment.paddingDuration
			let estWindows = max(1.0, ceil(segmentDuration / 29))
			let results: [TranscriptionResult] = try await kit.transcribe(
				audioPath: segment.tempFileURL.path,
				decodeOptions: options,
				callback: { whisperProgress in
					let windowFrac = min(
						0.99, Double(whisperProgress.windowId) / estWindows)
					onProgress(
						Progress(
							phase: .transcribing,
							completedSegments: i,
							totalSegments: segmentCount,
							segmentProgress: windowFrac
						)
					)
					return nil
				}
			)

			let allWords = results.flatMap { $0.allWords }
			let cleanedWords = Self.cleanWhisperKitWords(allWords)

			print(
				"[Transcriber] segment \(i): \(allWords.count) raw words, \(cleanedWords.count) cleaned, range \(segment.range.start)–\(segment.range.end)"
			)

			for mapping in segment.clipMappings {
				let clipEnd = mapping.clipSourceStart + mapping.clipSourceDuration
				let clipWords = cleanedWords.compactMap { word, cleaned -> WordResult? in
					let sourceTime =
						Double(word.start) - segment.paddingDuration + segment.range.start
					let sourceEnd =
						min(
							Double(word.end) - segment.paddingDuration + segment.range.start + 0.05,
							clipEnd)
					guard sourceTime >= mapping.clipSourceStart - 0.05,
						sourceTime < clipEnd + 0.05
					else { return nil }
					return WordResult(
						word: cleaned,
						start: Float(sourceTime),
						end: Float(sourceEnd)
					)
				}
				let fixedWords = Self.fixOverlappingTimestamps(clipWords)
				if fixedWords.isEmpty {
					print(
						"[Transcriber] clip \(mapping.clipIndex): 0 words matched (source \(mapping.clipSourceStart)–\(mapping.clipSourceStart + mapping.clipSourceDuration))"
					)
				}
				allClipResults.append(
					ClipResult(clipIndex: mapping.clipIndex, words: fixedWords)
				)
			}

			onProgress(
				Progress(
					phase: .transcribing, completedSegments: i + 1, totalSegments: segments.count))
		}

		return allClipResults
	}

	private func tokenize(hotWords: [String], using kit: WhisperKit) -> [Int] {
		guard let tokenizer = kit.tokenizer else { return [] }
		return hotWords.flatMap { word in
			tokenizer.encode(text: " \(word)").filter {
				$0 < tokenizer.specialTokens.specialTokenBegin
			}
		}
	}

	private static func cleanWhisperKitWords(_ words: [WordTiming]) -> [(WordTiming, String)] {
		var result: [(WordTiming, String)] = []
		var skipUntilCloseBracket = false
		var skipUntilCloseParen = false

		for word in words {
			let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)

			if text.contains("[") { skipUntilCloseBracket = true }
			if text.contains("(") { skipUntilCloseParen = true }

			if skipUntilCloseBracket {
				if text.contains("]") { skipUntilCloseBracket = false }
				continue
			}
			if skipUntilCloseParen {
				if text.contains(")") { skipUntilCloseParen = false }
				continue
			}

			var cleaned =
				text
				.replacingOccurrences(of: "...", with: "")
				.replacingOccurrences(of: "…", with: "")
				.replacingOccurrences(of: ">>", with: "")
				.replacingOccurrences(of: "♪", with: "")
				.replacingOccurrences(of: "Ґ", with: "")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			cleaned = Self.stripDashes(cleaned)
			guard !cleaned.isEmpty else { continue }

			let lower = cleaned.lowercased()
			if let digit = numberWords[lower] {
				cleaned = digit
			}

			result.append((word, cleaned))
		}

		return result
	}

	// SwiftWhisper engine (Intel)

	private func transcribeWithWhisperCpp(
		segments: [AudioPreparer.PreparedSegment],
		modelVariant: String,
		language: String?,
		translateToEnglish: Bool,
		hotWords: [String],
		onProgress: @escaping @Sendable (Progress) -> Void
	) async throws -> [ClipResult] {
		onProgress(
			Progress(phase: .loadingModel, completedSegments: 0, totalSegments: segments.count))

		let w: Whisper
		if let existing = whisperCpp, loadedWhisperCppVariant == modelVariant {
			w = existing
		} else {
			whisperCpp = nil
			loadedWhisperCppVariant = nil

			let modelURL = WhisperModelManager.modelFileURL(for: modelVariant)
			w = Whisper(fromFileURL: modelURL)
			try Task.checkCancellation()
			whisperCpp = w
			loadedWhisperCppVariant = modelVariant
		}

		let lang = language.flatMap { WhisperLanguage(rawValue: $0) } ?? .auto
		w.params.language = lang
		w.params.translate = translateToEnglish
		w.params.split_on_word = true
		w.params.max_len = 1
		w.params.token_timestamps = true
		w.params.suppress_blank = true
		w.params.no_speech_thold = 0.8
		w.params.entropy_thold = 2.4
		w.params.logprob_thold = -1.0
		w.params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
		w.params.no_context = true
		w.params.temperature_inc = 0

		promptCString?.deallocate()
		promptCString = nil
		if !hotWords.isEmpty {
			let str = hotWords.joined(separator: ", ")
			let cStr = strdup(str)
			promptCString = cStr
			w.params.initial_prompt = UnsafePointer(cStr)
		} else {
			w.params.initial_prompt = nil
		}

		let segmentCount = segments.count
		let detectingLanguage = language == nil
		let delegate = WhisperProgressDelegate()
		progressDelegate = delegate
		w.delegate = delegate

		var allClipResults: [ClipResult] = []

		for (i, segment) in segments.enumerated() {
			try Task.checkCancellation()

			var didStartTranscribing = false
			delegate.onProgress = { frac in
				let phase: Phase
				if detectingLanguage && !didStartTranscribing && frac < 0.05 {
					phase = .detectingLanguage
				} else {
					didStartTranscribing = true
					phase = .transcribing
				}
				onProgress(
					Progress(
						phase: phase,
						completedSegments: i,
						totalSegments: segmentCount,
						segmentProgress: frac
					)
				)
			}

			if detectingLanguage {
				onProgress(
					Progress(
						phase: .detectingLanguage, completedSegments: i,
						totalSegments: segments.count))
			} else {
				onProgress(
					Progress(
						phase: .transcribing, completedSegments: i,
						totalSegments: segments.count))
			}

			let audioFrames = try Self.loadAudioFrames(from: segment.tempFileURL)
			let whisperSegments = try await w.transcribe(audioFrames: audioFrames)

			let cleanedSegments = Self.cleanWhisperCppSegments(whisperSegments)

			print(
				"[Transcriber] segment \(i): \(whisperSegments.count) raw words, \(cleanedSegments.count) cleaned, range \(segment.range.start)–\(segment.range.end)"
			)

			for mapping in segment.clipMappings {
				let clipEnd = mapping.clipSourceStart + mapping.clipSourceDuration
				let clipWords = cleanedSegments.compactMap {
					seg, cleaned -> WordResult? in
					let sourceTime =
						Double(seg.startTime) / 1000.0 - segment.paddingDuration
						+ segment.range.start
					let sourceEnd =
						min(
							Double(seg.endTime) / 1000.0 - segment.paddingDuration
								+ segment.range.start + 0.05, clipEnd)
					guard sourceTime >= mapping.clipSourceStart - 0.05,
						sourceTime < clipEnd + 0.05
					else { return nil }
					return WordResult(
						word: cleaned,
						start: Float(sourceTime),
						end: Float(sourceEnd)
					)
				}
				let fixedWords = Self.fixOverlappingTimestamps(clipWords)
				if fixedWords.isEmpty {
					print(
						"[Transcriber] clip \(mapping.clipIndex): 0 words matched (source \(mapping.clipSourceStart)–\(mapping.clipSourceStart + mapping.clipSourceDuration))"
					)
				}
				allClipResults.append(
					ClipResult(clipIndex: mapping.clipIndex, words: fixedWords)
				)
			}

			onProgress(
				Progress(
					phase: .transcribing, completedSegments: i + 1, totalSegments: segments.count))
		}

		return allClipResults
	}

	private static func loadAudioFrames(from url: URL) throws -> [Float] {
		let audioFile = try AVAudioFile(
			forReading: url,
			commonFormat: .pcmFormatFloat32,
			interleaved: false
		)
		let frameCount = AVAudioFrameCount(audioFile.length)
		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)
		else {
			throw NSError(
				domain: "AudioTranscriber", code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
		}
		try audioFile.read(into: buffer)
		return Array(
			UnsafeBufferPointer(
				start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
	}

	private static func cleanWhisperCppSegments(
		_ segments: [SwiftWhisper.Segment]
	) -> [(SwiftWhisper.Segment, String)] {
		var result: [(SwiftWhisper.Segment, String)] = []
		var skipUntilCloseBracket = false
		var skipUntilCloseParen = false

		for segment in segments {
			let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

			if text.contains("[") { skipUntilCloseBracket = true }
			if text.contains("(") { skipUntilCloseParen = true }

			if skipUntilCloseBracket {
				if text.contains("]") { skipUntilCloseBracket = false }
				continue
			}
			if skipUntilCloseParen {
				if text.contains(")") { skipUntilCloseParen = false }
				continue
			}

			var cleaned =
				text
				.replacingOccurrences(of: "...", with: "")
				.replacingOccurrences(of: "…", with: "")
				.replacingOccurrences(of: ">>", with: "")
				.replacingOccurrences(of: "♪", with: "")
				.replacingOccurrences(of: "Ґ", with: "")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			cleaned = Self.stripDashes(cleaned)
			guard !cleaned.isEmpty else { continue }

			let lower = cleaned.lowercased()
			if let digit = numberWords[lower] {
				cleaned = digit
			}

			result.append((segment, cleaned))
		}

		return result
	}

	// Shared

	private static func fixOverlappingTimestamps(_ words: [WordResult]) -> [WordResult] {
		guard !words.isEmpty else { return [] }
		var fixed = [words[0]]
		for i in 1..<words.count {
			var word = words[i]
			let prev = fixed[i - 1]
			if word.start < prev.end {
				word = WordResult(word: word.word, start: prev.end, end: max(word.end, prev.end))
			}
			fixed.append(word)
		}
		return fixed
	}

	private static func stripDashes(_ text: String) -> String {
		var s = text
		while s.hasPrefix("-") || s.hasPrefix("–") || s.hasPrefix("—") {
			s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
		}
		return s
	}

	private static let numberWords: [String: String] = [
		"zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
		"five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
		"ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
		"fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
		"eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
		"forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
		"eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
	]
}

private class WhisperProgressDelegate: WhisperDelegate {
	var onProgress: ((Double) -> Void)?

	func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
		onProgress?(progress)
	}
}
