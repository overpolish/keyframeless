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
	let onSave: ([PublishedParameter], Bool) -> Void
	let onDismiss: () -> Void

	@State private var paramKinds: [String: PublishedParameter.ParamKind]
	@State private var paramListHeight: CGFloat = 0
	@State private var perWordStartsAtZero: Bool

	init(
		templateName: String,
		params: [PublishedParameter],
		hasPerWordAnimation: Bool = false,
		initialKinds: [String: PublishedParameter.ParamKind] = [:],
		initialPerWordStartsAtZero: Bool = false,
		onSave: @escaping ([PublishedParameter], Bool) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.templateName = templateName
		self.params = params
		self.hasPerWordAnimation = hasPerWordAnimation
		self.onSave = onSave
		self.onDismiss = onDismiss
		_paramKinds = State(
			initialValue: Dictionary(
				uniqueKeysWithValues: params.filter { $0.defaultFont == nil }.map {
					($0.id, initialKinds[$0.id] ?? .off)
				}))
		_perWordStartsAtZero = State(initialValue: initialPerWordStartsAtZero)
	}

	private var fontParams: [PublishedParameter] {
		params.filter { $0.defaultFont != nil }
	}

	private var nonFontParams: [PublishedParameter] {
		params.filter { $0.defaultFont == nil }
	}

	private var hasAnyContent: Bool {
		!params.isEmpty || hasPerWordAnimation
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
					if !hasAnyContent {
						Text("No published parameters detected in \"\(templateName)\".")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
							.padding(.vertical, KKPaddingLG)
							.fixedSize(horizontal: false, vertical: true)
					} else if params.isEmpty {
						Text(
							"Configure per-word animation for \"\(templateName)\"."
						)
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
				if hasPerWordAnimation {
					HStack(alignment: .center, spacing: KKSpacingSM) {
						Text("Word Timing")
							.font(.caption)
							.foregroundStyle(.primary)
						Spacer()
						PillToggle(
							selection: $perWordStartsAtZero,
							options: [
								(label: "Straight Away", value: true),
								(label: "Late Start", value: false),
							]
						)
					}
				}
				if !fontParams.isEmpty {
					KKAlertRepresentable(
						text: "Font parameters must be set manually in Final Cut Pro",
						icon: NSImage(
							systemSymbolName: "textformat", accessibilityDescription: nil),
						fontSize: 10
					)
					.frame(maxWidth: .infinity)
					.frame(height: 32)
				}
				if !nonFontParams.isEmpty {
					ScrollShadowView {
						VStack(spacing: KKSpacingMD) {
							ForEach(nonFontParams) { param in
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
					if !hasAnyContent {
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
		onSave(updated, perWordStartsAtZero)
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
