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

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			Text("Language")
				.font(.title3)
				.foregroundStyle(.secondary)

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
					LazyVStack(spacing: 0) {
						LanguageRow(
							name: "Auto-detect", code: nil,
							selected: manager.selectedLanguage == nil
						) {
							manager.selectedLanguage = nil
						}
						ForEach(filtered, id: \.code) { lang in
							LanguageRow(
								name: lang.name, code: lang.code,
								selected: manager.selectedLanguage == lang.code
							) {
								manager.selectedLanguage = lang.code
							}
						}
					}
					.padding(KKPaddingMD)
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

private struct LanguageRow: View {
	let name: String
	let code: String?
	let selected: Bool
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
			if let code {
				Text(code.uppercased())
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
					.monospacedDigit()
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
