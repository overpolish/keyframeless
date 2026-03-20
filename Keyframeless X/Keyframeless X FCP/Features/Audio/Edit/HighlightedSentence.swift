/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct HighlightedSentence: View {
	let words: [TranscriptionStore.StoredWord]
	var editedText: String?
	let currentTime: Double?

	var body: some View {
		if let currentTime {
			Text(attributedString(currentTime: currentTime))
				.font(.system(size: 13))
		} else if let editedText {
			Text(editedText)
				.font(.system(size: 13))
				.foregroundStyle(.primary)
		} else {
			Text(plainText)
				.font(.system(size: 13))
		}
	}

	private var plainText: String {
		words.map { $0.word.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
	}

	private static let highlightDelay: Double = 0.3

	private func attributedString(currentTime: Double) -> AttributedString {
		let adjusted = currentTime - Self.highlightDelay
		var result = AttributedString()
		for (i, word) in words.enumerated() {
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			var part = AttributedString(i > 0 ? " \(trimmed)" : trimmed)
			let isActive = adjusted >= Double(word.start) && adjusted < Double(word.end)
			if isActive {
				part.foregroundColor = Color(nsColor: .accent())
				part.font = .system(size: 13, weight: .semibold)
			}
			result.append(part)
		}
		return result
	}
}
