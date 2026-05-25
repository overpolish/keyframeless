/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

/// Icon-only button that opens the hosted feedback form, prefilled with this
/// component's plugin + version. Always available so users can report a bug or
/// raise an idea at any time.
struct FeedbackButton: View {
	let url: URL?

	var body: some View {
		if let url {
			Button {
				NSWorkspace.shared.open(url)
			} label: {
				Image(systemName: "exclamationmark.bubble")
					.font(.system(size: 13))
			}
			.buttonStyle(.borderless)
			.foregroundStyle(.secondary)
			.help("Send feedback")
		}
	}
}
