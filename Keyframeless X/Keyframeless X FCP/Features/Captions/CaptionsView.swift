/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionsView: View {
	@ObservedObject var model: CaptionsModel
	@State private var dropResult: String?
	@State private var isTargeted = false

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			Spacer()
			KKAlertRepresentable(
				text: "Hello from KKAlertView",
				icon: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil))
			KKSeparatorRepresentable(
				text: "Timer",
				icon: NSImage(systemSymbolName: "timer", accessibilityDescription: nil))
			Button("Insert Title") {
				model.insertTitle()
			}
			Text("Timeline: \(model.timelineDuration)")
				.font(.system(.body, design: .monospaced))
				.foregroundStyle(.secondary)

			ZStack {
				RoundedRectangle(cornerRadius: 8)
					.strokeBorder(
						isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
						style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
					)
				VStack(spacing: 6) {
					Image(systemName: "arrow.down.doc")
						.font(.title2)
						.foregroundStyle(.secondary)
					Text(dropResult ?? "Drop FCP clips here")
						.font(.caption)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				FCPDropZoneView { result in
					dropResult = result
					isTargeted = false
				}
			}
			.frame(maxWidth: .infinity)
			.frame(minHeight: 80)
			.padding(.horizontal, KKPaddingMD)

			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
