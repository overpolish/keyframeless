/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct TemplateControlsPopover: View {
	let template: CaptionTemplate
	@ObservedObject var store: TemplatePublishedParamsStore

	private var enabledParams: [PublishedParameter] {
		guard let settings = store.params(for: template.id) else { return [] }
		return settings.allParams.filter { settings.enabledIDs.contains($0.id) && $0.isToggleable }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			if enabledParams.isEmpty {
				Text("No parameters enabled")
					.font(.system(size: 11))
					.foregroundStyle(.secondary.opacity(0.6))
			} else {
				VStack(spacing: KKSpacingMD) {
					ForEach(enabledParams) { param in
						ParamControlRow(
							param: param,
							templateID: template.id,
							store: store
						)
					}
				}
			}
			if !enabledParams.isEmpty {
				HStack {
					Spacer()
					Button {
						store.resetValues(for: template.id)
					} label: {
						Label("Reset", systemImage: "arrow.uturn.backward")
							.font(.system(size: 10))
							.contentShape(Capsule())
					}
					.buttonStyle(.plain)
					.foregroundStyle(.primary)
				}
			}
		}
		.padding(KKPaddingLG)
		.frame(width: 260)
		.background(PopoverBackgroundClearer())
	}
}

private struct ParamControlRow: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	var body: some View {
		switch param.kind {
		case .color:
			ColorParamControl(param: param, templateID: templateID, store: store)
		case .slider:
			SliderParamControl(param: param, templateID: templateID, store: store)
		default:
			EmptyView()
		}
	}
}

private struct ColorParamControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	private var colorR: Binding<Double> {
		paramBinding(\.r)
	}
	private var colorG: Binding<Double> {
		paramBinding(\.g)
	}
	private var colorB: Binding<Double> {
		paramBinding(\.b)
	}
	private var colorA: Binding<Double> {
		paramBinding(\.a)
	}

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Text(param.name)
				.font(.caption)
				.foregroundStyle(.primary)
			Spacer()
			ColorSwatch(
				colorR: colorR,
				colorG: colorG,
				colorB: colorB,
				colorA: colorA
			)
		}
	}

	private func paramBinding(
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
}

private struct SliderParamControl: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore

	private var sliderValue: Binding<Double> {
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
		LabeledSlider(
			label: param.name,
			labelWidth: 120,
			value: sliderValue,
			range: 0...100,
			textColor: .primary,
			valueWidth: 20
		)
	}
}
