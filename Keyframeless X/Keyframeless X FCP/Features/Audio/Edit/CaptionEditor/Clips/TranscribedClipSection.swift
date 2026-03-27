/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct TranscribedClipGroup {
	let clipIndex: Int
	let clipName: String
	let isCompound: Bool
	let sentences: [AudioEditRow]
}

struct RowFrameKey: PreferenceKey {
	static var defaultValue: [Int: CGRect] = [:]
	static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
		value.merge(nextValue()) { $1 }
	}
}

struct TranscribedClipSection: View {
	let group: TranscribedClipGroup
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>
	@Binding var hoveredClipIndex: Int?
	@ObservedObject var player: AudioPlayer
	@Binding var editingRowID: Int?
	var sentenceRowIDs: [Int] = []
	var predictedBreaks: [Int: Set<Int>] = [:]
	var onSentenceEdit: (Int, [TranscriptionStore.StoredWord]?) -> Void = { _, _ in }
	var onBreakToggle: (Int, [Int]) -> Void = { _, _ in }
	@State private var isHovered = false

	private var groupContainsProfanity: Bool {
		let language = AudioSetupSettings.shared.selectedLanguage
		return group.sentences.contains { row in
			let words = row.editedWords ?? row.words
			return words.contains {
				ProfanityFilter.isProfane(
					$0.word.trimmingCharacters(in: .whitespaces), language: language)
			}
		}
	}

	private var clipColor: Color { .kkClipColor(isCompound: group.isCompound) }

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingXS) {
			TranscribedClipHeader(
				clipName: group.clipName,
				clipIndex: group.clipIndex,
				isCompound: group.isCompound,
				containsProfanity: groupContainsProfanity,
				selectedClips: $selectedClips
			)

			ForEach(group.sentences) { row in
				SentenceRow(
					row: row,
					clip: clips[row.clipIndex],
					player: player,
					editingRowID: $editingRowID,
					sentenceRowIDs: sentenceRowIDs,
					captionBreaks: Set(row.captionBreaks),
					predictedBreaks: predictedBreaks[row.id] ?? [],
					onToggleBreak: { wordIndex in
						guard wordIndex > 0 else { return }
						let clip = clips[row.clipIndex]
						TranscriptionStore.shared.toggleCaptionBreak(
							at: wordIndex, for: clip,
							sentenceStart: Float(row.sentenceStart))
						let updated =
							TranscriptionStore.shared.captionBreakIndices(
								for: clip, sentenceStart: Float(row.sentenceStart)) ?? []
						onBreakToggle(row.id, updated)
					},
					onEdit: { newText in
						let clip = clips[row.clipIndex]
						let store = TranscriptionStore.shared
						let editedWords: [TranscriptionStore.StoredWord]?
						if newText == row.text {
							editedWords = nil
							store.setEditedWords(
								nil, for: clip, sentenceStart: Float(row.sentenceStart))
						} else {
							editedWords = TranscriptionStore.alignWords(
								original: row.words, editedText: newText)
							store.setEditedWords(
								editedWords, for: clip, sentenceStart: Float(row.sentenceStart))
						}
						onSentenceEdit(row.id, editedWords)
					},
					onBreaksEdited: { newBreaks in
						let clip = clips[row.clipIndex]
						TranscriptionStore.shared.setCaptionBreakIndices(
							newBreaks.isEmpty ? nil : newBreaks,
							for: clip, sentenceStart: Float(row.sentenceStart))
						onBreakToggle(row.id, newBreaks)
					},
					onReset: row.editedWords != nil
						? {
							let clip = clips[row.clipIndex]
							TranscriptionStore.shared.setEditedWords(
								nil, for: clip, sentenceStart: Float(row.sentenceStart))
							onSentenceEdit(row.id, nil)
						} : nil
				)
				.id(row.id)
				.background(
					GeometryReader { geo in
						Color.clear.preference(
							key: RowFrameKey.self,
							value: [row.id: geo.frame(in: .named("editScroll"))]
						)
					}
				)
			}
		}
		.padding(.top, KKPaddingMD)
		.padding(.horizontal, KKPaddingMD)
		.padding(.bottom, KKPaddingMD - 2)
		.background(
			RoundedRectangle(cornerRadius: CGFloat(KKRadiusMD))
				.fill(clipColor.opacity(isHovered ? 0.12 : 0))
		)
		.contentShape(Rectangle())
		.onHover { hovering in
			isHovered = hovering
			hoveredClipIndex = hovering ? group.clipIndex : nil
		}
	}
}
