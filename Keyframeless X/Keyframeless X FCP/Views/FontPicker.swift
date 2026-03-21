/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import KeyframelessKit
import SwiftUI

struct FontPickerRow: View {
	@Binding var selectedFont: String
	@State private var isOpen = false

	private static let fontFamilies: [FontFamily] = FontFamily.all()

	private var displayName: String {
		NSFont(name: selectedFont, size: 12)?.displayName ?? selectedFont
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text("Font")
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(width: 68, alignment: .leading)
			HStack(spacing: KKSpacingSM) {
				Text(displayName)
					.font(.custom(selectedFont, size: 11))
					.lineLimit(1)
					.frame(maxWidth: .infinity, alignment: .leading)
				Image(systemName: "chevron.up.chevron.down")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			.frame(height: KKInspectorRowHeight)
			.padding(.horizontal, KKPaddingLG)
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.fill(Color.white.opacity(0.04))
			)
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
			)
			.contentShape(RoundedRectangle(cornerRadius: KKRadiusMD))
			.onTapGesture { isOpen.toggle() }
			.popover(isPresented: $isOpen, arrowEdge: .top) {
				FontListPopover(selectedFont: $selectedFont, fonts: Self.fontFamilies)
					.background(PopoverBackgroundClearer())
			}
		}
	}
}

class FontFavorites: ObservableObject {
	static let shared = FontFavorites()
	@Published private(set) var familyNames: Set<String> = []

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/font_favorites.json")
	}

	private init() { load() }

	func contains(_ name: String) -> Bool { familyNames.contains(name) }

	func toggle(_ name: String) {
		if familyNames.contains(name) {
			familyNames.remove(name)
		} else {
			familyNames.insert(name)
		}
		save()
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let names = try? JSONDecoder().decode(Set<String>.self, from: data)
		else { return }
		familyNames = names
	}

	private func save() {
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(familyNames).write(to: url, options: .atomic)
	}
}

struct FontVariant: Identifiable {
	let postScriptName: String
	let styleName: String
	var id: String { postScriptName }
}

struct FontFamily: Identifiable {
	let name: String
	let variants: [FontVariant]
	var id: String { name }

	static func all() -> [FontFamily] {
		let manager = NSFontManager.shared
		return manager.availableFontFamilies.sorted().map { family in
			let members = manager.availableMembers(ofFontFamily: family) ?? []
			let variants = members.compactMap { member -> FontVariant? in
				guard let postScript = member[0] as? String,
					let style = member[1] as? String
				else { return nil }
				return FontVariant(postScriptName: postScript, styleName: style)
			}
			return FontFamily(name: family, variants: variants)
		}
	}
}

private struct FontListPopover: View {
	@Binding var selectedFont: String
	let fonts: [FontFamily]
	@ObservedObject private var favorites = FontFavorites.shared
	@State private var search = ""
	@Environment(\.dismiss) private var dismiss

	private var filtered: [FontFamily] {
		guard !search.isEmpty else { return fonts }
		let q = search.lowercased()
		return fonts.filter { $0.name.lowercased().contains(q) }
	}

	private var favoriteFonts: [FontFamily] {
		filtered.filter { favorites.contains($0.name) }
	}

	private var otherFonts: [FontFamily] {
		filtered.filter { !favorites.contains($0.name) }
	}

	var body: some View {
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
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(favoriteFonts) { family in
							FontFamilyRow(
								family: family,
								selectedFont: selectedFont,
								onSelect: { font in
									selectedFont = font
									dismiss()
								}
							)
							.id(family.name)
						}
						if !favoriteFonts.isEmpty && !otherFonts.isEmpty {
							Rectangle()
								.fill(Color.secondary.opacity(0.15))
								.frame(height: KKBorderWidthXS)
								.padding(.horizontal, KKPaddingLG)
								.padding(.vertical, KKSpacingMD)
						}
						ForEach(otherFonts) { family in
							FontFamilyRow(
								family: family,
								selectedFont: selectedFont,
								onSelect: { font in
									selectedFont = font
									dismiss()
								}
							)
							.id(family.name)
						}
					}
					.padding(KKPaddingMD)
				}
				.onAppear {
					let familyName = fonts.first { family in
						family.variants.contains { $0.postScriptName == selectedFont }
					}?.name
					if let familyName {
						DispatchQueue.main.async {
							proxy.scrollTo(familyName, anchor: .center)
						}
					}
				}
			}
		}
		.frame(width: 240, height: 300)
	}
}

