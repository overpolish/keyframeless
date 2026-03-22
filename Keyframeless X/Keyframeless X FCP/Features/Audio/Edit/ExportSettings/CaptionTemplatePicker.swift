/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

private let cardAspect: CGFloat = 16.0 / 9.0
private let cardMinWidth: CGFloat = 120
private let cardSpacing = KKSpacingLG
private let selectionInset: CGFloat = 3
private let scrollMaxHeight: CGFloat = 240

class TemplateFavorites: ObservableObject {
	static let shared = TemplateFavorites()
	@Published private(set) var ids: Set<String> = []

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/template_favorites.json")
	}

	private init() { load() }

	func contains(_ id: String) -> Bool { ids.contains(id) }

	func toggle(_ id: String) {
		if ids.contains(id) {
			ids.remove(id)
		} else {
			ids.insert(id)
		}
		save()
	}

	private func save() {
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(Array(ids)).write(to: url, options: .atomic)
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let saved = try? JSONDecoder().decode([String].self, from: data)
		else { return }
		ids = Set(saved)
	}
}

struct CaptionTemplatePicker: View {
	@Binding var selectedTemplate: CaptionTemplate
	let templates: [CaptionTemplate]
	var onDropMoti: ((URL) -> Void)?
	var onRemoveCustom: ((CaptionTemplate) -> Void)?

	@ObservedObject private var favorites = TemplateFavorites.shared
	@State private var isDropTargeted = false
	@State private var searchText = ""
	@State private var showFavoritesOnly = false

	private func sorted(_ list: [CaptionTemplate]) -> [CaptionTemplate] {
		list.sorted { a, b in
			let aFav = favorites.contains(a.id)
			let bFav = favorites.contains(b.id)
			if aFav != bFav { return aFav }
			return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
		}
	}

	private func filtered(_ list: [CaptionTemplate]) -> [CaptionTemplate] {
		var result = list
		if showFavoritesOnly {
			result = result.filter { favorites.contains($0.id) }
		}
		if !searchText.isEmpty {
			result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
		}
		return sorted(result)
	}

	private var keyframelessTemplates: [CaptionTemplate] {
		filtered(templates.filter { !$0.isCustom })
	}

	private var customTemplates: [CaptionTemplate] {
		filtered(templates.filter { $0.isCustom })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			HStack(spacing: KKSpacingMD) {
				Text("Style")
					.font(.title3)
					.foregroundStyle(.secondary)
				HStack(spacing: KKSpacingSM) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
					TemplateSearchField(text: $searchText)
						.frame(height: 16)
				}
				.padding(.horizontal, KKPaddingLG)
				.padding(.vertical, KKPaddingXS)
				.background(
					Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: KKRadiusMD)
				)
				.overlay(
					RoundedRectangle(cornerRadius: KKRadiusMD)
						.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
				)
				.frame(maxWidth: 120)
				Button {
					showFavoritesOnly.toggle()
				} label: {
					Image(systemName: showFavoritesOnly ? "star.fill" : "star")
						.font(.system(size: 11))
						.foregroundStyle(
							showFavoritesOnly
								? Color(nsColor: .warning())
								: .secondary
						)
				}
				.buttonStyle(.plain)
			}
			ScrollShadowView(cornerRadius: KKRadiusSM) {
				VStack(alignment: .leading, spacing: KKSpacingLG) {
					TemplateSection(title: "Keyframeless") {
						ForEach(keyframelessTemplates) { template in
							CaptionTemplateCard(
								template: template,
								isSelected: template.id == selectedTemplate.id,
								isFavorite: favorites.contains(template.id),
								onSelect: { selectedTemplate = template },
								onToggleFavorite: { favorites.toggle(template.id) }
							)
						}
					}
					TemplateSection(title: "Custom") {
						ForEach(customTemplates) { template in
							CaptionTemplateCard(
								template: template,
								isSelected: template.id == selectedTemplate.id,
								isFavorite: favorites.contains(template.id),
								onSelect: { selectedTemplate = template },
								onToggleFavorite: { favorites.toggle(template.id) },
								onRemove: { onRemoveCustom?(template) }
							)
						}
						MotiDropTarget(onPickFile: pickMotiFile)
					}
				}
				.padding(.vertical, KKPaddingXS)
			}
			.frame(maxHeight: scrollMaxHeight)
		}
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			handleDrop(providers)
		}
	}

	private func pickMotiFile() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "moti") ?? .data]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		onDropMoti?(url)
	}

	private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == "moti"
				else { return }
				DispatchQueue.main.async { onDropMoti?(url) }
			}
		}
		return true
	}
}

