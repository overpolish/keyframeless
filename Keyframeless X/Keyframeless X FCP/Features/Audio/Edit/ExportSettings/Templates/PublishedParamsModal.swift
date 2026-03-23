/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct PublishedParamsModal: View {
	let templateName: String
	let params: [PublishedParameter]
	let hasPerWordAnimation: Bool
	let onSave: (Set<String>) -> Void
	let onDismiss: () -> Void

	@State private var enabledIDs: Set<String>

	init(
		templateName: String,
		params: [PublishedParameter],
		hasPerWordAnimation: Bool = false,
		initialEnabled: Set<String> = [],
		onSave: @escaping (Set<String>) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.templateName = templateName
		self.params = params
		self.hasPerWordAnimation = hasPerWordAnimation
		self.onSave = onSave
		self.onDismiss = onDismiss
		_enabledIDs = State(initialValue: initialEnabled)
	}

	var body: some View {
		ZStack {
			Color.black.opacity(0.5)
				.ignoresSafeArea()
				.onTapGesture { onDismiss() }
			VStack(alignment: .leading, spacing: KKSpacingXL) {
				VStack(alignment: .leading, spacing: KKSpacingSM) {
					HStack(spacing: KKSpacingMD) {
						Text("Customize Available Parameters")
							.font(.title3)
							.foregroundStyle(.primary)
						Spacer()
						if hasPerWordAnimation {
							InfoBadge(
								label: "Per word",
								systemImage: "directcurrent",
								color: .green
							)
						}
					}
					if params.isEmpty {
						Text("No published parameters detected in \"\(templateName)\".")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
							.padding(.vertical, KKPaddingLG)
							.fixedSize(horizontal: false, vertical: true)
					} else {
						Text(
							"Detected the following published parameters in \"\(templateName)\". Toggle which should be available from Keyframeless X."
						)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.padding(.vertical, KKPaddingLG)
						.fixedSize(horizontal: false, vertical: true)
					}
				}
				if !params.isEmpty {
					VStack(spacing: KKSpacingSM) {
						ForEach(params) { param in
							ParamToggleRow(
								param: param,
								isOn: Binding(
									get: { enabledIDs.contains(param.id) },
									set: { on in
										if on {
											enabledIDs.insert(param.id)
										} else {
											enabledIDs.remove(param.id)
										}
									}
								)
							)
						}
					}
				}
				HStack {
					if params.isEmpty {
						Spacer()
						Button("OK") { onDismiss() }
							.buttonStyle(.plain)
							.foregroundStyle(Color.kkAccent)
					} else {
						Button("Cancel") { onDismiss() }
							.buttonStyle(.plain)
							.foregroundStyle(.secondary)
						Spacer()
						Button("Save") { onSave(enabledIDs) }
							.buttonStyle(.plain)
							.foregroundStyle(Color.kkAccent)
					}
				}
			}
			.padding(KKPaddingXL)
			.frame(width: 360)
			.kkPanel()
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.fill(Color(nsColor: .windowBackgroundColor))
			)
		}
	}
}

private struct ParamToggleRow: View {
	let param: PublishedParameter
	@Binding var isOn: Bool

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			VStack(alignment: .leading, spacing: 2) {
				Text(param.name)
					.font(.system(size: 11))
					.foregroundStyle(.primary)
				if param.kind == .unsupported {
					Text("Unsupported type")
						.font(.system(size: 9))
						.foregroundStyle(.secondary.opacity(0.6))
				}
			}
			Spacer()
			kindBadge
			if param.isToggleable {
				Toggle("", isOn: $isOn)
					.toggleStyle(.switch)
					.controlSize(.mini)
					.labelsHidden()
					.tint(.kkAccent)
			}
		}
		.padding(.vertical, KKPaddingXS)
		.opacity(param.isToggleable ? 1 : 0.5)
	}

	@ViewBuilder
	private var kindBadge: some View {
		switch param.kind {
		case .color:
			InfoBadge(label: "Color", systemImage: "paintpalette", color: .kkAccent)
		case .slider:
			InfoBadge(label: "Slider", systemImage: "slider.horizontal.3", color: .kkWarning)
		case .unsupported:
			InfoBadge(label: "Unsupported", color: .secondary)
		case .animation:
			EmptyView()
		}
	}
}
