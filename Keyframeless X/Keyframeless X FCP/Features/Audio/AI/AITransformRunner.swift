/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation
import KeyframelessAI

@MainActor
final class AITransformBatch: ObservableObject, Identifiable {
	let id = UUID()
	let instruction: String
	@Published var items: [Item]
	@Published var isRunning: Bool = true

	let clips: [(index: Int, clip: FCPXMLParser.AudioClip)]

	struct Item: Identifiable {
		let id = UUID()
		let clipIndex: Int
		let clipName: String
		let isCompound: Bool
		let sentenceStart: Float
		let isFromSRT: Bool
		let originalText: String
		let originalWords: [TranscriptionStore.StoredWord]
		var resultText: String?
		var alignedWords: [TranscriptionStore.StoredWord]?
		var error: String?
		var include: Bool = true

		var status: Status {
			if let error { return .failed(error) }
			if resultText != nil { return .ready }
			return .pending
		}

		enum Status {
			case pending
			case ready
			case failed(String)
		}
	}

	init(instruction: String, clips: [(Int, FCPXMLParser.AudioClip)]) {
		self.instruction = instruction
		self.clips = clips
		var built: [Item] = []
		let store = TranscriptionStore.shared

		for (idx, clip) in clips {
			if let cues = store.srtCues(for: clip) {
				for cue in cues {
					let sourceStart = Float(clip.sourceStart + cue.startTime)
					let sourceEnd = Float(clip.sourceStart + cue.endTime)
					let synth = cue.text
						.split(whereSeparator: { $0.isWhitespace })
						.map {
							TranscriptionStore.StoredWord(
								word: String($0), start: sourceStart, end: sourceEnd)
						}
					guard !synth.isEmpty else { continue }
					built.append(
						Item(
							clipIndex: idx,
							clipName: clip.name,
							isCompound: clip.isCompound,
							sentenceStart: sourceStart,
							isFromSRT: true,
							originalText: synth.map(\.word).joined(separator: " "),
							originalWords: synth
						))
				}
			} else if let words = store.words(for: clip), !words.isEmpty {
				let sentences = AudioEditRowBuilder.groupIntoSentences(words)
				for sentence in sentences {
					built.append(
						Item(
							clipIndex: idx,
							clipName: clip.name,
							isCompound: clip.isCompound,
							sentenceStart: sentence.first!.start,
							isFromSRT: false,
							originalText: sentence.map(\.word).joined(separator: " "),
							originalWords: sentence
						))
				}
			}
		}
		self.items = built
	}
}

enum AITransformRunner {
	static let maxConcurrent = 5

	@MainActor
	static func run(_ batch: AITransformBatch) async {
		let instruction = batch.instruction
		var pending = batch.items.indices.map { idx -> (Int, String) in
			(idx, batch.items[idx].originalText)
		}

		await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
			let initial = pending.prefix(maxConcurrent)
			pending.removeFirst(initial.count)
			for (idx, text) in initial {
				group.addTask {
					do {
						let r = try await AITransform.transform(
							instruction: instruction, text: text)
						return (idx, .success(r))
					} catch {
						return (idx, .failure(error))
					}
				}
			}

			for await (idx, result) in group {
				switch result {
				case .success(let text):
					let aligned = TranscriptionStore.alignWords(
						original: batch.items[idx].originalWords,
						editedText: text
					)
					batch.items[idx].resultText = text
					batch.items[idx].alignedWords = aligned
				case .failure(let err):
					batch.items[idx].error = err.localizedDescription
					batch.items[idx].include = false
				}

				if let next = pending.first {
					pending.removeFirst()
					group.addTask {
						do {
							let r = try await AITransform.transform(
								instruction: instruction, text: next.1)
							return (next.0, .success(r))
						} catch {
							return (next.0, .failure(error))
						}
					}
				}
			}
		}
		batch.isRunning = false
	}

	@MainActor
	static func apply(_ batch: AITransformBatch) {
		let store = TranscriptionStore.shared
		for item in batch.items where item.include {
			guard let aligned = item.alignedWords, !aligned.isEmpty else { continue }
			guard let clip = batch.clips.first(where: { $0.index == item.clipIndex })?.clip
			else { continue }
			let trimmedAligned = aligned.map(\.word).joined(separator: " ")
				.trimmingCharacters(in: .whitespaces)
			let trimmedOriginal = item.originalText.trimmingCharacters(in: .whitespaces)
			if trimmedAligned == trimmedOriginal {
				store.setEditedWords(nil, for: clip, sentenceStart: item.sentenceStart)
			} else {
				store.setEditedWords(aligned, for: clip, sentenceStart: item.sentenceStart)
			}
		}
		NotificationCenter.default.post(name: .aiTransformApplied, object: nil)
	}
}

extension Notification.Name {
	static let aiTransformApplied = Notification.Name("AITransformApplied")
}
