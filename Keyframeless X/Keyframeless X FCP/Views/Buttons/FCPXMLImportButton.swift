/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct FCPXMLImportButton: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: KKSpacingSM) {
				Image(systemName: "square.and.arrow.down")
					.font(.system(size: 11, weight: .medium))
				Text("Import")
					.font(.system(size: 11, weight: .medium))
			}
			.foregroundStyle(Color.accentColor)
			.padding(.horizontal, KKPaddingXL)
		}
		.buttonStyle(.plain)
		.help("Import FCPXML into FCP")
	}
}
