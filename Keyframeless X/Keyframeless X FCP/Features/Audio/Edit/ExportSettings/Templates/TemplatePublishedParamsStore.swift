/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import Foundation

class TemplatePublishedParamsStore: ObservableObject {
	static let shared = TemplatePublishedParamsStore()

	@Published private(set) var settings: [String: TemplateParamSettings] = [:]
	@Published private var sessionValues: [String: [String: ParamValue]] = [:]

	struct ParamValue: Codable, Equatable {
		var r: Double = 1
		var g: Double = 1
		var b: Double = 1
		var a: Double = 1
		var sliderValue: Double = 0

		static func fromDefaults(_ param: PublishedParameter) -> ParamValue {
			switch param.kind {
			case .color:
				return ParamValue(
					r: param.defaultR ?? 1, g: param.defaultG ?? 1,
					b: param.defaultB ?? 1, a: 1)
			case .slider:
				return ParamValue(sliderValue: param.defaultSlider ?? 0)
			default:
				return ParamValue()
			}
		}
	}

	struct TemplateParamSettings: Codable {
		var allParams: [PublishedParameter]
		var enabledIDs: Set<String>
		var hasPerWordAnimation: Bool = false
	}

	private let filename = "template_published_params.json"

	private init() {
		settings = KKStore.load([String: TemplateParamSettings].self, from: filename) ?? [:]
	}

	func params(for templateID: String) -> TemplateParamSettings? {
		settings[templateID]
	}

	func setParams(
		_ params: [PublishedParameter], enabledIDs: Set<String>, hasPerWordAnimation: Bool = false,
		for templateID: String
	) {
		settings[templateID] = TemplateParamSettings(
			allParams: params, enabledIDs: enabledIDs, hasPerWordAnimation: hasPerWordAnimation)
		resetValues(for: templateID)
		KKStore.save(settings, to: filename)
	}

	func isEnabled(_ paramID: String, for templateID: String) -> Bool {
		settings[templateID]?.enabledIDs.contains(paramID) ?? false
	}

	func setValue(_ value: ParamValue, paramID: String, for templateID: String) {
		sessionValues[templateID, default: [:]][paramID] = value
	}

	func value(paramID: String, for templateID: String) -> ParamValue {
		if let v = sessionValues[templateID]?[paramID] { return v }
		if let param = settings[templateID]?.allParams.first(where: { $0.id == paramID }) {
			return ParamValue.fromDefaults(param)
		}
		return ParamValue()
	}

	func resetValues(for templateID: String) {
		sessionValues.removeValue(forKey: templateID)
	}

	func removeSettings(for templateID: String) {
		settings.removeValue(forKey: templateID)
		sessionValues.removeValue(forKey: templateID)
		KKStore.save(settings, to: filename)
	}
}
