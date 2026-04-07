/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct FrameratePickerButton: View {
	@Binding var selection: Framerate
	@State private var isOpen = false

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(selection.label)
			Spacer()
			Image(systemName: "chevron.up.chevron.down")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.frame(width: 85)
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKPaddingXS)
		.kkPanel(cornerRadius: KKRadiusMD)
		.contentShape(Rectangle())
		.onTapGesture { isOpen.toggle() }
		.popover(isPresented: $isOpen, arrowEdge: .top) {
			VStack(spacing: 0) {
				ForEach(Framerate.allCases) { rate in
					HStack {
						Text(rate.label)
							.font(.system(size: 12))
						Spacer()
					}
					.padding(.horizontal, KKPaddingLG)
					.padding(.vertical, KKSpacingMD)
					.kkSelectableBackground(selection == rate)
					.contentShape(Rectangle())
					.onTapGesture {
						selection = rate
						isOpen = false
					}
				}
			}
			.padding(KKPaddingMD)
			.background(PopoverBackgroundClearer())
		}
	}
}
