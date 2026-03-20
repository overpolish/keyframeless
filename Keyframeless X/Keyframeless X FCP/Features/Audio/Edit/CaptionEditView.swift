/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionEditView: View {
	@ObservedObject var model: CaptionsModel

	@State private var rows: [Row] = []

	struct Row: Identifiable {
		let id: Int
		let clipName: String
		let word: String
		let timestamp: String
		let isHeader: Bool
	}

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(rows) { row in
					if row.isHeader {
						Text(row.clipName)
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(.secondary)
							.padding(.top, KKSpacingLG)
							.padding(.bottom, KKSpacingXS)
					} else {
						HStack(spacing: KKSpacingMD) {
							Text(row.timestamp)
								.font(.system(size: 11).monospacedDigit())
								.foregroundStyle(.tertiary)
								.frame(width: 80, alignment: .trailing)
							Text(row.word)
								.font(.system(size: 13))
							Spacer()
						}
					}
				}
			}
			.padding(KKPaddingMD)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear { buildRows() }
	}

	private func buildRows() {
		let store = TranscriptionStore.shared
		var result: [Row] = []
		var nextID = 0

		for idx in model.audioClips.indices {
			guard let words = store.words(for: model.audioClips[idx])
			else { continue }

			let clip = model.audioClips[idx]
			result.append(
				Row(id: nextID, clipName: clip.name, word: "", timestamp: "", isHeader: true))
			nextID += 1

			for word in words {
				result.append(
					Row(
						id: nextID,
						clipName: clip.name,
						word: word.word.trimmingCharacters(in: .whitespaces),
						timestamp: formatTimestamp(word.start),
						isHeader: false
					))
				nextID += 1
			}
		}
		rows = result
	}

	private func formatTimestamp(_ time: Float) -> String {
		if let format = model.projectFormat {
			return format.timecode(for: Double(time))
		}
		let s = Int(time) % 60
		let m = Int(time) / 60
		let ms = Int((time - Float(Int(time))) * 100)
		return String(format: "%d:%02d.%02d", m, s, ms)
	}
}
