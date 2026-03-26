/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation
import WhisperKit

actor AudioTranscriber {

	struct WordResult {
		let word: String
		let start: Float
		let end: Float
		let probability: Float
	}

	struct ClipResult {
		let clipIndex: Int
		let words: [WordResult]
	}

	enum Phase: String {
		case preparingAudio = "Preparing audio"
		case loadingModel = "Loading model"
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

	private var whisperKit: WhisperKit?
	private var loadedModelVariant: String?

	func transcribe(
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
		if let existing = whisperKit, loadedModelVariant == modelVariant {
			kit = existing
		} else {
			whisperKit = nil
			loadedModelVariant = nil

			let modelFolder = FileManager.default
				.urls(for: .documentDirectory, in: .userDomainMask).first!
				.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
				.appendingPathComponent(modelVariant)
				.path
			let config = WhisperKitConfig(modelFolder: modelFolder, download: false)
			kit = try await WhisperKit(config)
			try Task.checkCancellation()
			whisperKit = kit
			loadedModelVariant = modelVariant
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
			let cleanedWords = Self.cleanWords(allWords)

			print(
				"[Transcriber] segment \(i): \(allWords.count) raw words, \(cleanedWords.count) cleaned, range \(segment.range.start)–\(segment.range.end)"
			)

			for mapping in segment.clipMappings {
				let clipWords = cleanedWords.compactMap { word, cleaned -> WordResult? in
					let sourceTime =
						Double(word.start) - segment.paddingDuration + segment.range.start
					let sourceEnd =
						Double(word.end) - segment.paddingDuration + segment.range.start + 0.05
					let clipEnd = mapping.clipSourceStart + mapping.clipSourceDuration
					guard sourceTime >= mapping.clipSourceStart - 0.05,
						sourceTime < clipEnd + 0.05
					else { return nil }
					return WordResult(
						word: cleaned,
						start: Float(sourceTime),
						end: Float(sourceEnd),
						probability: word.probability
					)
				}
				if clipWords.isEmpty {
					print(
						"[Transcriber] clip \(mapping.clipIndex): 0 words matched (source \(mapping.clipSourceStart)–\(mapping.clipSourceStart + mapping.clipSourceDuration))"
					)
				}
				allClipResults.append(
					ClipResult(clipIndex: mapping.clipIndex, words: clipWords)
				)
			}

			onProgress(
				Progress(
					phase: .transcribing, completedSegments: i + 1, totalSegments: segments.count))
		}

		return allClipResults
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

	private static func cleanWords(_ words: [WordTiming]) -> [(WordTiming, String)] {
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
				.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !cleaned.isEmpty else { continue }

			let lower = cleaned.lowercased()
			if let digit = numberWords[lower] {
				cleaned = digit
			}

			result.append((word, cleaned))
		}

		return result
	}

	private func tokenize(hotWords: [String], using kit: WhisperKit) -> [Int] {
		guard let tokenizer = kit.tokenizer else { return [] }
		return hotWords.flatMap { word in
			tokenizer.encode(text: " \(word)").filter {
				$0 < tokenizer.specialTokens.specialTokenBegin
			}
		}
	}

}