struct TemplateSection<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingSM) {
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
			TemplateGrid { content }
		}
	}
}

struct TemplateGrid<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		let gridColumns = [
			GridItem(.adaptive(minimum: cardMinWidth), spacing: cardSpacing)
		]

		LazyVGrid(columns: gridColumns, spacing: cardSpacing) {
			content
		}
	}
}

struct MotiDropTarget: View {
	var onPickFile: (() -> Void)?

	var body: some View {
		VStack(spacing: KKSpacingSM) {
			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(style: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3]))
					.foregroundStyle(.secondary.opacity(0.3))
				Image(systemName: "plus")
					.font(.system(size: 14))
					.foregroundStyle(.secondary.opacity(0.5))
			}
			.aspectRatio(cardAspect, contentMode: .fit)
			.padding(selectionInset)
			Text("Drop .moti")
				.font(.system(size: 9))
				.foregroundStyle(.secondary.opacity(0.5))
		}
		.contentShape(Rectangle())
		.onTapGesture { onPickFile?() }
	}
}

struct CaptionTemplateCard: View {
	let template: CaptionTemplate
	let isSelected: Bool
	let isFavorite: Bool
	let onSelect: () -> Void
	var onToggleFavorite: (() -> Void)?
	var onRemove: (() -> Void)?

	@State private var thumbnail: NSImage?
	@State private var gifURL: URL?
	@State private var isHovered = false
	@State private var gifProgress: CGFloat = 0

	var body: some View {
		VStack(spacing: KKSpacingSM) {
			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.fill(Color.white.opacity(0.06))
				if isHovered, let gifURL {
					GeometryReader { geo in
						AnimatedGifView(url: gifURL, progress: $gifProgress)
							.frame(width: geo.size.width, height: geo.size.height)
					}
				} else if let thumbnail {
					Image(nsImage: thumbnail)
						.resizable()
						.aspectRatio(contentMode: .fill)
				} else {
					Image(systemName: "textformat")
						.font(.system(size: 20))
						.foregroundStyle(.secondary)
				}
				VStack {
					HStack {
						if isHovered, let onRemove {
							Button {
								onRemove()
							} label: {
								Image(systemName: "xmark.circle.fill")
									.font(.system(size: 12))
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
							.padding(KKPaddingMD)
						}
						Spacer()
						if isFavorite || isHovered {
							Button {
								onToggleFavorite?()
							} label: {
								Image(systemName: isFavorite ? "star.fill" : "star")
									.font(.system(size: 9))
									.foregroundStyle(
										isFavorite
											? Color(nsColor: .warning())
											: .secondary.opacity(0.4)
									)
							}
							.buttonStyle(.plain)
							.padding(KKPaddingMD)
						}
					}
					Spacer()
				}
			}
			.overlay(alignment: .bottom) {
				if isHovered && gifURL != nil {
					GeometryReader { geo in
						Color(nsColor: .accent() ?? .blue)
							.frame(width: geo.size.width * gifProgress, height: 2)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: 2)
				}
			}
			.aspectRatio(cardAspect, contentMode: .fit)
			.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(
						Color.secondary.opacity(isHovered ? 0.4 : 0.2),
						lineWidth: KKBorderWidthXS
					)
			)
			.padding(selectionInset)
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD + selectionInset)
					.strokeBorder(
						isSelected
							? Color(nsColor: .accent() ?? .blue)
							: .clear,
						lineWidth: KKBorderWidthSM
					)
			)

			VStack(spacing: 0) {
				Text(template.name)
					.font(.system(size: 9))
					.foregroundStyle(isSelected ? .primary : .secondary)
					.lineLimit(1)
				if !template.isBuiltIn && !template.supportsAnimateOn {
					Text("No animation")
						.font(.system(size: 8))
						.foregroundStyle(Color(nsColor: .warning() ?? .yellow).opacity(0.8))
				}
			}
		}
		.onHover { hovering in
			isHovered = hovering
			if !hovering { gifProgress = 0 }
		}
		.onTapGesture { onSelect() }
		.onAppear {
			thumbnail = template.loadThumbnail()
			gifURL = template.loadPreviewGifURL()
		}
	}
}

