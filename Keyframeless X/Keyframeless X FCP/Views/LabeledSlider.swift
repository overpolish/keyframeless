/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct LabeledSlider: View {
	let label: String
	@Binding var value: Double
	let range: ClosedRange<Double>
	var suffix: String = ""

	@State private var isEditing = false
	@State private var editText = ""

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(width: 68, alignment: .leading)
			MiniSlider(value: $value, range: range)
			if isEditing {
				HStack(spacing: 0) {
					SliderTextField(
						text: $editText,
						onCommit: { commitEdit() },
						onCancel: { isEditing = false }
					)
					if !suffix.isEmpty {
						Text(suffix)
							.font(.caption.monospacedDigit())
							.foregroundStyle(.secondary)
					}
				}
				.frame(width: 40, height: 14)
			} else {
				Text("\(Int(value))\(suffix)")
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
					.frame(width: 40, alignment: .trailing)
					.contentShape(Rectangle())
					.onTapGesture {
						editText = "\(Int(value))"
						isEditing = true
					}
			}
		}
	}

	private func commitEdit() {
		if let parsed = Double(editText) {
			value = min(max(parsed, range.lowerBound), range.upperBound)
		}
		isEditing = false
	}
}

private struct SliderTextField: NSViewRepresentable {
	@Binding var text: String
	var onCommit: () -> Void
	var onCancel: () -> Void

	func makeNSView(context: Context) -> AccentTextField {
		let field = AccentTextField()
		field.stringValue = text
		field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
		field.textColor = .secondaryLabelColor
		field.alignment = .right
		field.isBordered = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.usesSingleLineMode = true
		field.cell?.isScrollable = true
		field.cell?.wraps = false
		field.cell?.lineBreakMode = .byClipping
		field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		field.delegate = context.coordinator
		DispatchQueue.main.async {
			field.window?.makeFirstResponder(field)
			field.currentEditor()?.selectAll(nil)
		}
		return field
	}

	func updateNSView(_ nsView: AccentTextField, context: Context) {}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: SliderTextField

		init(_ parent: SliderTextField) {
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
			parent.onCommit()
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool
		{
			if sel == #selector(NSResponder.insertNewline(_:)) {
				parent.onCommit()
				return true
			}
			if sel == #selector(NSResponder.cancelOperation(_:)) {
				parent.onCancel()
				return true
			}
			return false
		}
	}
}

private struct MiniSlider: View {
	@Binding var value: Double
	let range: ClosedRange<Double>

	private let trackHeight: CGFloat = 3
	private let thumbSize: CGFloat = 10

	private var fraction: Double {
		(value - range.lowerBound) / (range.upperBound - range.lowerBound)
	}

	var body: some View {
		GeometryReader { geo in
			let trackWidth = geo.size.width
			let thumbX = thumbSize / 2 + CGFloat(fraction) * (trackWidth - thumbSize)

			ZStack(alignment: .leading) {
				Capsule()
					.fill(Color.white.opacity(0.1))
					.frame(height: trackHeight)
				Capsule()
					.fill(Color(nsColor: .accent()))
					.frame(width: thumbX, height: trackHeight)
				Circle()
					.fill(Color.white)
					.frame(width: thumbSize, height: thumbSize)
					.offset(x: thumbX - thumbSize / 2)
			}
			.frame(height: geo.size.height)
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { drag in
						let pct = Double(
							(drag.location.x - thumbSize / 2) / (trackWidth - thumbSize))
						let clamped = min(max(pct, 0), 1)
						value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
					}
			)
		}
		.frame(height: thumbSize)
	}
}
