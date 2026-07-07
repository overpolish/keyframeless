/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
	@State private var fontModes: [String: TemplatePublishedParamsStore.FontMode]
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
					($0.id, initialKinds[$0.id] ?? $0.kind)
				}))
		_fontModes = State(
			initialValue: Dictionary(
				uniqueKeysWithValues: params.filter { $0.defaultFont != nil }.map {
					// Restore the saved mode (.font = custom). The passed params are re-parsed
					// on reopen with kind reset, so read the persisted kind via initialKinds -
					// same source the non-font paramKinds use just below.
					($0.id, (initialKinds[$0.id] ?? $0.kind) == .font ? .custom : .base)
				}))
		_perWordStartsAtZero = State(initialValue: initialPerWordStartsAtZero)
	}

	private var fontParams: [PublishedParameter] { params.filter { $0.defaultFont != nil } }
	private var nonFontParams: [PublishedParameter] {
		params.filter { $0.defaultFont == nil && !$0.isTextSize }
	}
	private var hasAnyContent: Bool { !params.isEmpty || hasPerWordAnimation }

	var body: some View {
		ModalContainer(width: 360, onDismiss: onDismiss) {
			VStack(alignment: .leading, spacing: KKSpacingSM) {
				HStack(spacing: KKSpacingMD) {
					Text("Customize Available Parameters")
						.font(.title3).foregroundStyle(.primary)
					Spacer()
					if hasPerWordAnimation {
						InfoBadge(
							label: String(localized: "Per word"), systemImage: "directcurrent",
							color: .green)
					}
				}
				if !hasAnyContent {
					Text("No published parameters detected in \"\(templateName)\".")
						.font(.system(size: 11)).foregroundStyle(.secondary)
						.padding(.vertical, KKPaddingLG)
						.fixedSize(horizontal: false, vertical: true)
				} else if params.isEmpty {
					Text("Configure per-word animation for \"\(templateName)\".")
						.font(.system(size: 11)).foregroundStyle(.secondary)
						.padding(.vertical, KKPaddingLG)
						.fixedSize(horizontal: false, vertical: true)
				} else {
					Text(
						"Detected the following published parameters in \"\(templateName)\". Choose a type for each parameter."
					)
					.font(.system(size: 11)).foregroundStyle(.secondary)
					.padding(.vertical, KKPaddingLG)
					.fixedSize(horizontal: false, vertical: true)
				}
			}
			if hasPerWordAnimation {
				HStack(alignment: .center, spacing: KKSpacingSM) {
					Text("Word Timing").font(.caption).foregroundStyle(.primary)
					Spacer()
					PillToggle(
						selection: $perWordStartsAtZero,
						options: [
							(label: String(localized: "Straight Away"), value: true),
							(label: String(localized: "Late Start"), value: false),
						])
				}
			}
			ForEach(fontParams) { param in
				FontModeRow(
					name: param.name,
					fontMode: Binding(
						get: { fontModes[param.id] ?? .base },
						set: { fontModes[param.id] = $0 }))
			}
			if !nonFontParams.isEmpty {
				ScrollShadowView {
					VStack(spacing: KKSpacingMD) {
						ForEach(nonFontParams) { param in
							ParamKindRow(
								name: param.name,
								kind: Binding(
									get: { paramKinds[param.id] ?? .off },
									set: { paramKinds[param.id] = $0 }),
								hasOptions: param.options?.isEmpty == false,
								hasPoint: param.defaultX != nil)
						}
					}
					.onGeometryChange(for: CGFloat.self) {
						$0.size.height
					} action: {
						paramListHeight = $0
					}
				}
				.frame(height: min(paramListHeight, 300))
			}
			HStack {
				if !hasAnyContent {
					Spacer()
					Button("OK") { onDismiss() }.buttonStyle(.plain).foregroundStyle(Color.kkAccent)
				} else {
					Button("Cancel") { onDismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
					Spacer()
					Button("Save") { save() }.buttonStyle(.plain).foregroundStyle(Color.kkAccent)
				}
			}
		}
	}

	private func save() {
		let updated = params.map { param -> PublishedParameter in
			var p = param
			if p.defaultFont != nil {
				p.kind = fontModes[param.id] == .custom ? .font : .off
			} else {
				p.kind = paramKinds[param.id] ?? .off
			}
			return p
		}
		onSave(updated, perWordStartsAtZero)
	}
}
