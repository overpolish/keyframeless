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
	let onSave: ([PublishedParameter]) -> Void
	let onDismiss: () -> Void

	@State private var paramKinds: [String: PublishedParameter.ParamKind]
	@State private var paramListHeight: CGFloat = 0

	init(
		templateName: String,
		params: [PublishedParameter],
		hasPerWordAnimation: Bool = false,
		initialKinds: [String: PublishedParameter.ParamKind] = [:],
		onSave: @escaping ([PublishedParameter]) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.templateName = templateName
		self.params = params
		self.hasPerWordAnimation = hasPerWordAnimation
		self.onSave = onSave
		self.onDismiss = onDismiss
		_paramKinds = State(
			initialValue: Dictionary(
				uniqueKeysWithValues: params.map {
					($0.id, initialKinds[$0.id] ?? .off)
				}))
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
							"Detected the following published parameters in \"\(templateName)\". Choose a type for each parameter."
						)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.padding(.vertical, KKPaddingLG)
						.fixedSize(horizontal: false, vertical: true)
					}
				}
				if !params.isEmpty {
					ScrollShadowView {
						VStack(spacing: KKSpacingMD) {
							ForEach(params) { param in
								ParamKindRow(
									name: param.name,
									kind: Binding(
										get: { paramKinds[param.id] ?? .off },
										set: { paramKinds[param.id] = $0 }
									)
								)
							}
						}
						.onGeometryChange(for: CGFloat.self) { proxy in
							proxy.size.height
						} action: { height in
							paramListHeight = height
						}
					}
					.frame(height: min(paramListHeight, 300))
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
						Button("Save") { save() }
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

	private func save() {
		let updated = params.map { param -> PublishedParameter in
			var p = param
			p.kind = paramKinds[param.id] ?? .off
			return p
		}
		onSave(updated)
	}
}

private struct ParamKindRow: View {
	let name: String
	@Binding var kind: PublishedParameter.ParamKind

	private let kindOptions:
		[(label: String, value: PublishedParameter.ParamKind, icon: String?, color: Color?)] = [
			("Off", .off, nil, .kkError),
			("Color", .color, "paintpalette", .kkAccent),
			("Slider", .slider, "slider.horizontal.3", .kkWarning),
			("Toggle", .toggle, "checkmark.circle", .green),
		]

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Text(name)
				.font(.system(size: 11))
				.foregroundStyle(.primary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
			Spacer()
			PillToggle(selection: $kind, options: kindOptions)
				.fixedSize()
		}
		.padding(.vertical, KKPaddingXS)
	}
}
