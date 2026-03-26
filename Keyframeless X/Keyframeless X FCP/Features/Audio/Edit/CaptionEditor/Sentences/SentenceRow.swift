/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct SentenceRow: View {
	let row: AudioEditRow
	let clip: FCPXMLParser.AudioClip
	@ObservedObject var player: AudioPlayer
	@Binding var editingRowID: Int?
	var sentenceRowIDs: [Int] = []
	var onEdit: (String) -> Void = { _ in }
	var onReset: (() -> Void)?

	@State private var draft = ""

	private var isEditing: Bool { editingRowID == row.id }

	private var draftText: String {
		row.editedWords.map {
			$0.map { $0.word.trimmingCharacters(in: .whitespaces) }
				.joined(separator: " ")
		} ?? row.text
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
				currentTime: player.isPlaying(index: row.id)
					? player.currentTime : nil,
				language: AudioSetupSettings.shared.selectedLanguage
			)
			.onTapGesture {
				draft = draftText
				editingRowID = row.id
			}
		}
	}

	private func saveEdit() {
		let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty || trimmed == row.text {
			onEdit(row.text)
		} else {
			onEdit(trimmed)
		}
	}

	private func navigateToSentence(offset: Int) {
		guard let currentIndex = sentenceRowIDs.firstIndex(of: row.id) else { return }
		let nextIndex = currentIndex + offset
		guard sentenceRowIDs.indices.contains(nextIndex) else { return }
		editingRowID = sentenceRowIDs[nextIndex]
	}
}

private class SentenceTextView: NSTextView {
	override var intrinsicContentSize: NSSize {
		guard let container = textContainer, let layoutManager else {
			return super.intrinsicContentSize
		}
		layoutManager.ensureLayout(for: container)
		let rect = layoutManager.usedRect(for: container)
		return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height))
	}

	override func didChangeText() {
		super.didChangeText()
		invalidateIntrinsicContentSize()
	}

	override func layout() {
		super.layout()
		invalidateIntrinsicContentSize()
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
		let accent = NSColor.controlAccentColor
		textView.insertionPointColor = accent
		textView.selectedTextAttributes = [
			.backgroundColor: accent.withAlphaComponent(0.3)
		]
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
			guard let textView = notification.object as? NSTextView else { return }
			parent.text = textView.string
		}

		func textDidEndEditing(_ notification: Notification) {
			if !handledByCommand {
				parent.onFocusLost()
			}
			handledByCommand = false
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
