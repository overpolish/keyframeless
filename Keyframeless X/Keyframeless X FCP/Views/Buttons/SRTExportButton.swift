/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct SRTExportButton: View {
	let hasOverlaps: Bool
	let action: () -> Void

	@State private var isHovered = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: KKSpacingSM) {
				Image(systemName: "doc.text")
					.font(.system(size: 11, weight: .medium))
				Text("SRT")
					.font(.system(size: 11, weight: .medium))
			}
			.foregroundStyle(
				hasOverlaps ? .secondary : Color(nsColor: .warning())
			)
			.padding(.horizontal, KKPaddingXL)
		}
		.buttonStyle(.plain)
		.frame(height: 40)
		.disabled(hasOverlaps)
		.opacity(hasOverlaps ? 0.6 : 1)
		.onHover { isHovered = $0 }
		.popover(isPresented: .constant(isHovered && hasOverlaps), arrowEdge: .top) {
			Text("SRT cannot have overlapping captions")
				.font(.system(size: 11))
				.padding(KKPaddingMD)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: 240)
				.background(PopoverBackgroundClearer())
		}
		.help(hasOverlaps ? "" : "Export SRT")
	}
}
