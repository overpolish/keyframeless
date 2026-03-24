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
		var toggleValue: Bool = false
		static func fromDefaults(_ param: PublishedParameter) -> ParamValue {
			switch param.kind {
			case .color:
				return ParamValue(
					r: param.defaultR ?? 1, g: param.defaultG ?? 1,
					b: param.defaultB ?? 1)
			default:
				return ParamValue()
			}
		}
	}

	struct TemplateParamSettings: Codable {
		var allParams: [PublishedParameter]
		/// Legacy field kept for migration from old format where enabledIDs was the source of truth.
		/// Now derived from param kinds on save. Safe to remove once all users have migrated.
		var enabledIDs: Set<String> = []
		var hasPerWordAnimation: Bool = false
		var perWordStartsAtZero: Bool = false
	}

	private let filename = "template_published_params.json"

	private init() {
		var loaded = KKStore.load([String: TemplateParamSettings].self, from: filename) ?? [:]
		var needsSave = false
		for (key, var setting) in loaded {
			let legacy = setting.enabledIDs
			guard !legacy.isEmpty else { continue }
			var changed = false
			for i in setting.allParams.indices {
				let param = setting.allParams[i]
				if param.kind != .off && param.kind != .animation
					&& !legacy.contains(param.id)
				{
					setting.allParams[i].kind = .off
					changed = true
				}
			}
			if changed {
				setting.enabledIDs = Set(setting.allParams.filter(\.isToggleable).map(\.id))
				loaded[key] = setting
				needsSave = true
			}
		}
		settings = loaded
		if needsSave { KKStore.save(settings, to: filename) }
	}

	func params(for templateID: String) -> TemplateParamSettings? {
		settings[templateID]
	}

	func setParams(
		_ params: [PublishedParameter], hasPerWordAnimation: Bool = false,
		for templateID: String
	) {
		let enabledIDs = Set(params.filter(\.isToggleable).map(\.id))
		settings[templateID] = TemplateParamSettings(
			allParams: params, enabledIDs: enabledIDs, hasPerWordAnimation: hasPerWordAnimation)
		resetValues(for: templateID)
		KKStore.save(settings, to: filename)
	}

	func kindMap(for templateID: String) -> [String: PublishedParameter.ParamKind] {
		guard let settings = settings[templateID] else { return [:] }
		return Dictionary(uniqueKeysWithValues: settings.allParams.map { ($0.id, $0.kind) })
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

	func setPerWordStartsAtZero(_ value: Bool, for templateID: String) {
		if settings[templateID] == nil {
			settings[templateID] = TemplateParamSettings(allParams: [], hasPerWordAnimation: true)
		}
		settings[templateID]?.perWordStartsAtZero = value
		KKStore.save(settings, to: filename)
	}

	func removeSettings(for templateID: String) {
		settings.removeValue(forKey: templateID)
		sessionValues.removeValue(forKey: templateID)
		KKStore.save(settings, to: filename)
	}
}
