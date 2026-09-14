/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
				.foregroundStyle(Color.kkWarning)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}
