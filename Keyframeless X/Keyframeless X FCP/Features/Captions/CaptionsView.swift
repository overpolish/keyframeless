/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionsView: View {
	@ObservedObject var model: CaptionsModel

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
			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
