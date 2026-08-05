/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

// Visual test: flip this to true (DEBUG builds only) to force the "Keyframeless
// AI update available" banner to always show with a placeholder version, so its
// layout can be eyeballed without a real pending update.
private let kAIForceUpdateBanner = false

public struct AISettingsPopover: View {
	public enum Tab: String, CaseIterable, Identifiable {
		case action, config
		public var id: String { rawValue }
		var label: String {
			switch self {
			case .action: return AILoc("Ask Kai")
			case .config: return AILoc("Config")
			}
		}
		var systemImage: String {
			switch self {
			case .action: return "wand.and.stars"
			case .config: return "key.fill"
			}
		}
	}

	@StateObject private var keyState = AIKeyState.shared
	@StateObject private var updateState = AIUpdateState.shared
	@State private var tab: Tab
	let selectedCount: Int
	let productContext: String
	let examples: [AIPromptExample]
	let placeholder: String
	let isPluginMode: Bool
	let onRun: (String) -> Void
	let onDismiss: () -> Void

	public init(
		selectedCount: Int,
		productContext: String,
		examples: [AIPromptExample] = AIPromptExample.stenoDefaults,
		placeholder: String? = nil,
		isPluginMode: Bool = false,
		onRun: @escaping (String) -> Void,
		onDismiss: @escaping () -> Void = {}
	) {
		self.selectedCount = selectedCount
		self.productContext = productContext
		self.examples = examples
		self.placeholder =
			placeholder ?? AILoc("Describe what to do to the selected transcriptions…")
		self.isPluginMode = isPluginMode
		self.onRun = onRun
		self.onDismiss = onDismiss
		let initial: Tab = AIKeyState.shared.activeIsConfigured ? .action : .config
		_tab = State(initialValue: initial)
	}

	public var body: some View {
		VStack(spacing: 0) {
			if (kAIForceUpdateBanner || updateState.availableVersion != nil)
				&& !updateState.dismissed
			{
				AIUpdateBanner(
					version: updateState.availableVersion ?? "1.0.2",
					url: updateState.notesURL
						?? URL(string: "https://keyframeless.com/kai/"),
					onDismiss: { updateState.dismissed = true }
				)
			}
			HStack(spacing: 8) {
				tabBar
				Spacer(minLength: 0)
				SharedProviderPicker { picked in
					// Picking a provider that isn't set up yet (cloud with no
					// key, or local with no model) drops the user on Config so
					// they can finish setup.
					if !keyState.configuredProviders.contains(picked) {
						tab = .config
					}
				}
			}
			.padding(.horizontal, 12)
			.padding(.top, 10)
			.padding(.bottom, 8)
			Divider().opacity(0.4)
			Group {
				switch tab {
				case .action:
					AIActionTab(
						selectedCount: selectedCount,
						productContext: productContext,
						examples: examples,
						placeholder: placeholder,
						isPluginMode: isPluginMode,
						onRun: { prompt in
							onRun(prompt)
							if !isPluginMode { onDismiss() }
						})
				case .config:
					AIConfigTab()
				}
			}
			.padding(14)
		}
		.frame(width: 380)
		.fixedSize(horizontal: false, vertical: true)
		.animation(.easeInOut(duration: 0.18), value: tab)
		.animation(.easeInOut(duration: 0.18), value: updateState.availableVersion)
		.popoverGlassFix()
		.onAppear { updateState.requestCheck() }
		.onChange(of: keyState.hasAnyKey) { _, hasKey in
			if !hasKey { tab = .config }
		}
	}

	private var tabBar: some View {
		HStack(spacing: 4) {
			ForEach(Tab.allCases) { t in
				let isSelected = tab == t
				// Action is unusable until the ACTIVE provider can actually run
				// (cloud key present, or a local model downloaded + selected).
				let isDisabled = (t == .action && !keyState.activeIsConfigured)
				Button {
					tab = t
				} label: {
					HStack(spacing: 5) {
						Image(systemName: t.systemImage)
							.font(.system(size: 10, weight: .semibold))
						Text(t.label)
							.font(.system(size: 12, weight: .medium))
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background {
						if isSelected {
							Capsule().fill(Color.accentColor)
						}
					}
					.foregroundStyle(isSelected ? Color.white : Color.aiSecondaryText)
					.contentShape(Capsule())
					.opacity(isDisabled ? 0.35 : 1)
				}
				.buttonStyle(.plain)
				.disabled(isDisabled)
			}
		}
	}
}

struct SharedProviderPicker: View {
	@StateObject private var keyState = AIKeyState.shared
	@State private var showMenu = false
	var onPick: (AIProvider) -> Void = { _ in }

	var body: some View {
		Button {
			showMenu.toggle()
		} label: {
			HStack(spacing: 5) {
				AIProviderLogo(provider: keyState.activeProvider)
					.frame(width: 12, height: 12)
				Text(keyState.activeProvider.displayName)
					.font(.system(size: 11, weight: .medium))
				Image(systemName: "chevron.up.chevron.down")
					.font(.system(size: 8))
					.foregroundStyle(Color.aiTertiaryText)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(Capsule().fill(Color.white.opacity(0.08)))
			.foregroundStyle(Color.aiSecondaryText)
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.popover(isPresented: $showMenu, arrowEdge: .bottom) {
			VStack(alignment: .leading, spacing: 2) {
				ForEach(AIProvider.availableCases) { p in
					let configured = keyState.configuredProviders.contains(p)
					Button {
						keyState.activeProvider = p
						showMenu = false
						onPick(p)
					} label: {
						HStack(spacing: 8) {
							AIProviderLogo(provider: p)
								.frame(width: 14, height: 14)
							Text(p.displayName)
								.font(.system(size: 12))
							if !configured {
								AIPillBadge(
									label: p.requiresAPIKey ? AILoc("No key") : AILoc("No model"))
							}
							Spacer()
							if p == keyState.activeProvider {
								Image(systemName: "checkmark")
									.font(.system(size: 10, weight: .semibold))
									.foregroundStyle(Color.accentColor)
							}
						}
						.padding(.horizontal, 8)
						.padding(.vertical, 5)
						.frame(minWidth: 160, alignment: .leading)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
			}
			.padding(4)
			.popoverGlassFix()
		}
	}
}
