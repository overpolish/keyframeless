/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct TranscribedClipHeader: View {
	let clipName: String
	let clipIndex: Int
	let isCompound: Bool
	var containsProfanity: Bool = false
	@Binding var selectedClips: Set<Int>

	private var clipColor: Color { .kkClipColor(isCompound: isCompound) }

	var body: some View {
		HStack(spacing: KKSpacingLG) {
			Toggle(
				isOn: Binding(
					get: { selectedClips.contains(clipIndex) },
					set: { isOn in
						if isOn {
							selectedClips.insert(clipIndex)
						} else {
							selectedClips.remove(clipIndex)
						}
					}
				)
			) {
				Text(clipName)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.secondary)
			}
			.toggleStyle(.checkbox)
			.tint(clipColor)
			Spacer()
			if containsProfanity {
				InfoBadge(
					label: "Profanity",
					systemImage:
						"exclamationmark.bubble.fill",
					color: Color.kkError
				)
			}
		}
	}
}
