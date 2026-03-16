/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import SwiftUI

struct ContentView: View {
	@ObservedObject var model: FCPModel

	var body: some View {
		TabView {
			Tab("Captions", systemImage: "globe") {
				CaptionsView(model: model)
			}
			Tab("Other", systemImage: "sparkles") {
				ComingSoonView()
			}
			.disabled(true)
		}
		.tabViewStyle(.sidebarAdaptable)
		.toolbar(removing: .title)
	}
}

struct CaptionsView: View {
	@ObservedObject var model: FCPModel

	var body: some View {
		VStack(spacing: 8) {
			Spacer()
			Button("Insert Title") {
				model.insertTitle()
			}
			Text("Timeline: \(model.timelineDuration)")
				.font(.system(.body, design: .monospaced))
				.foregroundStyle(.secondary)
			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.overlay(alignment: .bottomTrailing) {
			Image("keyframeless-logo")
				.resizable()
				.scaledToFit()
				.frame(width: 48)
				.opacity(0.15)
				.padding(12)
		}
		.background(Color(nsColor: .init(white: 0x27 / 255, alpha: 1)))
	}
}

struct ComingSoonView: View {
	var body: some View {
		ContentUnavailableView("Coming Soon", systemImage: "sparkles")
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Color(nsColor: .init(white: 0x27 / 255, alpha: 1)))
	}
}
