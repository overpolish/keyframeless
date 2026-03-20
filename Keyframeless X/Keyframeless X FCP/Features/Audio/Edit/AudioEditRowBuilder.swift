/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit

struct AudioEditRow: Identifiable {
	let id: Int
	let clipIndex: Int
	let clipName: String
	let text: String
	let timestamp: String
	let isHeader: Bool
	let isTranscribed: Bool
	var sentenceStart: Double = 0
	var sentenceEnd: Double = 0
	var words: [TranscriptionStore.StoredWord] = []
}

enum AudioEditRowBuilder {
	static func buildRows(
		clips: [FCPXMLParser.AudioClip],
		format: FCPXMLParser.ProjectFormat?
	) -> [AudioEditRow] {
		let store = TranscriptionStore.shared
		var result: [AudioEditRow] = []
		var nextID = 0

		for idx in clips.indices {
			let clip = clips[idx]
			let words = store.words(for: clip)
			let hasTranscription = words != nil

			result.append(
				AudioEditRow(
					id: nextID, clipIndex: idx, clipName: clip.name, text: "", timestamp: "",
					isHeader: true, isTranscribed: hasTranscription))
			nextID += 1

			if let words {
				let sentences = groupIntoSentences(words)
				for sentence in sentences {
					let text = sentence.map { $0.word.trimmingCharacters(in: .whitespaces) }
						.joined(separator: " ")
					result.append(
						AudioEditRow(
							id: nextID,
							clipIndex: idx,
							clipName: clip.name,
							text: text,
							timestamp: formatTimestamp(sentence.first!.start, format: format),
							isHeader: false,
							isTranscribed: true,
							sentenceStart: Double(sentence.first!.start),
							sentenceEnd: Double(sentence.last!.end),
							words: sentence
						))
					nextID += 1
				}
			}
		}
		return result
	}

	private static let sentenceEndChars = CharacterSet(charactersIn: ".!?")
	private static let pauseThreshold: Float = 0.7

	private static func groupIntoSentences(
		_ words: [TranscriptionStore.StoredWord]
	) -> [[TranscriptionStore.StoredWord]] {
		guard !words.isEmpty else { return [] }

		var sentences: [[TranscriptionStore.StoredWord]] = []
		var current: [TranscriptionStore.StoredWord] = []

		for word in words {
			if let prev = current.last,
				word.start - prev.end > pauseThreshold
			{
				sentences.append(current)
				current = []
			}

			current.append(word)

			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			if trimmed.unicodeScalars.last.map({ sentenceEndChars.contains($0) }) == true {
				sentences.append(current)
				current = []
			}
		}

		if !current.isEmpty {
			sentences.append(current)
		}

		return sentences
	}

	private static func formatTimestamp(
		_ time: Float, format: FCPXMLParser.ProjectFormat?
	) -> String {
		if let format {
			return format.timecode(for: Double(time))
		}
		let s = Int(time) % 60
		let m = Int(time) / 60
		let ms = Int((time - Float(Int(time))) * 100)
		return String(format: "%d:%02d.%02d", m, s, ms)
	}
}
