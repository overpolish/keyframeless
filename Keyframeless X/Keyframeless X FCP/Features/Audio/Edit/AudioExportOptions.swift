/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct AudioExportOptionsView: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text("Project Settings")
				.font(.subheadline)
				.foregroundStyle(.secondary)
			Spacer()
			IntegerField(placeholder: "Width", text: $model.exportWidth)
				.frame(width: 60)
			Text("\u{00d7}")
				.foregroundStyle(.secondary)
			IntegerField(placeholder: "Height", text: $model.exportHeight)
				.frame(width: 60)
			Picker("", selection: $model.exportFramerate) {
				ForEach(Framerate.allCases) { rate in
					Text(rate.label).tag(rate)
				}
			}
			.labelsHidden()
			.frame(width: 100)
		}
		.onAppear {
			guard !model.exportSettingsInitialized else { return }
			let format = model.projectFormat ?? .default
			model.exportWidth = "\(format.width)"
			model.exportHeight = "\(format.height)"
			model.exportFramerate = Framerate.from(frameDuration: format.frameDuration)
			model.exportSettingsInitialized = true
		}
	}
}

enum Framerate: String, CaseIterable, Identifiable, Codable {
	case fps2398 = "1001/24000s"
	case fps24 = "100/2400s"
	case fps25 = "100/2500s"
	case fps2997 = "1001/30000s"
	case fps30 = "100/3000s"
	case fps50 = "100/5000s"
	case fps5994 = "1001/60000s"
	case fps60 = "100/6000s"
	case fps120 = "100/12000s"

	var id: String { rawValue }

	var label: String {
		switch self {
		case .fps2398: return "23.98 fps"
		case .fps24: return "24 fps"
		case .fps25: return "25 fps"
		case .fps2997: return "29.97 fps"
		case .fps30: return "30 fps"
		case .fps50: return "50 fps"
		case .fps5994: return "59.94 fps"
		case .fps60: return "60 fps"
		case .fps120: return "120 fps"
		}
	}

	static func from(frameDuration: String) -> Framerate {
		allCases.first { $0.rawValue == frameDuration } ?? .fps30
	}
}

struct AudioExportOptionsSidebar: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			AudioExportOptionsView(model: model)
			Spacer()
		}
		.padding(KKPaddingLG)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD + 4))
		.background(
			RoundedRectangle(cornerRadius: KKRadiusMD + 4)
				.fill(Color.white.opacity(0.04))
		)
		.overlay(
			RoundedRectangle(cornerRadius: KKRadiusMD + 4)
				.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
		)
	}
}

private class AccentTextField: NSTextField {
	override func becomeFirstResponder() -> Bool {
		let result = super.becomeFirstResponder()
		if result,
			let editor = currentEditor() as? NSTextView,
			let accent = NSColor.accent()
		{
			editor.insertionPointColor = accent
			editor.selectedTextAttributes = [
				.backgroundColor: accent.withAlphaComponent(0.3)
			]
		}
		return result
	}
}

private struct IntegerField: NSViewRepresentable {
	var placeholder: String
	@Binding var text: String

	func makeNSView(context: Context) -> AccentTextField {
		let field = AccentTextField()
		field.placeholderString = placeholder
		field.bezelStyle = .roundedBezel
		field.focusRingType = .none
		field.font = .systemFont(ofSize: NSFont.systemFontSize)
		field.alignment = .center
		field.delegate = context.coordinator
		field.stringValue = text
		return field
	}

	func updateNSView(_ nsView: AccentTextField, context: Context) {
		if nsView.stringValue != text {
			nsView.stringValue = text
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: IntegerField

		init(_ parent: IntegerField) {
			self.parent = parent
		}

		func controlTextDidChange(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			let filtered = field.stringValue.filter(\.isWholeNumber)
			if field.stringValue != filtered {
				field.stringValue = filtered
			}
			parent.text = filtered
		}
	}
}
