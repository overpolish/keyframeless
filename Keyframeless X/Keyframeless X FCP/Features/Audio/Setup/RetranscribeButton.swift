/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct RetranscribeButton: View {
	let disabled: Bool
	var action: () -> Void = {}
	@State private var showInfo = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: KKSpacingSM) {
				Image(systemName: "arrow.trianglehead.2.counterclockwise")
				Text("Retranscribe Selected")
					.font(.system(size: 13, weight: .medium))
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, KKSpacingMD)
		}
		.buttonStyle(.bordered)
		.disabled(disabled)
		.overlay(alignment: .bottomTrailing) {
			Image(systemName: "info.circle")
				.font(.system(size: 10))
				.padding(.trailing, KKPaddingSM)
				.padding(.bottom, KKPaddingMD)
				.onHover { showInfo = $0 }
				.popover(isPresented: $showInfo, arrowEdge: .bottom) {
					Text("Mix and match models by retranscribing only the selected clips.")
						.font(.system(size: 11))
						.padding(KKPaddingSM)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: 240)
				}
		}
	}
}
