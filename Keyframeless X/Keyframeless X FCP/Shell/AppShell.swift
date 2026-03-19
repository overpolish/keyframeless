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
		VStack(spacing: 0) {
			PillTabBar(selected: $selectedTab)
				.padding(.top, KKPaddingSM)
				.padding(.bottom, KKPaddingXL)

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
}
