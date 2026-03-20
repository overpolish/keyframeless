/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct SentenceRow: View {
	let row: AudioEditRow
	let clip: FCPXMLParser.AudioClip
	let isHovered: Bool
	@ObservedObject var player: AudioPlayer
	@Binding var hoveredClipIndex: Int?

	var body: some View {
		HStack(alignment: .top, spacing: KKSpacingMD) {
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
			Text(row.timestamp)
				.font(.system(size: 11).monospacedDigit())
				.foregroundStyle(.tertiary)
				.frame(width: 80, alignment: .trailing)
			HighlightedSentence(
				words: row.words,
				currentTime: player.isPlaying(index: row.id)
					? player.currentTime : nil
			)
			Spacer()
		}
		.padding(.vertical, KKPaddingXS)
		.padding(.horizontal, KKPaddingSM)
		.background(
			RoundedRectangle(cornerRadius: CGFloat(KKRadiusSM))
				.fill(
					Color(nsColor: .hover()).opacity(
						isHovered && !player.isPlaying(index: row.id)
							? 1 : 0
					))
		)
		.onHover { hovering in
			hoveredClipIndex = hovering ? row.clipIndex : nil
		}
	}
}
