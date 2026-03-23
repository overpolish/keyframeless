/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct TemplatePublishModal: View {
	let template: CaptionTemplate
	let params: [PublishedParameter]
	let hasPerWordAnimation: Bool
	let enabledIDs: Set<String>
	let onDismiss: () -> Void

	@State private var name: String
	@State private var author: String = ""
	@State private var previewGifURL: URL?
	@State private var isDropTargeted = false
	@State private var gifTooLarge = false
	@State private var gifWrongAspect = false
	@State private var focusName = false
	@State private var focusAuthor = false
	@State private var isPublishing = false
	@State private var publishError: String?

	init(
		template: CaptionTemplate,
		params: [PublishedParameter],
		hasPerWordAnimation: Bool,
		enabledIDs: Set<String>,
		onDismiss: @escaping () -> Void
	) {
		self.template = template
		self.params = params
		self.hasPerWordAnimation = hasPerWordAnimation
		self.enabledIDs = enabledIDs
		self.onDismiss = onDismiss
		_name = State(initialValue: template.name)
	}

	private var canPublish: Bool {
		!name.trimmingCharacters(in: .whitespaces).isEmpty && previewGifURL != nil && !gifTooLarge
			&& !gifWrongAspect
	}

	private var enabledParams: [PublishedParameter] {
		params.filter { enabledIDs.contains($0.id) && $0.isToggleable }
	}

	var body: some View {
		ZStack {
			Color.black.opacity(0.5)
				.ignoresSafeArea()
				.onTapGesture { onDismiss() }
			VStack(alignment: .leading, spacing: KKSpacingXL) {
				HStack {
					Text("Publish Template")
						.font(.title3)
						.foregroundStyle(.primary)
					Spacer()
					if hasPerWordAnimation {
						HStack(spacing: KKSpacingMD) {
							InfoBadge(
								label: "Per word",
								systemImage: "directcurrent",
								color: .green
							)
						}
					}
				}

				VStack(alignment: .leading, spacing: KKSpacingLG) {
					LabeledField(label: "Name") {
						HStack(spacing: KKSpacingSM) {
							Image(systemName: "tag.fill")
								.font(.system(size: 10))
								.foregroundStyle(.secondary)
							PublishTextField(
								text: $name, placeholder: "Template name", requestFocus: $focusName
							)
							.frame(height: 16)
						}
						.padding(.horizontal, KKPaddingLG)
						.padding(.vertical, KKPaddingLG)
						.contentShape(Rectangle())
						.onTapGesture { focusName.toggle() }
						.kkPanel(cornerRadius: KKRadiusMD)
					}
					LabeledField(label: "Author") {
						HStack(spacing: KKSpacingSM) {
							Image(systemName: "person.circle.fill")
								.font(.system(size: 10))
								.foregroundStyle(.secondary)
							PublishTextField(
								text: $author, placeholder: "Optional", requestFocus: $focusAuthor
							)
							.frame(height: 16)
						}
						.padding(.horizontal, KKPaddingLG)
						.padding(.vertical, KKPaddingLG)
						.contentShape(Rectangle())
						.onTapGesture { focusAuthor.toggle() }
						.kkPanel(cornerRadius: KKRadiusMD)
					}
				}

				VStack(alignment: .leading, spacing: KKSpacingSM) {
					HStack {
						Text("Preview")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
						Spacer()
						Text("16:9 Aspect Ratio - Max size 300Kb").font(.caption).foregroundStyle(
							.secondary)
					}
					Button {
						downloadSampleAudio()
					} label: {
						HStack(spacing: KKSpacingSM) {
							Image(systemName: "arrow.down.circle.fill")
								.font(.system(size: 10))
							Text("Download Sample Audio")
								.font(.system(size: 11))
						}
						.foregroundStyle(Color.kkAccent)
					}
					.buttonStyle(.plain)
					GifDropZone(
						gifURL: previewGifURL,
						isDropTargeted: $isDropTargeted,
						onPick: pickGif,
						onDrop: handleGifDrop
					)
					if gifTooLarge {
						Text("GIF exceeds 300 KB limit")
							.font(.system(size: 10))
							.foregroundStyle(Color.kkError)
					}
					if gifWrongAspect {
						Text("GIF must be 16:9 aspect ratio")
							.font(.system(size: 10))
							.foregroundStyle(Color.kkError)
					}
				}

				if !enabledParams.isEmpty {
					VStack(alignment: .leading, spacing: KKSpacingSM) {
						Text("Parameters")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
						HStack(spacing: KKSpacingSM) {
							ForEach(enabledParams) { param in
								paramBadge(param)
							}
						}
					}
				}

				if let publishError {
					Text(publishError)
						.font(.system(size: 10))
						.foregroundStyle(Color.kkError)
						.fixedSize(horizontal: false, vertical: true)
				}

				HStack {
					Button("Cancel") { onDismiss() }
						.buttonStyle(.plain)
						.foregroundStyle(.secondary)
					Spacer()
					Button(isPublishing ? "Publishing..." : "Publish") { publish() }
						.buttonStyle(.plain)
						.foregroundStyle(
							canPublish && !isPublishing
								? Color.kkAccent : .secondary.opacity(0.4)
						)
						.disabled(!canPublish || isPublishing)
				}
			}
			.padding(KKPaddingXL)
			.frame(width: 360)
			.kkPanel()
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.fill(Color(nsColor: .windowBackgroundColor))
			)
		}
	}

	@ViewBuilder
	private func paramBadge(_ param: PublishedParameter) -> some View {
		switch param.kind {
		case .color:
			InfoBadge(label: param.name, systemImage: "paintpalette", color: .kkAccent)
		case .slider:
			InfoBadge(label: param.name, systemImage: "slider.horizontal.3", color: .kkWarning)
		default:
			InfoBadge(label: param.name, color: .secondary)
		}
	}

	private static let maxGifSize = 300 * 1024

	private func setGif(_ url: URL) {
		let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
		gifTooLarge = size > Self.maxGifSize
		if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let w = props[kCGImagePropertyPixelWidth] as? Int,
			let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0
		{
			let ratio = Double(w) / Double(h)
			gifWrongAspect = abs(ratio - 16.0 / 9.0) > 0.05
		} else {
			gifWrongAspect = true
		}
		previewGifURL = url
	}

	private func downloadSampleAudio() {
		guard
			let sourceURL = Bundle.main.url(
				forResource: "the-quick-brown-fox-jumps-over-the-lazy-dog",
				withExtension: "m4a"
			)
		else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "the-quick-brown-fox-jumps-over-the-lazy-dog.m4a"
		panel.allowedContentTypes = [UTType.mpeg4Audio]
		guard panel.runModal() == .OK, let destURL = panel.url else { return }
		try? FileManager.default.copyItem(at: sourceURL, to: destURL)
	}

	private func pickGif() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType.gif]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		setGif(url)
	}

	private func handleGifDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == "gif"
				else { return }
				DispatchQueue.main.async { setGif(url) }
			}
		}
		return true
	}

	private func resolveMotiDirectory() -> URL? {
		let uid = template.uid
		let motiURL: URL
		if uid.hasPrefix("~/") {
			let relative = String(uid.dropFirst(2))
			let base = FileManager.default.homeDirectoryForCurrentUser
				.appendingPathComponent("Movies/Motion Templates.localized")
			motiURL = base.appendingPathComponent(relative)
		} else {
			motiURL = URL(fileURLWithPath: uid)
		}
		return motiURL.deletingLastPathComponent()
	}

	private func publish() {
		guard canPublish, !isPublishing else { return }
		guard let motiDir = resolveMotiDirectory() else {
			publishError = "Could not locate template directory"
			return
		}
		guard let gifURL = previewGifURL else { return }

		isPublishing = true
		publishError = nil

		let payload = CommunityPublisher.TemplatePayload(
			id: UUID().uuidString,
			name: name.trimmingCharacters(in: .whitespaces),
			author: author.trimmingCharacters(in: .whitespaces),
			perWord: hasPerWordAnimation,
			params: enabledParams.map { ["name": $0.name, "kind": "\($0.kind)"] },
			motiDirectoryURL: motiDir,
			previewGifURL: gifURL
		)

		Task {
			do {
				try await CommunityPublisher.publish(payload)
				await MainActor.run {
					isPublishing = false
					onDismiss()
				}
			} catch {
				await MainActor.run {
					isPublishing = false
					publishError = error.localizedDescription
				}
			}
		}
	}
}

