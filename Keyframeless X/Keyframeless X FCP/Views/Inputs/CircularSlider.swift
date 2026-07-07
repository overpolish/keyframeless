/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import SwiftUI

/// The angle knob used across the plugins' Rotation controls: a native circular
/// `NSSlider` (0…360°, continuous, integer granularity). Mirrors the knob in
/// KKTimelineStaticValueRow. Value 0 is at the top, increasing clockwise.
struct CircularSlider: NSViewRepresentable {
	@Binding var degrees: Double

	private func normalized(_ d: Double) -> Double {
		let r = d.truncatingRemainder(dividingBy: 360)
		return r < 0 ? r + 360 : r
	}

	/// NSSlider's circular knob is 0 = top, clockwise; FCP (and the value we emit)
	/// is 0 = right, 90 = up, counter-clockwise. `90 - x` converts between them (it's
	/// its own inverse), so 90° points up like FCP.
	private func flip(_ x: Double) -> Double { normalized(90 - x) }

	func makeNSView(context: Context) -> NSSlider {
		let slider = NSSlider(
			value: flip(degrees), minValue: 0, maxValue: 360,
			target: context.coordinator, action: #selector(Coordinator.changed(_:)))
		slider.sliderType = .circular
		slider.controlSize = .mini
		slider.isContinuous = true
		return slider
	}

	func updateNSView(_ nsView: NSSlider, context: Context) {
		context.coordinator.parent = self
		let n = flip(degrees)
		if abs(nsView.doubleValue - n) > 0.5 {
			nsView.doubleValue = n
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	final class Coordinator: NSObject {
		var parent: CircularSlider
		init(_ parent: CircularSlider) { self.parent = parent }

		@objc func changed(_ sender: NSSlider) {
			parent.degrees = parent.flip(sender.doubleValue).rounded()
		}
	}
}
