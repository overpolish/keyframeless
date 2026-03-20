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

struct TranscribedClipSection: View {
	let group: TranscribedClipGroup
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>
	@Binding var hoveredClipIndex: Int?
	@ObservedObject var player: AudioPlayer
	@Binding var editingRowID: Int?
	var sentenceRowIDs: [Int] = []
	var onSentenceEdit: (Int, String?) -> Void = { _, _ in }
	@State private var isHovered = false

	private var clipColor: Color {
		Color(nsColor: group.isCompound ? .warning() ?? .yellow : .accent() ?? .blue)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingXS) {
			TranscribedClipHeader(
				clipName: group.clipName,
				clipIndex: group.clipIndex,
				isCompound: group.isCompound,
				selectedClips: $selectedClips
			)

			ForEach(group.sentences) { row in
				SentenceRow(
					row: row,
					clip: clips[row.clipIndex],
					player: player,
					editingRowID: $editingRowID,
					sentenceRowIDs: sentenceRowIDs
				) { newText in
					let clip = clips[row.clipIndex]
					let store = TranscriptionStore.shared
					let editedText: String?
					if newText == row.text {
						editedText = nil
						store.setEditedText(nil, for: clip, sentenceStart: Float(row.sentenceStart))
					} else {
						editedText = newText
						store.setEditedText(
							newText, for: clip, sentenceStart: Float(row.sentenceStart))
					}
					onSentenceEdit(row.id, editedText)
				}
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
