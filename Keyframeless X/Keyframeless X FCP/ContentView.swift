/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

private let windowBg = Color(nsColor: .init(white: 0x27 / 255, alpha: 1))

private enum AppTab: CaseIterable {
	case captions
	case other

	var label: String {
		switch self {
		case .captions: "Captions"
		case .other: "Other"
		}
	}

	var icon: String {
		switch self {
		case .captions: "globe"
		case .other: "sparkles"
		}
	}

	var isEnabled: Bool {
		switch self {
		case .captions: true
		case .other: false
		}
	}
}

struct ContentView: View {
	@ObservedObject var model: FCPModel
	@State private var selectedTab: AppTab = .captions

	var body: some View {
		VStack(spacing: 0) {
			PillTabBar(selected: $selectedTab)
				.padding(.top, KKPaddingSM)
				.padding(.bottom, KKPaddingXL)

			switch selectedTab {
			case .captions:
				CaptionsView(model: model)
			case .other:
				ComingSoonView()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(windowBg)
	}
}

private struct PillTabBar: View {
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

private struct KKSeparatorViewRepresentable: NSViewRepresentable {
	var text: String? = nil
	var icon: NSBezierPath? = nil

	func makeNSView(context: Context) -> KKSeparatorView {
		KKSeparatorView(text: text, icon: icon)
	}

	func updateNSView(_ nsView: KKSeparatorView, context: Context) {
		nsView.text = text
		nsView.icon = icon
	}
}

private struct KKAlertViewRepresentable: NSViewRepresentable {
	let text: String
	var icon: NSBezierPath? = nil

	func makeNSView(context: Context) -> KKAlertView {
		KKAlertView(text: text)
	}

	func updateNSView(_ nsView: KKAlertView, context: Context) {
		nsView.text = text
		nsView.icon = icon
	}
}

struct CaptionsView: View {
	@ObservedObject var model: FCPModel

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			Spacer()
			KKAlertViewRepresentable(
				text: "Hello from KKAlertView", icon: KKIcons.info())
			KKSeparatorViewRepresentable(text: "Timer", icon: KKIcons.timer())
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
				.padding(KKSpacingXL)
		}
	}
}

struct ComingSoonView: View {
	var body: some View {
		ContentUnavailableView("Coming Soon", systemImage: "sparkles")
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
