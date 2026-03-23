/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct LabeledSlider: View {
	let label: String
	var labelWidth: CGFloat? = 68
	@Binding var value: Double
	let range: ClosedRange<Double>
	var step: Double? = nil
	var suffix: String = ""
	var textColor: Color = .secondary
	var valueWidth: CGFloat = 40

	@State private var isEditing = false
	@State private var editText = ""

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(label)
				.font(.caption)
				.foregroundStyle(textColor)
				.frame(width: labelWidth, alignment: .leading)
			MiniSlider(value: $value, range: range, step: step)
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
							.foregroundStyle(textColor)
					}
				}
				.frame(width: valueWidth, height: 14)
			} else {
				Text("\(Int(value))\(suffix)")
					.font(.caption.monospacedDigit())
					.foregroundStyle(textColor)
					.frame(width: valueWidth, alignment: .trailing)
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
	var step: Double? = nil

	private let trackHeight: CGFloat = 3
	private let thumbSize: CGFloat = 10

	private var fraction: Double {
		(value - range.lowerBound) / (range.upperBound - range.lowerBound)
	}

	private func snap(_ raw: Double) -> Double {
		guard let step else { return raw }
		return (raw / step).rounded() * step
	}

	private var tickCount: Int? {
		guard let step else { return nil }
		let span = range.upperBound - range.lowerBound
		let count = Int(span / step) + 1
		return count <= 20 ? count : nil
	}

	var body: some View {
		GeometryReader { geo in
			let trackWidth = geo.size.width
			let usable = trackWidth - thumbSize
			let thumbX = thumbSize / 2 + CGFloat(fraction) * usable

			ZStack(alignment: .leading) {
				Capsule()
					.fill(Color.white.opacity(0.1))
					.frame(height: trackHeight)
				Capsule()
					.fill(Color.kkAccent)
					.frame(width: thumbX, height: trackHeight)
				Circle()
					.fill(Color.white)
					.frame(width: thumbSize, height: thumbSize)
					.offset(x: thumbX - thumbSize / 2)
			}
			.frame(height: thumbSize)
			.overlay(alignment: .bottom) {
				if let tickCount, tickCount > 1 {
					HStack(spacing: 0) {
						ForEach(0..<tickCount, id: \.self) { i in
							if i > 0 { Spacer(minLength: 0) }
							Circle()
								.fill(Color.white.opacity(0.25))
								.frame(width: 2, height: 2)
						}
					}
					.padding(.horizontal, thumbSize / 2 - 1)
					.offset(y: 4)
				}
			}
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { drag in
						let pct = Double((drag.location.x - thumbSize / 2) / usable)
						let clamped = min(max(pct, 0), 1)
						let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
						value = snap(raw)
					}
			)
		}
		.frame(height: thumbSize)
	}
}
