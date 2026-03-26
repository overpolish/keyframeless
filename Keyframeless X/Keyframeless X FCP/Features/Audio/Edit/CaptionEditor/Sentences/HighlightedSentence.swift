/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct HighlightedSentence: View {
	let words: [TranscriptionStore.StoredWord]
	var editedWords: [TranscriptionStore.StoredWord]?
	let currentTime: Double?
	var language: String? = nil

	private var displayWords: [TranscriptionStore.StoredWord] {
		editedWords ?? words
	}

	var body: some View {
		if let currentTime {
			Text(attributedString(currentTime: currentTime))
				.font(.system(size: 13))
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
		} else {
			Text(styledText)
				.font(.system(size: 13))
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var styledText: AttributedString {
		var result = AttributedString()
		for (i, word) in displayWords.enumerated() {
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			var part = AttributedString(i > 0 ? " \(trimmed)" : trimmed)
			if ProfanityFilter.isProfane(trimmed, language: language) {
				part.foregroundColor = Color.kkError
			}
			result.append(part)
		}
		return result
	}

	private func attributedString(currentTime: Double) -> AttributedString {
		var result = AttributedString()
		for (i, word) in displayWords.enumerated() {
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			var part = AttributedString(i > 0 ? " \(trimmed)" : trimmed)
			let isActive = currentTime >= Double(word.start) && currentTime < Double(word.end)
			if ProfanityFilter.isProfane(trimmed, language: language) {
				part.foregroundColor = Color.kkError
				if isActive {
					part.font = .system(size: 13)
				}
			} else if isActive {
				part.foregroundColor = Color.kkAccent
				part.font = .system(size: 13)
			}
			result.append(part)
		}
		return result
	}
}
