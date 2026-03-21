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
		} else {
			Text(styledText)
				.font(.system(size: 13))
		}
	}

	private var styledText: AttributedString {
		var result = AttributedString()
		for (i, word) in displayWords.enumerated() {
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			var part = AttributedString(i > 0 ? " \(trimmed)" : trimmed)
			if ProfanityFilter.isProfane(trimmed, language: language) {
				part.foregroundColor = Color(nsColor: .error())
			}
			result.append(part)
		}
		return result
	}

	private static let highlightDelay: Double = 0.3

	private func attributedString(currentTime: Double) -> AttributedString {
		let adjusted = currentTime - Self.highlightDelay
		var result = AttributedString()
		for (i, word) in displayWords.enumerated() {
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			var part = AttributedString(i > 0 ? " \(trimmed)" : trimmed)
			let isActive = adjusted >= Double(word.start) && adjusted < Double(word.end)
			if ProfanityFilter.isProfane(trimmed, language: language) {
				part.foregroundColor = Color(nsColor: .error())
				if isActive {
					part.font = .system(size: 13, weight: .semibold)
				}
			} else if isActive {
				part.foregroundColor = Color(nsColor: .accent())
				part.font = .system(size: 13, weight: .semibold)
			}
			result.append(part)
		}
		return result
	}
}
