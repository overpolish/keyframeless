/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation

class TemplatePublishedParamsStore: ObservableObject {
	static let shared = TemplatePublishedParamsStore()

	@Published private(set) var settings: [String: TemplateParamSettings] = [:]
	@Published private var sessionValues: [String: [String: ParamValue]] = [:]

	enum FontMode: String, Codable, Equatable, Hashable {
		case base
		case custom
	}

	struct ParamValue: Codable, Equatable {
		var r: Double = 1
		var g: Double = 1
		var b: Double = 1
		var a: Double = 1
		var sliderValue: Double = 0
		var toggleValue: Bool = false
		var fontMode: FontMode = .base
		var customFont: String?
		static func fromDefaults(_ param: PublishedParameter) -> ParamValue {
			switch param.kind {
			case .color:
				return ParamValue(
					r: param.defaultR ?? 1, g: param.defaultG ?? 1,
					b: param.defaultB ?? 1)
			case .font:
				return ParamValue(fontMode: .base, customFont: param.defaultFont)
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
		var textOzmlKey: String?
		var textOzml: String?
		var textOzmlDefaultText: String?
		var textOzmlStyleID: String?
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
				if param.kind != .off && param.kind != .animation && param.kind != .font
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
		textOzml: PublishedParameter.TextOzmlInfo? = nil,
		for templateID: String
	) {
		let enabledIDs = Set(params.filter { $0.isToggleable || $0.isFont }.map(\.id))
		let existing = settings[templateID]
		var s = TemplateParamSettings(
			allParams: params, enabledIDs: enabledIDs, hasPerWordAnimation: hasPerWordAnimation,
			perWordStartsAtZero: existing?.perWordStartsAtZero ?? false)
		s.textOzmlKey = textOzml?.key ?? existing?.textOzmlKey
		s.textOzml = textOzml?.ozml ?? existing?.textOzml
		s.textOzmlDefaultText = textOzml?.defaultText ?? existing?.textOzmlDefaultText
		s.textOzmlStyleID = textOzml?.styleID ?? existing?.textOzmlStyleID
		settings[templateID] = s
		resetValues(for: templateID)
		KKStore.save(settings, to: filename)
	}

	func setTextOzml(_ info: PublishedParameter.TextOzmlInfo, for templateID: String) {
		if settings[templateID] == nil {
			settings[templateID] = TemplateParamSettings(allParams: [])
		}
		settings[templateID]?.textOzmlKey = info.key
		settings[templateID]?.textOzml = info.ozml
		settings[templateID]?.textOzmlDefaultText = info.defaultText
		settings[templateID]?.textOzmlStyleID = info.styleID
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
