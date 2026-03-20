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

	@State private var draft = ""

	private var isEditing: Bool { editingRowID == row.id }

	var body: some View {
		HStack(alignment: .top, spacing: KKSpacingMD) {
			TimestampBadge(timestamp: row.timestamp)
			sentenceContent
			Spacer()
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
				draft =
					row.editedWords.map {
						$0.map { $0.word.trimmingCharacters(in: .whitespaces) }
							.joined(separator: " ")
					} ?? row.text
			}
		}
	}

	@ViewBuilder
	private var sentenceContent: some View {
		if isEditing {
			SentenceTextField(
				draft: $draft,
				onCommit: {
					saveEdit()
					editingRowID = nil
				},
				onTab: {
					saveEdit()
					navigateToSentence(offset: 1)
				},
				onShiftTab: {
					saveEdit()
					navigateToSentence(offset: -1)
				})
		} else {
			HighlightedSentence(
				words: row.words,
				editedWords: row.editedWords,
				currentTime: player.isPlaying(index: row.id)
					? player.currentTime : nil
			)
			.onTapGesture {
				draft =
					row.editedWords.map {
						$0.map { $0.word.trimmingCharacters(in: .whitespaces) }
							.joined(separator: " ")
					} ?? row.text
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

struct SentenceTextField: NSViewRepresentable {
	@Binding var draft: String
	var onCommit: () -> Void
	var onTab: () -> Void = {}
	var onShiftTab: () -> Void = {}

	func makeNSView(context: Context) -> NSTextField {
		let field = NSTextField()
		field.isBordered = false
		field.drawsBackground = false
		field.font = .systemFont(ofSize: 13)
		field.focusRingType = .none
		field.lineBreakMode = .byWordWrapping
		field.cell?.wraps = true
		field.cell?.isScrollable = false
		field.maximumNumberOfLines = 0
		field.delegate = context.coordinator
		field.stringValue = draft
		DispatchQueue.main.async {
			field.window?.makeFirstResponder(field)
		}
		return field
	}

	func updateNSView(_ nsView: NSTextField, context: Context) {
		if nsView.stringValue != draft {
			nsView.stringValue = draft
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: SentenceTextField

		init(_ parent: SentenceTextField) {
			self.parent = parent
		}

		func controlTextDidChange(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			parent.draft = field.stringValue
		}

		func controlTextDidEndEditing(_ obj: Notification) {
			let movement =
				obj.userInfo?["NSTextMovement"] as? Int ?? NSOtherTextMovement
			switch movement {
			case NSTabTextMovement:
				parent.onTab()
			case NSBacktabTextMovement:
				parent.onShiftTab()
			default:
				parent.onCommit()
			}
		}

		func control(
			_ control: NSControl, textView: NSTextView,
			doCommandBy commandSelector: Selector
		) -> Bool {
			if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
				parent.onCommit()
				return true
			}
			return false
		}
	}
}