private struct FontFamilyRow: View {
	let family: FontFamily
	let selectedFont: String
	let onSelect: (String) -> Void
	@ObservedObject private var favorites = FontFavorites.shared
	@State private var showVariants = false

	private var isSelected: Bool {
		family.variants.contains { $0.postScriptName == selectedFont }
	}
	private var hasVariants: Bool { family.variants.count > 1 }
	private var isFavorite: Bool { favorites.contains(family.name) }

	var body: some View {
		let accent = Color(nsColor: .accent() ?? .blue)

		HStack(spacing: KKSpacingLG) {
			Button {
				favorites.toggle(family.name)
			} label: {
				Image(systemName: isFavorite ? "star.fill" : "star")
					.font(.system(size: 9))
					.foregroundStyle(
						isFavorite ? Color(nsColor: .warning()) : .secondary.opacity(0.4))
			}
			.buttonStyle(.plain)
			Text(family.name)
				.font(.custom(family.name, size: 12))
				.lineLimit(1)
			Spacer()
			if hasVariants {
				Image(systemName: "chevron.right")
					.font(.system(size: 8, weight: .semibold))
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKSpacingMD)
		.background(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(isSelected ? accent.opacity(0.12) : Color.clear)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if hasVariants {
				showVariants = true
			} else if let first = family.variants.first {
				onSelect(first.postScriptName)
			}
		}
		.popover(isPresented: $showVariants, arrowEdge: .trailing) {
			FontVariantPopover(
				family: family,
				selectedFont: selectedFont,
				onSelect: { font in
					showVariants = false
					onSelect(font)
				}
			)
		}
	}
}

private struct FontVariantPopover: View {
	let family: FontFamily
	let selectedFont: String
	let onSelect: (String) -> Void

	var body: some View {
		let accent = Color(nsColor: .accent() ?? .blue)

		ScrollView {
			VStack(spacing: 0) {
				ForEach(family.variants) { variant in
					let variantSelected = selectedFont == variant.postScriptName

					HStack(spacing: KKSpacingLG) {
						Text(variant.styleName)
							.font(.custom(variant.postScriptName, size: 12))
							.lineLimit(1)
						Spacer()
					}
					.frame(maxWidth: .infinity)
					.padding(.horizontal, KKPaddingLG)
					.padding(.vertical, KKSpacingMD)
					.background(
						GeometryReader { geo in
							let _ = print(
								"[VariantRow] '\(variant.styleName)' frame: \(geo.size), origin: \(geo.frame(in: .named("variantScroll")).origin)"
							)
							RoundedRectangle(cornerRadius: KKRadiusMD)
								.fill(variantSelected ? accent.opacity(0.12) : Color.clear)
						}
					)
					.contentShape(Rectangle())
					.onTapGesture { onSelect(variant.postScriptName) }
				}
			}
			.padding(KKPaddingMD)
			.frame(width: 180)
			.background(
				GeometryReader { geo in
					let _ = print("[VariantVStack] size: \(geo.size)")
					Color.clear
				}
			)
		}
		.coordinateSpace(name: "variantScroll")
		.scrollIndicators(.never)
		.background(
			GeometryReader { geo in
				let _ = print("[VariantScrollView] size: \(geo.size)")
				Color.clear
			}
		)
		.frame(width: 180, height: min(CGFloat(family.variants.count) * 26 + KKPaddingMD * 2, 200))
		.background(PopoverBackgroundClearer())
	}
}
