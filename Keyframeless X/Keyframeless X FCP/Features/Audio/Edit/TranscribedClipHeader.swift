/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct TranscribedClipHeader: View {
	let clipName: String
	let clipIndex: Int
	let isCompound: Bool
	@Binding var selectedClips: Set<Int>

	private var clipColor: Color {
		Color(nsColor: isCompound ? .warning() ?? .yellow : .accent() ?? .blue)
	}

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
		}
	}
}
