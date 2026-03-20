/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct TimestampBadge: View {
	let timestamp: String

	var body: some View {
		Text(timestamp)
			.font(.system(size: 10).monospacedDigit())
			.foregroundStyle(.secondary)
			.padding(.horizontal, KKPaddingSM)
			.padding(.vertical, KKSpacingXS)
			.background(
				Capsule().fill(Color.white.opacity(0.06))
			)
	}
}
