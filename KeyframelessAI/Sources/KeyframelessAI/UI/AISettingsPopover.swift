/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct AISettingsPopover: View {
	public enum Tab: String, CaseIterable, Identifiable {
		case action, config
		public var id: String { rawValue }
		var label: String {
			switch self {
			case .action: return "Action"
			case .config: return "Config"
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
		placeholder: String = "Describe what to do to the selected transcriptions…",
		isPluginMode: Bool = false,
		onRun: @escaping (String) -> Void,
		onDismiss: @escaping () -> Void = {}
	) {
		self.selectedCount = selectedCount
		self.productContext = productContext
		self.examples = examples
		self.placeholder = placeholder
		self.isPluginMode = isPluginMode
		self.onRun = onRun
		self.onDismiss = onDismiss
		let initial: Tab = AIKeyState.shared.hasAnyKey ? .action : .config
		_tab = State(initialValue: initial)
	}

	public var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				tabBar
				Spacer(minLength: 0)
				SharedProviderPicker()
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
		.frame(width: 360)
		.fixedSize(horizontal: false, vertical: true)
		.animation(.easeInOut(duration: 0.18), value: tab)
		.popoverGlassFix()
		.onChange(of: keyState.hasAnyKey) { _, hasKey in
			if !hasKey { tab = .config }
		}
	}

	private var tabBar: some View {
		HStack(spacing: 4) {
			ForEach(Tab.allCases) { t in
				let isSelected = tab == t
				let isDisabled = (t == .action && !keyState.hasAnyKey)
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
					.foregroundStyle(isSelected ? Color.white : .secondary)
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
					.foregroundStyle(.tertiary)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(Capsule().fill(Color.white.opacity(0.08)))
			.foregroundStyle(.secondary)
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.popover(isPresented: $showMenu, arrowEdge: .bottom) {
			VStack(alignment: .leading, spacing: 2) {
				ForEach(AIProvider.allCases) { p in
					let configured = keyState.configuredProviders.contains(p)
					Button {
						keyState.activeProvider = p
						showMenu = false
					} label: {
						HStack(spacing: 8) {
							AIProviderLogo(provider: p)
								.frame(width: 14, height: 14)
							Text(p.displayName)
								.font(.system(size: 12))
							if !configured {
								Text("no key")
									.font(.system(size: 9))
									.foregroundStyle(.tertiary)
									.padding(.horizontal, 5)
									.padding(.vertical, 1)
									.background(Capsule().strokeBorder(Color.white.opacity(0.12)))
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
