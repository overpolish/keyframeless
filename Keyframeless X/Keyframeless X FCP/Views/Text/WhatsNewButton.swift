/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

/// Icon-only button that opens the release-notes page. Always available (unlike the
/// update banner, which only shows when behind), so users can check what's new and
/// which version is current at any time.
struct WhatsNewButton: View {
	let url: URL?

	var body: some View {
		if let url {
			Button {
				NSWorkspace.shared.open(url)
			} label: {
				Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
					.font(.system(size: 13))
			}
			.buttonStyle(.borderless)
			.foregroundStyle(.secondary)
			.help("What's New")
		}
	}
}
