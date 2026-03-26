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
	@FocusState private var isFocused: Bool

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
			TextField("", text: $draft, axis: .vertical)
				.textFieldStyle(.plain)
				.font(.system(size: 13))
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.focused($isFocused)
				.onAppear { isFocused = true }
				.onKeyPress(phases: .down) { keyPress in
					switch keyPress.key {
					case .return:
						saveEdit()
						editingRowID = nil
						return .handled
					case .escape:
						saveEdit()
						editingRowID = nil
						return .handled
					case .tab:
						saveEdit()
						if keyPress.modifiers.contains(.shift) {
							navigateToSentence(offset: -1)
						} else {
							navigateToSentence(offset: 1)
						}
						return .handled
					default:
						return .ignored
					}
				}
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
