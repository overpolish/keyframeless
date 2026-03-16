/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct PillTabBar: View {
	@Binding var selected: AppTab

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			ForEach(AppTab.allCases, id: \.self) { tab in
				PillTabItem(tab: tab, isSelected: selected == tab) {
					selected = tab
				}
			}
		}
		.padding(KKPaddingSM)
		.background(Capsule().fill(Color.white.opacity(0.08)))
	}
}

private struct PillTabItem: View {
	let tab: AppTab
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Label(tab.label, systemImage: tab.icon)
				.font(.system(size: 12, weight: .medium))
				.padding(.horizontal, KKPaddingLG)
				.padding(.vertical, KKSpacingMD)
				.background {
					if isSelected {
						Capsule().fill(Color(nsColor: .accent()))
					}
				}
				.foregroundStyle(isSelected ? .white : .secondary)
		}
		.buttonStyle(.plain)
		.disabled(!tab.isEnabled)
	}
}
