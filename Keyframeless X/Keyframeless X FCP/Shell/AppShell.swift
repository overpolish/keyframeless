/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

private let windowBg = Color(nsColor: .init(white: 0x27 / 255, alpha: 1))

struct AppShell: View {
	@ObservedObject var captionsModel: CaptionsModel
	@State private var selectedTab: AppTab = .captions

	var body: some View {
		VStack(spacing: 0) {
			PillTabBar(selected: $selectedTab)
				.padding(.top, KKPaddingSM)
				.padding(.bottom, KKPaddingXL)

			switch selectedTab {
			case .captions:
				CaptionsView(model: captionsModel)
			case .other:
				ComingSoonView()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(windowBg)
		.overlay(alignment: .bottomTrailing) {
			Image("keyframeless-logo")
				.resizable()
				.scaledToFit()
				.frame(width: 48)
				.opacity(0.15)
				.padding(KKSpacingXL)
		}
	}
}
