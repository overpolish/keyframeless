/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct TranscribedClipHeader: View {
	let clipName: String
	let clipIndex: Int
	@Binding var selectedClips: Set<Int>

	var body: some View {
		HStack(spacing: KKSpacingMD) {
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
			.tint(Color(nsColor: .accent()))
		}
		.padding(.top, KKSpacingLG)
		.padding(.bottom, KKSpacingXS)
	}
}