private struct LabeledField<Content: View>: View {
	let label: String
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingXS) {
			Text(label)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
			content
		}
	}
}

private struct PublishTextField: NSViewRepresentable {
	@Binding var text: String
	let placeholder: String
	@Binding var requestFocus: Bool

	func makeNSView(context: Context) -> AccentTextField {
		let field = AccentTextField()
		field.placeholderString = placeholder
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
		if requestFocus {
			DispatchQueue.main.async {
				nsView.window?.makeFirstResponder(nsView)
				requestFocus = false
			}
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: PublishTextField
		init(_ parent: PublishTextField) { self.parent = parent }

		func controlTextDidChange(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			parent.text = field.stringValue
		}
	}
}

private struct GifDropZone: View {
	let gifURL: URL?
	@Binding var isDropTargeted: Bool
	let onPick: () -> Void
	let onDrop: ([NSItemProvider]) -> Bool

	@State private var gifProgress: CGFloat = 0

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(Color.white.opacity(0.06))
			if let gifURL {
				GeometryReader { geo in
					AnimatedGifView(url: gifURL, progress: $gifProgress)
						.frame(width: geo.size.width, height: geo.size.height)
				}
				.allowsHitTesting(false)
				.id(gifURL)
			} else {
				VStack(spacing: KKSpacingSM) {
					Image(systemName: "photo.badge.plus")
						.font(.system(size: 16))
						.foregroundStyle(.secondary.opacity(0.5))
					Text("Drop preview .gif")
						.font(.system(size: 10))
						.foregroundStyle(.secondary.opacity(0.5))
				}
			}
			if isDropTargeted {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(Color.kkAccent, lineWidth: KKBorderWidthSM)
			}
		}
		.aspectRatio(16.0 / 9.0, contentMode: .fit)
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
		.overlay(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.strokeBorder(
					Color.secondary.opacity(0.2),
					style: gifURL != nil
						? StrokeStyle(lineWidth: KKBorderWidthXS)
						: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3])
				)
		)
		.contentShape(Rectangle())
		.onTapGesture { onPick() }
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			onDrop(providers)
		}
	}
}
