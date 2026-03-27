/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import KeyframelessKit
import SwiftUI

struct SentenceRow: View {
	let row: AudioEditRow
	let clip: FCPXMLParser.AudioClip
	@ObservedObject var player: AudioPlayer
	@Binding var editingRowID: Int?
	var sentenceRowIDs: [Int] = []
	var captionBreaks: Set<Int> = []
	var predictedBreaks: Set<Int> = []
	var onToggleBreak: ((Int) -> Void)? = nil
	var onEdit: (String) -> Void = { _ in }
	var onBreaksEdited: ([Int]) -> Void = { _ in }
	var onReset: (() -> Void)?
	var showTrailingBreak: Bool = false

	@State private var draft = ""
	@State private var highlightTime: Double?

	private var isEditing: Bool { editingRowID == row.id }

	private var draftText: String {
		let words =
			(row.editedWords ?? row.words).map {
				$0.word.trimmingCharacters(in: .whitespaces)
			}
		var tokens: [String] = []
		for (i, word) in words.enumerated() {
			if captionBreaks.contains(i) && i > 0 {
				tokens.append("|")
			}
			tokens.append(word)
		}
		return tokens.joined(separator: " ")
	}

	var body: some View {
		HStack(alignment: .top, spacing: KKSpacingMD) {
			InfoBadge(label: row.timestamp, monospaced: true)
			sentenceContent
			Spacer()
			if row.editedWords != nil, let onReset {
				ResetButton { onReset() }
			}
			PlayButton(
				isPlaying: player.isPlaying(index: row.id)
			) {
				player.toggleRange(
					clip: clip,
					index: row.id,
					from: row.sentenceStart,
					to: row.sentenceEnd
				)
			}
		}
		.padding(.vertical, KKPaddingXS)
		.onChange(of: editingRowID) {
			if editingRowID == row.id {
				draft = draftText
			}
		}
		.onReceive(player.currentTimeSubject) { time in
			let newTime = player.isPlaying(index: row.id) ? time : nil
			if newTime != highlightTime { highlightTime = newTime }
		}
	}

	@ViewBuilder
	private var sentenceContent: some View {
		if isEditing {
			SentenceTextField(
				text: $draft,
				onCommit: {
					saveEdit()
					editingRowID = nil
				},
				onTab: {
					saveEdit()
					navigateToSentence(offset: 1)
				},
				onBackTab: {
					saveEdit()
					navigateToSentence(offset: -1)
				},
				onFocusLost: {
					saveEdit()
					editingRowID = nil
				}
			)
		} else {
			HighlightedSentence(
				words: row.words,
				editedWords: row.editedWords,
				currentTime: highlightTime,
				language: AudioSetupSettings.shared.selectedLanguage,
				captionBreaks: captionBreaks,
				predictedBreaks: predictedBreaks,
				onToggleBreak: onToggleBreak,
				showTrailingBreak: showTrailingBreak,
				onTap: {
					draft = draftText
					editingRowID = row.id
				}
			)
		}
	}

	private func saveEdit() {
		let tokens = draft.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
		var cleanTokens: [String] = []
		var newBreaks: [Int] = []
		for token in tokens {
			if token == "|" {
				newBreaks.append(cleanTokens.count)
			} else {
				cleanTokens.append(token)
			}
		}
		let cleanText = cleanTokens.joined(separator: " ")
		if cleanText.isEmpty || cleanText == row.text {
			onEdit(row.text)
		} else {
			onEdit(cleanText)
		}
		onBreaksEdited(newBreaks)
	}

	private func navigateToSentence(offset: Int) {
		guard let currentIndex = sentenceRowIDs.firstIndex(of: row.id) else { return }
		let nextIndex = currentIndex + offset
		guard sentenceRowIDs.indices.contains(nextIndex) else { return }
		editingRowID = sentenceRowIDs[nextIndex]
	}
}

private class SentenceTextView: AutoSizingTextView {
	var onResignFirstResponder: (() -> Void)?

	override func resignFirstResponder() -> Bool {
		let result = super.resignFirstResponder()
		if result { onResignFirstResponder?() }
		return result
	}

	override func didChangeText() {
		super.didChangeText()
		colorPipeCharacters()
	}

	func colorPipeCharacters() {
		guard let storage = textStorage else { return }
		let text = storage.string
		let defaultColor = NSColor.labelColor
		let accentColor = NSColor.controlAccentColor
		storage.beginEditing()
		storage.addAttribute(
			.foregroundColor, value: defaultColor,
			range: NSRange(location: 0, length: storage.length))
		for (i, char) in text.enumerated() where char == "|" {
			storage.addAttribute(
				.foregroundColor, value: accentColor,
				range: NSRange(location: i, length: 1))
		}
		storage.endEditing()
	}
}

private struct SentenceTextField: NSViewRepresentable {
	@Binding var text: String
	var onCommit: () -> Void
	var onTab: () -> Void
	var onBackTab: () -> Void
	var onFocusLost: () -> Void = {}

	func makeNSView(context: Context) -> SentenceTextView {
		let textView = SentenceTextView()
		textView.font = .systemFont(ofSize: 13)
		textView.textContainerInset = .zero
		textView.textContainer?.lineFragmentPadding = 0
		textView.textContainer?.widthTracksTextView = true
		textView.isRichText = false
		textView.drawsBackground = false
		textView.isEditable = true
		textView.isSelectable = true
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.string = text
		textView.delegate = context.coordinator
		let coordinator = context.coordinator
		textView.onResignFirstResponder = { [weak coordinator] in
			guard let coordinator, !coordinator.handledByCommand else { return }
			coordinator.parent.onFocusLost()
		}
		let accent = NSColor.controlAccentColor
		textView.insertionPointColor = accent
		textView.selectedTextAttributes = [
			.backgroundColor: accent.withAlphaComponent(0.3)
		]
		textView.colorPipeCharacters()
		DispatchQueue.main.async {
			textView.window?.makeFirstResponder(textView)
			let windowPoint = textView.window?.mouseLocationOutsideOfEventStream ?? .zero
			let viewPoint = textView.convert(windowPoint, from: nil)
			let index = textView.characterIndexForInsertion(at: viewPoint)
			textView.setSelectedRange(NSRange(location: index, length: 0))
		}
		return textView
	}

	func updateNSView(_ textView: SentenceTextView, context: Context) {
		if textView.string != text {
			textView.string = text
			textView.colorPipeCharacters()
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	class Coordinator: NSObject, NSTextViewDelegate {
		var parent: SentenceTextField
		var handledByCommand = false

		init(_ parent: SentenceTextField) {
			self.parent = parent
		}

		func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? SentenceTextView else { return }
			parent.text = textView.string
		}

		func textView(
			_ textView: NSTextView, doCommandBy commandSelector: Selector
		) -> Bool {
			if commandSelector == #selector(NSResponder.insertNewline(_:))
				|| commandSelector == #selector(NSResponder.cancelOperation(_:))
			{
				handledByCommand = true
				parent.onCommit()
				return true
			}
			if commandSelector == #selector(NSResponder.insertTab(_:)) {
				handledByCommand = true
				parent.onTab()
				return true
			}
			if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
				handledByCommand = true
				parent.onBackTab()
				return true
			}
			return false
		}
	}
}
