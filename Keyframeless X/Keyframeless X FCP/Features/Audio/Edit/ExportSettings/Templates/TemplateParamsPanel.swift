/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct TemplateParamsPanel: View {
	let template: CaptionTemplate
	@ObservedObject var store: TemplatePublishedParamsStore

	private var enabledParams: [PublishedParameter] {
		guard let settings = store.params(for: template.id) else { return [] }
		return settings.allParams.filter { $0.isToggleable && !$0.isFont }
	}

	private var fontParams: [PublishedParameter] {
		guard let settings = store.params(for: template.id) else { return [] }
		return settings.allParams.filter(\.isFont)
	}

	private var hasParams: Bool {
		!enabledParams.isEmpty || !fontParams.isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			if hasParams {
				ScrollView(.vertical, showsIndicators: false) {
					VStack(alignment: .leading, spacing: KKSpacingLG) {
						ForEach(enabledParams) { param in
							CompactParamControl(
								param: param,
								templateID: template.id,
								store: store
							)
						}
						ForEach(fontParams) { param in
							CompactFontControl(
								param: param,
								templateID: template.id,
								store: store
							)
						}
					}
				}
				Spacer()
				HStack {
					Spacer()
					Button {
						store.resetValues(for: template.id)
					} label: {
						Label("Reset", systemImage: "arrow.uturn.backward")
							.font(.system(size: 9))
							.contentShape(Capsule())
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				}
			} else {
				Spacer()
				Text("No options to customise")
					.font(.system(size: 9))
					.foregroundStyle(.secondary.opacity(0.6))
					.multilineTextAlignment(.center)
					.frame(maxWidth: .infinity)
				Spacer()
			}
		}
		.padding(KKPaddingMD)
	}
}

private struct CompactParamControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	var body: some View {
		switch param.kind {
		case .color:
			CompactColorControl(param: param, templateID: templateID, store: store)
		case .slider:
			CompactSliderControl(param: param, templateID: templateID, store: store)
		case .toggle:
			CompactToggleControl(param: param, templateID: templateID, store: store)
		default:
			EmptyView()
		}
	}
}

private struct CompactColorControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	private func binding(
		_ keyPath: WritableKeyPath<TemplatePublishedParamsStore.ParamValue, Double>
	) -> Binding<Double> {
		Binding(
			get: { store.value(paramID: param.id, for: templateID)[keyPath: keyPath] },
			set: { newVal in
				var val = store.value(paramID: param.id, for: templateID)
				val[keyPath: keyPath] = newVal
				store.setValue(val, paramID: param.id, for: templateID)
			}
		)
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(param.name)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.lineLimit(1)
			Spacer()
			ColorSwatch(
				colorR: binding(\.r),
				colorG: binding(\.g),
				colorB: binding(\.b),
				colorA: binding(\.a)
			)
		}
	}
}

private struct CompactSliderControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	private var value: Binding<Double> {
		Binding(
			get: { store.value(paramID: param.id, for: templateID).sliderValue },
			set: { newVal in
				var val = store.value(paramID: param.id, for: templateID)
				val.sliderValue = newVal
				store.setValue(val, paramID: param.id, for: templateID)
			}
		)
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(param.name)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.lineLimit(1)
			Spacer()
			Slider(value: value, in: 0...100)
				.controlSize(.mini)
				.frame(maxWidth: 80)
		}
	}
}

private struct CompactToggleControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	private var value: Binding<Bool> {
		Binding(
			get: { store.value(paramID: param.id, for: templateID).toggleValue },
			set: { newVal in
				var val = store.value(paramID: param.id, for: templateID)
				val.toggleValue = newVal
				store.setValue(val, paramID: param.id, for: templateID)
			}
		)
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(param.name)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.lineLimit(1)
			Spacer()
			Toggle("", isOn: value)
				.toggleStyle(.checkbox)
				.controlSize(.small)
				.labelsHidden()
		}
	}
}

private struct CompactFontControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore
	@State private var isFontOpen = false

	private var customFont: Binding<String> {
		Binding(
			get: {
				store.value(paramID: param.id, for: templateID).customFont ?? param.defaultFont
					?? "HelveticaNeue"
			},
			set: { newVal in
				var val = store.value(paramID: param.id, for: templateID)
				val.customFont = newVal
				store.setValue(val, paramID: param.id, for: templateID)
			}
		)
	}

	private var displayName: String {
		NSFont(name: customFont.wrappedValue, size: 12)?.displayName ?? customFont.wrappedValue
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(param.name)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.lineLimit(1)
			Spacer()
			HStack(spacing: KKSpacingSM) {
				Text(displayName)
					.font(.custom(customFont.wrappedValue, size: 11))
					.lineLimit(1)
					.frame(maxWidth: .infinity, alignment: .leading)
				Image(systemName: "chevron.up.chevron.down")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			.frame(height: KKInspectorRowHeight)
			.padding(.horizontal, KKPaddingLG)
			.kkPanel(cornerRadius: KKRadiusMD)
			.contentShape(RoundedRectangle(cornerRadius: KKRadiusMD))
			.onTapGesture { isFontOpen.toggle() }
			.popover(isPresented: $isFontOpen, arrowEdge: .leading) {
				FontListPopover(selectedFont: customFont, fonts: FontCache.families)
					.background(PopoverBackgroundClearer())
			}
		}
	}
}
