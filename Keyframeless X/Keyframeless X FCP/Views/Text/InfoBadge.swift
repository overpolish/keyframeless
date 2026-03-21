/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct InfoBadge: View {
	let label: String
	var systemImage: String? = nil
	var color: Color = .secondary
	var monospaced: Bool = false

	var body: some View {
		HStack(spacing: 3) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: 8))
			}
			Text(label)
				.font(
					monospaced
						? .system(size: 10).monospacedDigit()
						: .system(size: 9, weight: .medium)
				)
		}
		.foregroundStyle(color)
		.padding(.horizontal, KKPaddingSM + 1)
		.padding(.vertical, KKSpacingXS)
		.background(Capsule().fill(color.opacity(0.15)))
	}
}
