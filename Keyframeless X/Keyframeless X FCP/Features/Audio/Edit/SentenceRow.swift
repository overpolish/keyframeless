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

	var body: some View {
		HStack(alignment: .top, spacing: KKSpacingMD) {
			TimestampBadge(timestamp: row.timestamp)
			HighlightedSentence(
				words: row.words,
				currentTime: player.isPlaying(index: row.id)
					? player.currentTime : nil
			)
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
	}
}
