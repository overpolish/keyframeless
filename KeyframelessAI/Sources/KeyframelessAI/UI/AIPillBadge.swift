/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

/// Small filled-capsule badge. Mirrors Keyframeless X's `InfoBadge` (the style
/// used by the interactive guides and Steno's model picker) so badges look the
/// same everywhere. This package can't depend on KeyframelessKit, so the token
/// values are inlined.
struct AIPillBadge: View {
	let label: String
	var systemImage: String? = nil
	var color: Color = .secondary

	var body: some View {
		HStack(spacing: 3) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: 8))
			}
			Text(label)
				.font(.system(size: 9, weight: .medium))
				.lineLimit(1)
		}
		.foregroundStyle(color)
		.padding(.horizontal, 5)
		.padding(.vertical, 2)
		.background(Capsule().fill(color.opacity(0.15)))
		.fixedSize()
	}
}
