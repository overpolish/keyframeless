/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
				hasOverlaps ? .secondary : Color.kkWarning
			)
			.padding(.horizontal, KKPaddingXL)
		}
		.buttonStyle(.plain)
		.disabled(hasOverlaps)
		.opacity(hasOverlaps ? 0.6 : 1)
		.onHover { isHovered = $0 }
		.popover(isPresented: .constant(isHovered && hasOverlaps), arrowEdge: .top) {
			Text("SRT cannot have overlapping captions")
				.font(.system(size: 11))
				.multilineTextAlignment(.center)
				.padding(KKPaddingLG)
				.background(PopoverBackgroundClearer())
		}
		.help(hasOverlaps ? "" : "Export SRT")
	}
}
