/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import CoreML
import Foundation
import SwiftWhisper
import WhisperKit
import whisper_cpp

final class TermBoostFilter: LogitsFiltering {
	let tokenIndexes: [[NSNumber]]
	let boost: Float

	init(tokenIds: [Int], boost: Float = 5.0) {
		self.tokenIndexes = tokenIds.map { [0 as NSNumber, 0 as NSNumber, $0 as NSNumber] }
		self.boost = boost
	}

	func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
		for index in tokenIndexes {
			logits[index] = NSNumber(value: logits[index].floatValue + boost)
		}
		return logits
	}
}

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
		terms: [String],
		onProgress: @escaping @Sendable (Progress) -> Void
	) async throws -> [ClipResult] {
		defer { unloadModel() }
		if WhisperModelManager.isAppleSilicon {
			return try await transcribeWithWhisperKit(
				segments: segments, modelVariant: modelVariant,
				language: language, translateToEnglish: translateToEnglish,
				terms: terms, onProgress: onProgress)
		} else {
			return try await transcribeWithWhisperCpp(
				segments: segments, modelVariant: modelVariant,
				language: language, translateToEnglish: translateToEnglish,
				terms: terms, onProgress: onProgress)
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
		terms: [String],
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

		let termTokens = tokenize(terms: terms, using: kit)
		if termTokens.isEmpty {
			kit.textDecoder.logitsFilters = []
		} else {
			kit.textDecoder.logitsFilters = [TermBoostFilter(tokenIds: termTokens)]
		}

		let options = DecodingOptions(
			task: translateToEnglish ? .translate : .transcribe,
			language: language,
			temperatureFallbackCount: 3,
			detectLanguage: language == nil,
			skipSpecialTokens: true,
			wordTimestamps: true,
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
			let cleanedWords = Self.cleanWhisperKitWords(allWords, language: language)

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

	private func tokenize(terms: [String], using kit: WhisperKit) -> [Int] {
		guard let tokenizer = kit.tokenizer else { return [] }
		return terms.flatMap { word in
			tokenizer.encode(text: " \(word)").filter {
				$0 < tokenizer.specialTokens.specialTokenBegin
			}
		}
	}

	private static func cleanWhisperKitWords(_ words: [WordTiming], language: String?) -> [(
		WordTiming, String
	)] {
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

			if isHallucination(text, language: language) { continue }

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
		terms: [String],
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
		if !terms.isEmpty {
			let str = terms.joined(separator: ", ")
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

			let cleanedSegments = Self.cleanWhisperCppSegments(whisperSegments, language: language)

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
		_ segments: [SwiftWhisper.Segment], language: String?
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

			if isHallucination(text, language: language) { continue }

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

	private static func isHallucination(_ text: String, language: String?) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return true }

		// Non-Latin script in Latin-script languages
		let latinLanguages: Set<String?> = [
			nil, "en", "es", "fr", "de", "it", "pt", "nl", "pl", "ro", "cs", "sk",
			"hr", "da", "fi", "sv", "nb", "hu", "tr", "vi", "id", "ms", "tl",
		]
		if latinLanguages.contains(language) {
			let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
			if !letters.isEmpty {
				let latinCount = letters.filter {
					CharacterSet(charactersIn: "a"..."z")
						.union(CharacterSet(charactersIn: "A"..."Z"))
						.union(CharacterSet(charactersIn: "\u{00C0}"..."\u{024F}"))
						.contains($0)
				}.count
				if Double(latinCount) / Double(letters.count) < 0.5 {
					return true
				}
			}
		}

		// Excessive repetition: same token repeated many times
		let words = trimmed.split(whereSeparator: { $0.isWhitespace })
		if words.count >= 4 {
			let unique = Set(words.map { $0.lowercased() })
			if unique.count == 1 { return true }
			// Most words are the same (e.g. "the the the the end")
			let mostCommon =
				unique.map { u in words.filter { $0.lowercased() == u }.count }.max() ?? 0
			if Double(mostCommon) / Double(words.count) > 0.7 { return true }
		}

		// Single repeated character (e.g. "AAAAAAA")
		let uniqueChars = Set(trimmed.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
		if uniqueChars.count <= 1, trimmed.count > 3 { return true }

		// Common Whisper hallucination phrases
		let lower = trimmed.lowercased()
		let hallucinationPhrases = [
			"thank you for watching",
			"thanks for watching",
			"please subscribe",
			"subscribe to my channel",
			"like and subscribe",
			"see you next time",
			"see you in the next",
			"thanks for listening",
			"thank you for listening",
			"please like and subscribe",
			"don't forget to subscribe",
			"subtitles by",
			"captioned by",
			"translated by",
			"amara.org",
		]
		for phrase in hallucinationPhrases {
			if lower.contains(phrase) { return true }
		}

		return false
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
