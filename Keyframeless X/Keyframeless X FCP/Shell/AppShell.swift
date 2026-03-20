/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AppShell: View {
	@ObservedObject var captionsModel: CaptionsModel
	@State private var selectedTab: AppTab = .captions
	@State private var isTranscribing = false
	@State private var transcribeProgress: Double = 0

	var body: some View {
		VStack(spacing: KKSpacingMD) {
			topBar
			Group {
				switch selectedTab {
				case .captions:
					CaptionsView(
						model: captionsModel,
						isTranscribing: $isTranscribing
					)
				case .other:
					ComingSoonView()
				}
			}
		}
		.padding([.horizontal, .bottom], KKPadding2XL)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(nsColor: .windowBackground()))
		.overlay {
			if isTranscribing {
				TranscribingOverlay(
					progress: transcribeProgress,
					onCancel: {
						withAnimation(.easeOut(duration: 0.25)) {
							isTranscribing = false
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
		case .captions:
			PillIconToggle<CaptionsModel.Stage>(
				selection: $captionsModel.stage,
				options: [
					(
						label: "Transcription", systemImage: "sparkles.rectangle.stack.fill",
						value: .transcription
					),
					(label: "Captioning", systemImage: "bubble.fill", value: .captioning),
				]
			)
		case .other:
			EmptyView()
		}
	}
}
