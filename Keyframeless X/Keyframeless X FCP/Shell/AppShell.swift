/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AppShell: View {
	@ObservedObject var captionsModel: CaptionsModel
	@State private var selectedTab: AppTab = .audio
	@State private var isProcessing = false
	@State private var processProgress: Double = 0

	var body: some View {
		VStack(spacing: KKSpacingMD) {
			topBar
			Group {
				switch selectedTab {
				case .audio:
					switch captionsModel.stage {
					case .setup:
						AudioSetupView(
							model: captionsModel,
							isProcessing: $isProcessing
						)
					case .captioning:
						Text("Edit view")
						Spacer()
					}
				}
			}
		}
		.padding([.horizontal, .bottom], KKPadding2XL)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(nsColor: .windowBackground()))
		.overlay {
			if isProcessing {
				ProcessingOverlay(
					progress: processProgress,
					onCancel: {
						withAnimation(.easeOut(duration: 0.25)) {
							isProcessing = false
						}
					}
				)
				.transition(.opacity)
			}
		}
	}

	private var topBar: some View {
		HStack {
			PillTabBar(selected: $selectedTab)
			Spacer()
			toolNav
		}
		.overlay {
			Image("keyframeless-logo")
				.resizable()
				.scaledToFit()
				.frame(width: 36)
				.opacity(0.15)
		}
	}

	@ViewBuilder
	private var toolNav: some View {
		switch selectedTab {
		case .audio:
			PillIconToggle<CaptionsModel.Stage>(
				selection: $captionsModel.stage,
				options: [
					(
						label: "Setup", systemImage: "sparkles.rectangle.stack.fill",
						value: .setup
					),
					(label: "Edit", systemImage: "bubble.and.pencil", value: .captioning),
				]
			)
		}
	}
}
