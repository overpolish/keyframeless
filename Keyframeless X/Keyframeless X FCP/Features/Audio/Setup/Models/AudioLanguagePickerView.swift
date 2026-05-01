/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import FluidAudio
import KeyframelessKit
import SwiftUI

struct AudioLanguagePickerView: View {
	@ObservedObject var manager: AudioModelManager
	@State private var search: String = ""

	private static let profanityLanguages = ProfanityFilter.availableLanguages

	private static let whisperLanguages: [String: String] = [
		"af": "Afrikaans", "am": "Amharic", "ar": "Arabic", "as": "Assamese",
		"az": "Azerbaijani", "ba": "Bashkir", "be": "Belarusian", "bg": "Bulgarian",
		"bn": "Bengali", "bo": "Tibetan", "br": "Breton", "bs": "Bosnian",
		"ca": "Catalan", "cs": "Czech", "cy": "Welsh", "da": "Danish",
		"de": "German", "el": "Greek", "en": "English", "es": "Spanish",
		"et": "Estonian", "eu": "Basque", "fa": "Persian", "fi": "Finnish",
		"fo": "Faroese", "fr": "French", "gl": "Galician", "gu": "Gujarati",
		"ha": "Hausa", "haw": "Hawaiian", "he": "Hebrew", "hi": "Hindi",
		"hr": "Croatian", "ht": "Haitian", "hu": "Hungarian", "hy": "Armenian",
		"id": "Indonesian", "is": "Icelandic", "it": "Italian", "ja": "Japanese",
		"jw": "Javanese", "ka": "Georgian", "kk": "Kazakh", "km": "Khmer",
		"kn": "Kannada", "ko": "Korean", "la": "Latin", "lb": "Luxembourgish",
		"ln": "Lingala", "lo": "Lao", "lt": "Lithuanian", "lv": "Latvian",
		"mg": "Malagasy", "mi": "Maori", "mk": "Macedonian", "ml": "Malayalam",
		"mn": "Mongolian", "mr": "Marathi", "ms": "Malay", "mt": "Maltese",
		"my": "Myanmar", "ne": "Nepali", "nl": "Dutch", "nn": "Nynorsk",
		"no": "Norwegian", "oc": "Occitan", "pa": "Punjabi", "pl": "Polish",
		"ps": "Pashto", "pt": "Portuguese", "ro": "Romanian", "ru": "Russian",
		"sa": "Sanskrit", "sd": "Sindhi", "si": "Sinhala", "sk": "Slovak",
		"sl": "Slovenian", "sn": "Shona", "so": "Somali", "sq": "Albanian",
		"sr": "Serbian", "su": "Sundanese", "sv": "Swedish", "sw": "Swahili",
		"ta": "Tamil", "te": "Telugu", "tg": "Tajik", "th": "Thai",
		"tk": "Turkmen", "tl": "Tagalog", "tr": "Turkish", "tt": "Tatar",
		"uk": "Ukrainian", "ur": "Urdu", "uz": "Uzbek", "vi": "Vietnamese",
		"yi": "Yiddish", "yo": "Yoruba", "yue": "Cantonese", "zh": "Chinese",
	]

	private static let sortedLanguages: [(name: String, code: String)] =
		whisperLanguages
		.map { code, name in (name: name, code: code) }
		.sorted { $0.name < $1.name }

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

	private var isParakeet: Bool {
		manager.currentEngine == .parakeet
	}

	private var lockToEnglish: Bool {
		manager.currentParakeetVersion == .v2
	}

	private func isLanguageDisabled(_ code: String) -> Bool {
		guard let version = manager.currentParakeetVersion else { return false }
		return !AudioModelManager.parakeetSupports(language: code, version: version)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			HStack {
				Text("Language")
					.font(.title3)
					.foregroundStyle(.secondary)
				Spacer()
				if !isParakeet {
					TranslateToggle(
						isOn: $manager.translateToEnglish,
						disabled: isEnglish
					)
				}
			}
			.frame(height: 20)

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
					.disabled(lockToEnglish)

				ScrollShadowView {
					ScrollViewReader { proxy in
						LazyVStack(spacing: 0) {
							LanguageRow(
								name: "Auto-detect", code: nil,
								selected: manager.selectedLanguage == nil,
								hasProfanityList: false,
								disabled: isParakeet
							) {
								manager.selectedLanguage = nil
							}
							.id("auto")
							ForEach(filtered, id: \.code) { lang in
								LanguageRow(
									name: lang.name, code: lang.code,
									selected: manager.selectedLanguage == lang.code,
									hasProfanityList: Self.profanityLanguages.contains(lang.code),
									disabled: isLanguageDisabled(lang.code)
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
			.kkPanel()
			.overlay {
				if lockToEnglish {
					ParakeetLockOverlay(message: "Parakeet 0.6B v2 is English only.")
				}
			}
		}
	}
}

private struct ParakeetLockOverlay: View {
	let message: String

	var body: some View {
		ZStack {
			Rectangle()
				.fill(.ultraThinMaterial)
			VStack(spacing: KKSpacingSM) {
				Image(systemName: "lock.fill")
					.font(.system(size: 16))
					.foregroundStyle(.secondary)
				Text(message)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			.padding(KKPaddingLG)
		}
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD + 4))
		.allowsHitTesting(true)
	}
}

private struct TranslateToggle: View {
	@Binding var isOn: Bool
	let disabled: Bool

	var body: some View {
		CapsuleToggle(
			isOn: $isOn,
			label: "Translate to English",
			systemImage: "translate",
			disabled: disabled
		)
	}
}

private struct LanguageRow: View {
	let name: String
	let code: String?
	let selected: Bool
	let hasProfanityList: Bool
	var disabled: Bool = false
	let action: () -> Void

	var body: some View {
		let accent = Color.kkAccent

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
						"exclamationmark.bubble.fill",
					color: .green
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
		.kkSelectableBackground(selected)
		.contentShape(Rectangle())
		.opacity(disabled ? 0.35 : 1)
		.onTapGesture {
			guard !disabled else { return }
			action()
		}
	}
}
