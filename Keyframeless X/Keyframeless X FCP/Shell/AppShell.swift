/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AppShell: View {
	@ObservedObject var captionsModel: CaptionsModel
	@State private var selectedTab: AppTab = .captions

	var body: some View {
		VStack(spacing: 0) {
			PillTabBar(selected: $selectedTab)
				.padding(.top, KKPaddingSM)
				.padding(.bottom, KKPaddingXL)

			Group {
				switch selectedTab {
				case .captions:
					CaptionsView(model: captionsModel)
				case .other:
					ComingSoonView()
				}
			}
			.padding([.leading, .trailing], KKSpacingXL)
			.padding(.bottom, KKSpacingXS)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(nsColor: .windowBackground()))
		.overlay(alignment: .topTrailing) {
			Image("keyframeless-logo")
				.resizable()
				.scaledToFit()
				.frame(width: 48)
				.opacity(0.15)
				.padding([.bottom, .trailing], KKSpacingXL)
		}
	}
}
