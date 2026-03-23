/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct LabeledField<Content: View>: View {
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

struct PublishTextField: NSViewRepresentable {
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

struct GifDropZone: View {
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