struct AnimatedGifView: NSViewRepresentable {
	let url: URL
	@Binding var progress: CGFloat

	func makeNSView(context: Context) -> NSImageView {
		let imageView = NSImageView()
		imageView.imageScaling = .scaleProportionallyUpOrDown
		imageView.animates = false
		imageView.canDrawSubviewsIntoLayer = true
		imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
		imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
			let count = CGImageSourceGetCount(source)
			var delays: [Double] = []
			for i in 0..<count {
				let props =
					CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
				let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
				let delay =
					(gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
					?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double)
					?? 0.1
				delays.append(delay)
			}
			context.coordinator.start(
				source: source, delays: delays, imageView: imageView, progress: $progress)
		}

		return imageView
	}

	func updateNSView(_ nsView: NSImageView, context: Context) {}

	static func dismantleNSView(_ nsView: NSImageView, coordinator: Coordinator) {
		coordinator.stop()
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	class Coordinator {
		private var timer: Timer?
		private var source: CGImageSource?
		private var delays: [Double] = []
		private var currentFrame = 0
		private var progress: Binding<CGFloat>?
		private weak var imageView: NSImageView?

		func start(
			source: CGImageSource, delays: [Double], imageView: NSImageView,
			progress: Binding<CGFloat>
		) {
			self.source = source
			self.delays = delays
			self.imageView = imageView
			self.progress = progress
			currentFrame = 0
			showFrame(0)
			scheduleNext()
		}

		func stop() {
			timer?.invalidate()
			timer = nil
		}

		private func showFrame(_ index: Int) {
			guard let source,
				let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil)
			else { return }
			let image = NSImage(
				cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
			imageView?.image = image
			let count = CGImageSourceGetCount(source)
			DispatchQueue.main.async {
				self.progress?.wrappedValue = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
			}
		}

		private func scheduleNext() {
			guard !delays.isEmpty else { return }
			let delay = delays[currentFrame]
			timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
				guard let self, let source = self.source else { return }
				let count = CGImageSourceGetCount(source)
				self.currentFrame = (self.currentFrame + 1) % count
				self.showFrame(self.currentFrame)
				self.scheduleNext()
			}
		}
	}
}

struct TemplateSearchField: NSViewRepresentable {
	@Binding var text: String

	func makeNSView(context: Context) -> AccentTextField {
		let field = AccentTextField()
		field.placeholderString = "Search"
		field.isBezeled = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.font = .systemFont(ofSize: 11)
		field.delegate = context.coordinator
		field.stringValue = text
		return field
	}

	func updateNSView(_ nsView: AccentTextField, context: Context) {
		if nsView.stringValue != text {
			nsView.stringValue = text
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: TemplateSearchField
		init(_ parent: TemplateSearchField) { self.parent = parent }

		func controlTextDidChange(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			parent.text = field.stringValue
		}
	}
}
