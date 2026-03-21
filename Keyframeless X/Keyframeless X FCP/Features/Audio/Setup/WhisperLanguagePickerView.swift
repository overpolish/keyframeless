/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI
import WhisperKit

struct WhisperLanguagePickerView: View {
	@ObservedObject var manager: WhisperModelManager
	@State private var search: String = ""

	private static let profanityLanguages = ProfanityFilter.availableLanguages

	private static let sortedLanguages: [(name: String, code: String)] = {
		var seen = Set<String>()
		return Constants.languages
			.sorted { $0.key < $1.key }
			.compactMap { name, code in
				guard seen.insert(code).inserted else { return nil }
				return (name: name.capitalized, code: code)
			}
	}()

	private var filtered: [(name: String, code: String)] {
		guard !search.isEmpty else { return Self.sortedLanguages }
		let q = search.lowercased()
		return Self.sortedLanguages.filter {
			$0.name.lowercased().contains(q) || $0.code.lowercased().contains(q)
		}
	}

	private var isEnglish: Bool {
		manager.selectedLanguage == "en"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			HStack {
				Text("Language")
					.font(.title3)
					.foregroundStyle(.secondary)
				Spacer()
				TranslateToggle(
					isOn: $manager.translateToEnglish,
					disabled: isEnglish
				)
			}

			VStack(spacing: 0) {
				TextField("Search", text: $search)
					.textFieldStyle(.plain)
					.font(.system(size: 12))
					.padding(.horizontal, KKPaddingLG)
					.padding(.vertical, KKSpacingLG)
					.overlay(
						Rectangle()
							.frame(height: KKBorderWidthXS)
							.foregroundStyle(Color.secondary.opacity(0.15)),
						alignment: .bottom
					)

				ScrollShadowView {
					ScrollViewReader { proxy in
						LazyVStack(spacing: 0) {
							LanguageRow(
								name: "Auto-detect", code: nil,
								selected: manager.selectedLanguage == nil,
								hasProfanityList: false
							) {
								manager.selectedLanguage = nil
							}
							.id("auto")
							ForEach(filtered, id: \.code) { lang in
								LanguageRow(
									name: lang.name, code: lang.code,
									selected: manager.selectedLanguage == lang.code,
									hasProfanityList: Self.profanityLanguages.contains(lang.code)
								) {
									manager.selectedLanguage = lang.code
								}
								.id(lang.code)
							}
						}
						.padding(KKPaddingMD)
						.onAppear {
							DispatchQueue.main.async {
								proxy.scrollTo(
									manager.selectedLanguage ?? "auto",
									anchor: .center)
							}
						}
					}
				}
				.clipShape(
					UnevenRoundedRectangle(
						bottomLeadingRadius: KKRadiusMD + 4, bottomTrailingRadius: KKRadiusMD + 4))
			}
			.frame(maxHeight: .infinity)
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4).fill(Color.white.opacity(0.04))
			)
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
			)
		}
	}
}

private struct TranslateToggle: View {
	@Binding var isOn: Bool
	let disabled: Bool

	var body: some View {
		Button {
			isOn.toggle()
		} label: {
			HStack(spacing: KKSpacingSM) {
				Image(systemName: "translate")
					.font(.system(size: 10))
				Text("Translate to English")
					.font(.system(size: 10, weight: .medium))
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(
				Capsule().fill(
					isOn ? Color(nsColor: .accent()).opacity(0.2) : Color.white.opacity(0.08)
				)
			)
			.overlay(
				Capsule().strokeBorder(
					isOn ? Color(nsColor: .accent()).opacity(0.4) : Color.clear,
					lineWidth: KKBorderWidthXS
				)
			)
			.foregroundStyle(isOn ? .primary : .secondary)
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.opacity(disabled ? 0.4 : 1)
	}
}

private struct LanguageRow: View {
	let name: String
	let code: String?
	let selected: Bool
	let hasProfanityList: Bool
	let action: () -> Void

	var body: some View {
		let accent = Color(nsColor: .accent() ?? .blue)

		HStack(spacing: KKSpacingLG) {
			Circle()
				.fill(selected ? accent : Color.secondary.opacity(0.3))
				.frame(width: 6, height: 6)
			Text(name)
				.font(.system(size: 12, weight: selected ? .medium : .regular))
			Spacer()
			if hasProfanityList {
				InfoBadge(
					label: "Profanity",
					systemImage:
						"checkmark.circle.trianglebadge.exclamationmark.fill",
					color: Color(nsColor: .error())
				)
			}
			if let code {
				Text(code.uppercased())
					.font(.system(size: 10).monospaced())
					.foregroundStyle(.tertiary)
					.frame(width: 24, alignment: .trailing)
			}
		}
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKSpacingMD)
		.background(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(selected ? accent.opacity(0.12) : Color.clear)
		)
		.contentShape(Rectangle())
		.onTapGesture { action() }
	}
}
