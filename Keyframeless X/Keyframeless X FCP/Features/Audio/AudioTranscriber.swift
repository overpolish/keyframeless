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
		var fraction: Double {
			totalSegments > 0 ? Double(completedSegments) / Double(totalSegments) : 0
		}
	}

	private var whisperKit: WhisperKit?

	func transcribe(
		segments: [AudioPreparer.PreparedSegment],
		modelVariant: String,
		language: String?,
		hotWords: [String],
		onProgress: @Sendable (Progress) -> Void
	) async throws -> [ClipResult] {
		onProgress(
			Progress(phase: .loadingModel, completedSegments: 0, totalSegments: segments.count))

		let modelFolder = FileManager.default
			.urls(for: .documentDirectory, in: .userDomainMask).first!
			.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
			.appendingPathComponent(modelVariant)
			.path
		let config = WhisperKitConfig(modelFolder: modelFolder, download: false)
		let kit = try await WhisperKit(config)
		try Task.checkCancellation()
		whisperKit = kit

		let promptTokens = tokenize(hotWords: hotWords, using: kit)

		let options = DecodingOptions(
			language: language,
			wordTimestamps: true,
			promptTokens: promptTokens.isEmpty ? nil : promptTokens
		)

		var allClipResults: [ClipResult] = []

		for (i, segment) in segments.enumerated() {
			try Task.checkCancellation()

			onProgress(
				Progress(phase: .transcribing, completedSegments: i, totalSegments: segments.count))

			let results: [TranscriptionResult] = try await kit.transcribe(
				audioPath: segment.tempFileURL.path,
				decodeOptions: options
			)

			let allWords = results.flatMap { $0.allWords }

			for mapping in segment.clipMappings {
				let clipWords = allWords.compactMap { word -> WordResult? in
					let sourceTime = Double(word.start) + segment.range.start
					let clipEnd = mapping.clipSourceStart + mapping.clipSourceDuration
					guard sourceTime >= mapping.clipSourceStart - 0.05,
						sourceTime < clipEnd + 0.05
					else { return nil }
					return WordResult(
						word: word.word,
						start: Float(sourceTime),
						end: Float(Double(word.end) + segment.range.start),
						probability: word.probability
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

	private func tokenize(hotWords: [String], using kit: WhisperKit) -> [Int] {
		guard let tokenizer = kit.tokenizer else { return [] }
		return hotWords.flatMap { word in
			tokenizer.encode(text: " \(word)").filter {
				$0 < tokenizer.specialTokens.specialTokenBegin
			}
		}
	}

}
