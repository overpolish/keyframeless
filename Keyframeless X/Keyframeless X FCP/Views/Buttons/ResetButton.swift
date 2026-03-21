/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct ResetButton: View {
	var size: CGFloat = 12
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: "arrow.uturn.backward")
				.font(.system(size: size, weight: .semibold))
				.foregroundStyle(Color(nsColor: .warning()))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}
