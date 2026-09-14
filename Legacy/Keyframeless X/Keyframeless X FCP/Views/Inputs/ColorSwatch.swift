/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct ColorSwatch: View {
	@Binding var colorR: Double
	@Binding var colorG: Double
	@Binding var colorB: Double
	@Binding var colorA: Double

	private var nsColor: NSColor {
		NSColor(red: colorR, green: colorG, blue: colorB, alpha: colorA)
	}

	var body: some View {
		Button {
			ColorPanelController.shared.show(color: nsColor) { color in
				guard let c = color.usingColorSpace(.sRGB) else { return }
				colorR = Double(c.redComponent)
				colorG = Double(c.greenComponent)
				colorB = Double(c.blueComponent)
				colorA = Double(c.alphaComponent)
			}
		} label: {
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(Color(nsColor: nsColor))
				.frame(width: 20, height: 20)
				.overlay(
					RoundedRectangle(cornerRadius: KKRadiusMD)
						.strokeBorder(.secondary.opacity(0.3), lineWidth: KKBorderWidthXS)
				)
		}
		.buttonStyle(.plain)
	}
}

private final class ColorPanelController: NSObject {
	static let shared = ColorPanelController()
	private var onChange: ((NSColor) -> Void)?

	func show(color: NSColor, onChange: @escaping (NSColor) -> Void) {
		self.onChange = onChange
		let panel = NSColorPanel.shared
		panel.showsAlpha = true
		panel.color = color
		panel.setTarget(self)
		panel.setAction(#selector(colorDidChange(_:)))

		// Add as child window of the extension's window so they stay grouped
		// in Mission Control and the panel doesn't get pushed behind FCP
		if let extensionWindow = NSApp.windows.first(where: {
			!($0 is NSColorPanel) && $0.isVisible
		}) {
			if panel.parent != extensionWindow {
				panel.parent?.removeChildWindow(panel)
				extensionWindow.addChildWindow(panel, ordered: .above)
			}
		}

		panel.orderFront(nil)
	}

	@objc private func colorDidChange(_ sender: NSColorPanel) {
		onChange?(sender.color)
	}
}
