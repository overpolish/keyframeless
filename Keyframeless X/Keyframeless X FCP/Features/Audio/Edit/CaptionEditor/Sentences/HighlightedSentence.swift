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
	var captionBreaks: Set<Int> = []
	var onToggleBreak: ((Int) -> Void)? = nil

	private var displayWords: [TranscriptionStore.StoredWord] {
		editedWords ?? words
	}

	var body: some View {
		HighlightedSentenceTextView(
			words: displayWords,
			currentTime: currentTime,
			language: language,
			captionBreaks: captionBreaks,
			onToggleBreak: onToggleBreak
		)
	}
}

private class SentenceDisplayView: NSTextView {
	var wordRanges: [(wordIndex: Int, range: NSRange)] = []
	var onToggleBreak: ((Int) -> Void)?

	override var intrinsicContentSize: NSSize {
		guard let container = textContainer, let layoutManager else {
			return super.intrinsicContentSize
		}
		layoutManager.ensureLayout(for: container)
		let rect = layoutManager.usedRect(for: container)
		return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height))
	}

	override func layout() {
		super.layout()
		invalidateIntrinsicContentSize()
	}

	override func rightMouseDown(with event: NSEvent) {
		guard let onToggleBreak else {
			super.rightMouseDown(with: event)
			return
		}
		let point = convert(event.locationInWindow, from: nil)
		let charIndex = characterIndexForInsertion(at: point)
		for (wordIndex, range) in wordRanges {
			if charIndex >= range.location && charIndex < range.location + range.length {
				onToggleBreak(wordIndex)
				return
			}
		}
	}

	override func menu(for event: NSEvent) -> NSMenu? { nil }
}

private struct HighlightedSentenceTextView: NSViewRepresentable {
	let words: [TranscriptionStore.StoredWord]
	let currentTime: Double?
	let language: String?
	let captionBreaks: Set<Int>
	let onToggleBreak: ((Int) -> Void)?

	func makeNSView(context: Context) -> SentenceDisplayView {
		let textView = SentenceDisplayView()
		textView.isEditable = false
		textView.isSelectable = false
		textView.drawsBackground = false
		textView.textContainerInset = .zero
		textView.textContainer?.lineFragmentPadding = 0
		textView.textContainer?.widthTracksTextView = true
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.onToggleBreak = onToggleBreak
		applyAttributedString(to: textView)
		return textView
	}

	func updateNSView(_ textView: SentenceDisplayView, context: Context) {
		textView.onToggleBreak = onToggleBreak
		applyAttributedString(to: textView)
		textView.invalidateIntrinsicContentSize()
	}

	private func applyAttributedString(to textView: SentenceDisplayView) {
		let result = NSMutableAttributedString()
		let font = NSFont.systemFont(ofSize: 13)
		let defaultAttrs: [NSAttributedString.Key: Any] = [
			.font: font,
			.foregroundColor: NSColor.labelColor,
		]
		var wordRanges: [(wordIndex: Int, range: NSRange)] = []

		for (i, word) in words.enumerated() {
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			let hitStart = result.length

			if i > 0 && captionBreaks.contains(i) {
				let marker = NSAttributedString(
					string: " | ",
					attributes: [
						.font: font,
						.foregroundColor: NSColor.controlAccentColor,
					])
				result.append(marker)
			} else if i > 0 {
				result.append(NSAttributedString(string: " ", attributes: defaultAttrs))
			}

			let wordStart = result.length

			if let currentTime {
				let (core, trailing) = splitPunctuation(trimmed)
				let isActive =
					currentTime >= Double(word.start) && currentTime < Double(word.end)
				let isProfane = ProfanityFilter.isProfane(trimmed, language: language)

				var coreAttrs = defaultAttrs
				if isProfane {
					if isActive {
						coreAttrs[.backgroundColor] = NSColor.error()
					} else {
						coreAttrs[.foregroundColor] = NSColor.error()
					}
				} else if isActive {
					coreAttrs[.backgroundColor] = NSColor.controlAccentColor
				}
				result.append(NSAttributedString(string: core, attributes: coreAttrs))
				if !trailing.isEmpty {
					result.append(NSAttributedString(string: trailing, attributes: defaultAttrs))
				}
			} else {
				var attrs = defaultAttrs
				if ProfanityFilter.isProfane(trimmed, language: language) {
					attrs[.foregroundColor] = NSColor.error()
				}
				result.append(NSAttributedString(string: trimmed, attributes: attrs))
			}

			let wordEnd = result.length
			let rangeStart = i == 0 ? wordStart : hitStart
			wordRanges.append(
				(wordIndex: i, range: NSRange(location: rangeStart, length: wordEnd - rangeStart)))
		}

		textView.wordRanges = wordRanges
		if textView.textStorage?.string != result.string
			|| textView.textStorage?.isEqual(to: result) == false
		{
			textView.textStorage?.setAttributedString(result)
		}
	}

	private func splitPunctuation(_ text: String) -> (word: String, trailing: String) {
		let reversed = String(text.reversed())
		let punctuation = reversed.prefix(while: { $0.isPunctuation })
		let word = String(text.dropLast(punctuation.count))
		return (word, String(punctuation.reversed()))
	}
}
