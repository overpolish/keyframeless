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
		let accent = Color(nsColor: .accent() ?? .blue)

		HStack(spacing: KKSpacingSM) {
			Text(selection.label)
			Spacer()
			Image(systemName: "chevron.up.chevron.down")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.frame(width: 80)
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKPaddingXS)
		.background(
			Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: KKRadiusMD)
		)
		.overlay(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
		)
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
					.background(
						RoundedRectangle(cornerRadius: KKRadiusMD)
							.fill(selection == rate ? accent.opacity(0.12) : Color.clear)
					)
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
