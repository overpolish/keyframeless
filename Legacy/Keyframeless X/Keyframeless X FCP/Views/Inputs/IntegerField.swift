/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct IntegerField: View {
	var placeholder: String
	@Binding var text: String
	var min: Int?
	var max: Int?

	var body: some View {
		IntegerFieldRepresentable(placeholder: placeholder, text: $text, min: min, max: max)
			.padding(.horizontal, KKPaddingLG)
			.padding(.vertical, KKPaddingXS)
			.background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: KKRadiusMD))
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
			)
	}
}

private struct IntegerFieldRepresentable: NSViewRepresentable {
	var placeholder: String
	@Binding var text: String
	var min: Int?
	var max: Int?

	func makeNSView(context: Context) -> AccentTextField {
		let field = AccentTextField()
		field.placeholderString = placeholder
		field.isBezeled = false
		field.drawsBackground = false
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
		var parent: IntegerFieldRepresentable

		init(_ parent: IntegerFieldRepresentable) {
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

		func controlTextDidEndEditing(_ obj: Notification) {
			guard let field = obj.object as? NSTextField,
				let value = Int(field.stringValue)
			else { return }
			var clamped = value
			if let min = parent.min { clamped = Swift.max(clamped, min) }
			if let max = parent.max { clamped = Swift.min(clamped, max) }
			if clamped != value {
				let text = "\(clamped)"
				field.stringValue = text
				parent.text = text
			}
		}
	}
}

class AccentTextField: NSTextField {
	override var canBecomeKeyView: Bool { false }

	override func becomeFirstResponder() -> Bool {
		let result = super.becomeFirstResponder()
		if result,
			let editor = currentEditor() as? NSTextView
		{
			let accent = NSColor.controlAccentColor
			editor.insertionPointColor = accent
			editor.selectedTextAttributes = [
				.backgroundColor: accent.withAlphaComponent(0.3)
			]
		}
		return result
	}
}
