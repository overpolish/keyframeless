/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AudioEditView: View {
	@ObservedObject var model: AudioModel

	@State private var rows: [Row] = []

	struct Row: Identifiable {
		let id: Int
		let clipName: String
		let text: String
		let timestamp: String
		let isHeader: Bool
	}

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(rows) { row in
					if row.isHeader {
						Text(row.clipName)
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(.secondary)
							.padding(.top, KKSpacingLG)
							.padding(.bottom, KKSpacingXS)
					} else {
						HStack(alignment: .top, spacing: KKSpacingMD) {
							Text(row.timestamp)
								.font(.system(size: 11).monospacedDigit())
								.foregroundStyle(.tertiary)
								.frame(width: 80, alignment: .trailing)
							Text(row.text)
								.font(.system(size: 13))
							Spacer()
						}
					}
				}
			}
			.padding(KKPaddingMD)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear { buildRows() }
	}

	private func buildRows() {
		let store = TranscriptionStore.shared
		var result: [Row] = []
		var nextID = 0

		for idx in model.audioClips.indices {
			guard let words = store.words(for: model.audioClips[idx])
			else { continue }

			let clip = model.audioClips[idx]
			result.append(
				Row(id: nextID, clipName: clip.name, text: "", timestamp: "", isHeader: true))
			nextID += 1

			let sentences = groupIntoSentences(words)
			for sentence in sentences {
				let text = sentence.map { $0.word.trimmingCharacters(in: .whitespaces) }
					.joined(separator: " ")
				result.append(
					Row(
						id: nextID,
						clipName: clip.name,
						text: text,
						timestamp: formatTimestamp(sentence.first!.start),
						isHeader: false
					))
				nextID += 1
			}
		}
		rows = result
	}

	private static let sentenceEndChars = CharacterSet(charactersIn: ".!?")
	private static let pauseThreshold: Float = 0.7

	private func groupIntoSentences(
		_ words: [TranscriptionStore.StoredWord]
	) -> [[TranscriptionStore.StoredWord]] {
		guard !words.isEmpty else { return [] }

		var sentences: [[TranscriptionStore.StoredWord]] = []
		var current: [TranscriptionStore.StoredWord] = []

		for word in words {
			if let prev = current.last,
				word.start - prev.end > Self.pauseThreshold
			{
				sentences.append(current)
				current = []
			}

			current.append(word)

			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			if trimmed.unicodeScalars.last.map({ Self.sentenceEndChars.contains($0) }) == true {
				sentences.append(current)
				current = []
			}
		}

		if !current.isEmpty {
			sentences.append(current)
		}

		return sentences
	}

	private func formatTimestamp(_ time: Float) -> String {
		if let format = model.projectFormat {
			return format.timecode(for: Double(time))
		}
		let s = Int(time) % 60
		let m = Int(time) / 60
		let ms = Int((time - Float(Int(time))) * 100)
		return String(format: "%d:%02d.%02d", m, s, ms)
	}
}
